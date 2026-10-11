import CryptoKit
import Darwin
import Foundation
import Security

public enum HostVersionResolutionMode: Sendable {
    case reuseValidated
    case forceProbe
}

/// Cache publication and successful version probing are independent outcomes.
public enum HostVersionRefreshStatus: String, Sendable, Equatable {
    case published, disabled, ineligible, busy, writeFailed, probeFailed
    case identityChanged, expired, cancelled, publicationLeaseHeld, unsupportedHost
}

public struct HostVersionRefreshResult: Sendable, Equatable {
    public let version: String?
    public let status: HostVersionRefreshStatus

    public init(version: String?, status: HostVersionRefreshStatus) {
        self.version = version
        self.status = status
    }
}

public struct HostVersionObservationTime: Sendable {
    public let wall: TimeInterval
    public let uptime: TimeInterval

    public init(
        wall: TimeInterval = Date().timeIntervalSince1970,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.wall = wall
        self.uptime = uptime
    }
}

public protocol HostVersionSignatureValidating: Sendable {
    func accepts(host: HostID, executable: URL) -> Bool
}

/// Cold-fill validation only. No codesign subprocess and no network/notarization lookup.
public struct SystemHostVersionSignatureValidator: HostVersionSignatureValidating {
    public init() {}

    public func accepts(host: HostID, executable: URL) -> Bool {
        let identifier: String
        let team: String
        switch host {
        case .claudeCode: identifier = "com.anthropic.claude-code"; team = "Q6L2SF6YDW"
        case .codex: identifier = "codex"; team = "2DC432GLL2"
        default: return false
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            let code, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(
            code, SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate)),
            requirement) == errSecSuccess
    }
}

/// Sole owner of host version resolution; only Claude native observations qualify for reuse.
/// Codex always probes. A nil directory deliberately leaves disk
/// caching disabled: production activation is a separate gate from local implementation.
/// Only version text is reused; callers still build the complete activation scope themselves.
public struct HostVersionResolver: Sendable {
    private let cacheDirectory: URL?
    private let homeDirectory: URL
    private let locator: HostExecutableLocator
    private let runner: any CommandRunning
    private let signatureValidator: any HostVersionSignatureValidating
    private let now: @Sendable () -> HostVersionObservationTime
    private let maximumAge: TimeInterval

    public init(
        cacheDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil,
        signatureValidator: any HostVersionSignatureValidating =
            SystemHostVersionSignatureValidator(),
        maximumAge: TimeInterval = 600,
        now: @escaping @Sendable () -> HostVersionObservationTime = { .init() }
    ) {
        self.cacheDirectory = cacheDirectory?.standardizedFileURL
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        locator = executableLocator
        runner =
            commandRunner
            ?? SystemCommandRunner(
                environmentOverrides: ["PATH": executableLocator.executableSearchPath])
        self.signatureValidator = signatureValidator
        self.maximumAge = maximumAge.isFinite ? min(600, max(0, maximumAge)) : 0
        self.now = now
    }

    public func resolve(_ host: HostID, mode: HostVersionResolutionMode) -> String? {
        // A TaskLocal context can exist before authorization is held. Only an acquired final
        // publication lease forbids probing; never turn that lease into a subprocess wait.
        guard HostPublicationContext.current?.isLeaseHeld != true,
            host == .claudeCode || host == .codex
        else { return nil }
        return HookMeasurementContext.measure(.versionResolution) {
            resolveVersion(host, mode: mode)
        }
    }

    private func resolveVersion(_ host: HostID, mode: HostVersionResolutionMode) -> String? {
        let command = host == .claudeCode ? "claude" : "codex"
        guard let call = locator.executablePath(command: command) else { return nil }
        let before = cacheDirectory == nil ? nil : candidate(host, call: call)
        let started = now()
        let observation =
            mode == .reuseValidated
            ? before.flatMap { candidate in
                readEntries(host).first { $0.identity == candidate.identity }
            } : nil
        if let before, let entry = observation,
            isFresh(entry, at: started), entry.version == before.expectedOutput,
            locator.executablePath(command: command) == call,
            candidate(host, call: call) == before
        {
            let finished = now()
            if validInterval(from: started, to: finished), isFresh(entry, at: finished) {
                return entry.version
            }
        }
        // Invocation uses the original locator path, never the resolved target: argv[0] matters.
        guard let version = probe(call) else {
            // Revoke only the exact observation this invocation saw. A late failed probe
            // must not delete a newer explicit refresh, even when clock values are equal.
            if let observation { discard(host, observation: observation) }
            return nil
        }
        if let before {
            guard locator.executablePath(command: command) == call,
                candidate(host, call: call) == before
            else { return nil }
        }
        // Both resolution modes stop here: no signature validation, fill, or TTL renewal.
        return version
    }

    private func probe(_ call: String) -> String? {
        guard
            case .completed(0, let output) = runner.run(
                executablePath: call, arguments: ["--version"], timeout: 1)
        else { return nil }
        return Self.normalized(output)
    }

    /// Explicit cold fill only. Callers own lifecycle scheduling; this synchronous operation
    /// must run outside UI/manager executors and all event or integration publication locks.
    /// Cancellation prevents publication, but cannot interrupt a synchronous Security call.
    public func refresh(
        _ host: HostID, isCurrent: @Sendable () -> Bool = { !Task.isCancelled }
    ) -> HostVersionRefreshResult {
        guard host == .claudeCode || host == .codex else {
            return .init(version: nil, status: .unsupportedHost)
        }
        guard HostPublicationContext.current?.isLeaseHeld != true else {
            return .init(version: nil, status: .publicationLeaseHeld)
        }
        guard isCurrent() else { return .init(version: nil, status: .cancelled) }
        guard let cacheDirectory else {
            return .init(version: resolve(host, mode: .forceProbe), status: .disabled)
        }
        let command = host == .claudeCode ? "claude" : "codex"
        guard let call = locator.executablePath(command: command) else {
            return .init(version: nil, status: .probeFailed)
        }
        guard candidate(host, call: call) != nil else {
            return .init(version: resolve(host, mode: .forceProbe), status: .ineligible)
        }
        guard prepareDirectory() else { return .init(version: nil, status: .writeFailed) }
        let operationFile = cacheDirectory.appendingPathComponent("\(host.rawValue).refresh.lock")
        guard privateFile(operationFile, allowMissing: true) else {
            return .init(version: nil, status: .writeFailed)
        }
        let lock = FileLock(path: operationFile.path)
        switch lock.attemptLock() {
        case .busy: return .init(version: nil, status: .busy)
        case .failed: return .init(version: nil, status: .writeFailed)
        case .acquired: break
        }
        defer { lock.unlock() }
        guard privateDirectory(), privateFile(operationFile, allowMissing: false),
            let operationIdentity = Node.read(operationFile),
            locator.executablePath(command: command) == call,
            let before = candidate(host, call: call)
        else { return .init(version: nil, status: .identityChanged) }
        guard isCurrent() else { return .init(version: nil, status: .cancelled) }

        // Withdraw the replaced observation before probing. A failed refresh cannot leave
        // its old entry reusable. The short write lock is released before either slow call.
        let revoked = update(host) { entries in
            let retained = entries.filter { $0.identity != before.identity }
            return retained.count == entries.count ? nil : retained
        }
        switch revoked {
        case .busy: return .init(version: nil, status: .busy)
        case .failed: return .init(version: nil, status: .writeFailed)
        case .applied, .unchanged: break
        }
        let started = now()
        guard isCurrent() else { return .init(version: nil, status: .cancelled) }
        guard let version = probe(call) else {
            return .init(version: nil, status: .probeFailed)
        }
        let observed = now()
        guard locator.executablePath(command: command) == call,
            candidate(host, call: call) == before
        else { return .init(version: nil, status: .identityChanged) }
        guard isCurrent() else { return .init(version: nil, status: .cancelled) }
        guard validInterval(from: started, to: observed) else {
            return .init(version: version, status: .expired)
        }
        guard version == before.expectedOutput else {
            return .init(version: version, status: .ineligible)
        }
        let signed = signatureValidator.accepts(host: host, executable: before.target)
        guard isCurrent() else { return .init(version: nil, status: .cancelled) }
        guard locator.executablePath(command: command) == call,
            candidate(host, call: call) == before
        else { return .init(version: nil, status: .identityChanged) }
        guard signed else { return .init(version: version, status: .ineligible) }
        let entry = Entry(
            identity: before.identity, version: version, wall: observed.wall,
            uptime: observed.uptime, generation: UUID())
        var refusal: HostVersionRefreshStatus = .writeFailed
        let published = update(host) { entries in
            guard isCurrent() else { refusal = .cancelled; return nil }
            guard Node.read(operationFile) == operationIdentity,
                locator.executablePath(command: command) == call,
                candidate(host, call: call) == before
            else { refusal = .identityChanged; return nil }
            let publishing = now()
            guard validInterval(from: started, to: publishing), isFresh(entry, at: publishing)
            else {
                refusal = .expired; return nil
            }
            let retained = entries.filter {
                $0.identity != entry.identity && isFresh($0, at: publishing)
            }.sorted { $0.wall > $1.wall }
            return [entry] + retained.prefix(3)
        }
        let status: HostVersionRefreshStatus =
            switch published {
            case .applied: .published
            case .unchanged: refusal
            case .busy: .busy
            case .failed: .writeFailed
            }
        return .init(
            version: status == .identityChanged || status == .cancelled ? nil : version,
            status: status)
    }

    private static func normalized(_ value: String) -> String? {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty || normalized.utf8.count > 256 ? nil : normalized
    }

    private struct Candidate: Equatable {
        let target: URL
        let identity: String
        let expectedOutput: String
    }

    private func candidate(_ host: HostID, call: String) -> Candidate? {
        // Codex package resources/PATH have not been proven independent of version probing.
        // Until that dependency boundary is verified, both modes retain the real probe.
        guard host == .claudeCode else { return nil }
        let original = URL(fileURLWithPath: call)
        let target = original.resolvingSymlinksInPath().standardizedFileURL
        guard let binary = Node.read(target), binary.isRegular,
            binary.mode & 0o022 == 0,
            binary.owner == geteuid() || binary.owner == 0,
            let callChain = Self.pathIdentity(original),
            let targetChain = Self.pathIdentity(target)
        else { return nil }
        let versions = homeDirectory.appendingPathComponent(".local/share/claude/versions")
        let version = target.lastPathComponent
        guard target.deletingLastPathComponent() == versions, Self.releaseVersion(version)
        else { return nil }
        let dependencies = [call, target.path, binary.token, callChain, targetChain]
        return Candidate(
            target: target,
            identity: Self.digest(Data(dependencies.joined(separator: "\u{0}").utf8)),
            expectedOutput: "\(version) (Claude Code)")
    }

    private static func releaseVersion(_ value: String) -> Bool {
        value.range(
            of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$",
            options: .regularExpression) != nil
    }

    private static func digest(_ bytes: Data) -> String {
        // Preserve the schema-1 lowercase SHA-256 identity without 32 Foundation formatter calls.
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: bytes) {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Include every lexical link/directory identity. Directory timestamps are excluded because
    /// unrelated sibling creation is not a version dependency; leaf/link ctime and nanoseconds are.
    private static func pathIdentity(_ path: URL) -> String? {
        var current = URL(fileURLWithPath: "/")
        var tokens: [String] = []
        for component in path.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let node = Node.read(current) else { return nil }
            tokens.append(node.isDirectory ? node.directoryToken : node.token)
        }
        return tokens.joined(separator: ":")
    }

    private struct Node: Equatable {
        let device: Int32
        let inode: UInt64
        let owner: UInt32
        let group: UInt32
        let mode: UInt16
        let links: UInt16
        let size: Int64
        let modified: Int
        let modifiedNS: Int
        let changed: Int
        let changedNS: Int
        var isRegular: Bool { mode & S_IFMT == S_IFREG }
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var directoryToken: String { "\(device):\(inode):\(owner):\(group):\(mode)" }
        var token: String {
            "\(directoryToken):\(links):\(size):\(modified):\(modifiedNS):\(changed):\(changedNS)"
        }
        static func read(_ url: URL) -> Node? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return Node(
                device: info.st_dev, inode: info.st_ino, owner: info.st_uid, group: info.st_gid,
                mode: info.st_mode, links: info.st_nlink, size: info.st_size,
                modified: info.st_mtimespec.tv_sec, modifiedNS: info.st_mtimespec.tv_nsec,
                changed: info.st_ctimespec.tv_sec, changedNS: info.st_ctimespec.tv_nsec)
        }
    }

    private struct Entry: Codable, Equatable {
        let identity: String
        let version: String
        let wall: TimeInterval
        let uptime: TimeInterval
        // Optional for schema-1 compatibility; new refreshes are distinct even at equal clocks.
        let generation: UUID?
    }
    private struct Document: Codable {
        let schema: Int
        let entries: [Entry]
    }
    private func validInterval(from: HostVersionObservationTime, to: HostVersionObservationTime)
        -> Bool
    {
        guard from.wall.isFinite, from.uptime.isFinite, to.wall.isFinite, to.uptime.isFinite,
            from.uptime >= 0, to.wall >= from.wall, to.uptime >= from.uptime
        else { return false }
        return abs((to.wall - from.wall) - (to.uptime - from.uptime)) <= 5
    }
    private func isFresh(_ entry: Entry, at time: HostVersionObservationTime) -> Bool {
        validInterval(from: .init(wall: entry.wall, uptime: entry.uptime), to: time)
            && time.wall - entry.wall < maximumAge && time.uptime - entry.uptime < maximumAge
            && Self.normalized(entry.version) == entry.version
    }

    private func file(_ host: HostID) -> URL? {
        cacheDirectory?.appendingPathComponent("\(host.rawValue).json")
    }
    private func privateDirectory() -> Bool {
        guard let cacheDirectory,
            (try? validateExistingDirectoryComponents(of: cacheDirectory)) != nil,
            let node = Node.read(cacheDirectory), node.isDirectory,
            node.owner == geteuid(), node.mode & 0o777 == 0o700
        else { return false }
        return true
    }
    private func privateFile(_ file: URL, allowMissing: Bool) -> Bool {
        guard let node = Node.read(file) else { return allowMissing && errno == ENOENT }
        return node.isRegular && node.links == 1 && node.owner == geteuid()
            && node.mode & 0o777 == 0o600
    }
    private func decode(_ bytes: Data?) -> [Entry] {
        guard let bytes, let document = try? JSONDecoder().decode(Document.self, from: bytes),
            document.schema == 1, document.entries.count <= 4,
            Set(document.entries.map(\.identity)).count == document.entries.count
        else { return [] }
        return document.entries
    }
    private func readEntries(_ host: HostID) -> [Entry] {
        guard privateDirectory(), let file = file(host), privateFile(file, allowMissing: false),
            let before = Node.read(file),
            let io = try? AnchoredFileIO(file: file, preserveFinalSymlink: false),
            let snapshot = try? io.read(maxBytes: 16_384), Node.read(file) == before
        else { return [] }
        return decode(snapshot.data)
    }
    private enum Mutation { case applied, unchanged, busy, failed }

    private func prepareDirectory() -> Bool {
        guard let cacheDirectory else { return false }
        // Never repair/chmod unsafe existing state.
        if Node.read(cacheDirectory) == nil {
            guard errno == ENOENT,
                (try? ensurePrivateDirectoryExists(at: cacheDirectory)) != nil
            else { return false }
        }
        return privateDirectory()
    }

    /// No directory creation: misses and failed hook probes must not become cold fills.
    private func update(_ host: HostID, _ body: ([Entry]) -> [Entry]?) -> Mutation {
        guard let cacheDirectory, let file = file(host), privateDirectory(),
            privateFile(file, allowMissing: true)
        else { return .failed }
        let lockFile = cacheDirectory.appendingPathComponent("\(host.rawValue).lock")
        guard privateFile(lockFile, allowMissing: true) else { return .failed }
        let result = withNonBlockingLock(path: lockFile.path) { () -> Mutation in
            guard privateDirectory(), privateFile(lockFile, allowMissing: false),
                privateFile(file, allowMissing: true),
                let io = try? AnchoredFileIO(file: file, preserveFinalSymlink: false),
                let snapshot = try? io.read(maxBytes: 16_384)
            else { return .failed }
            guard let entries = body(decode(snapshot.data)) else { return .unchanged }
            guard let bytes = try? JSONEncoder().encode(Document(schema: 1, entries: entries)),
                bytes.count <= 16_384
            else { return .failed }
            do {
                try io.publish(bytes, expected: snapshot)
                guard try io.read(maxBytes: 16_384).data == bytes,
                    privateDirectory(), privateFile(file, allowMissing: false)
                else { return .failed }
                return .applied
            } catch { return .failed }
        }
        switch result {
        case .ran(let value): return value
        case .skipped: return .busy
        case .failed: return .failed
        }
    }

    private func discard(_ host: HostID, observation: Entry) {
        _ = update(host) { entries in
            let retained = entries.filter { $0 != observation }
            return retained.count == entries.count ? nil : retained
        }
    }
}
