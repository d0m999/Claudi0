import Darwin
import Foundation

public struct HostGUIRunIdentity: Codable, Sendable, Equatable {
    public let runID: UUID
    public let process: HostProcessIdentity
    public let userID: UInt32

    public init(runID: UUID = UUID(), process: HostProcessIdentity, userID: UInt32) {
        self.runID = runID
        self.process = process
        self.userID = userID
    }
}

/// Independent of the optional notice receiver. Kernel start identity rejects PID reuse/zombies.
public struct HostGUIRunRegistry: Sendable {
    public let file: URL
    public let authorizationLockFile: URL
    private let readProcess: @Sendable (Int32) -> HostProcessSnapshot?

    public init(
        file: URL = ClaudioPaths.root.appendingPathComponent("gui-run.json"),
        authorizationLockFile: URL = ClaudioPaths.root.appendingPathComponent(
            "host-authorization.lock"),
        readProcess: @escaping @Sendable (Int32) -> HostProcessSnapshot? = Self.liveProcess
    ) {
        self.file = file
        self.authorizationLockFile = authorizationLockFile
        self.readProcess = readProcess
    }

    public static func liveProcess(_ pid: Int32) -> HostProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_status != 5,  // SZOMB, deliberately fail closed before reading identity.
            info.pbi_uid == getuid(), info.pbi_ruid == getuid()
        else { return nil }
        return HostProcessAncestry.read(pid)
    }

    public func current() -> HostGUIRunIdentity? {
        guard
            case .success(let bytes) = readRegularFileBounded(
                at: file, maxBytes: 4096, followSymlink: false),
            let identity = try? JSONDecoder().decode(HostGUIRunIdentity.self, from: bytes),
            identity.userID == getuid(),
            let process = readProcess(identity.process.pid),
            process.identity == identity.process, process.userID == identity.userID
        else { return nil }
        return identity
    }

    public func register() -> Result<HostGUIRunIdentity, ConfigFileTransactionError> {
        guard let process = readProcess(getpid()) else {
            return .failure(.mutationRejected(reason: "无法验证 GUI 运行身份"))
        }
        let identity = HostGUIRunIdentity(process: process.identity, userID: process.userID)
        let boundary = HostPublicationContext.unconditional(lockFile: authorizationLockFile)
        defer { boundary.release() }
        return HostPublicationContext.$current.withValue(boundary) {
            do { try ensurePrivateDirectoryTree(at: file.deletingLastPathComponent()) } catch {
                return .failure(.writeFailure(reason: "GUI 运行目录不可写"))
            }
            let transaction = ConfigFileTransaction(
                file: file,
                lockFile: file.appendingPathExtension("lock"), symlinkPolicy: .reject,
                maximumBytes: 4096)
            return transaction.updateBytes { bytes in
                // Never supersede another verifiably live app instance.
                if let active = current() {
                    guard active.process == identity.process else {
                        throw ConfigFileTransactionError.lockBusy
                    }
                    return .unchanged(active)
                }
                return .replace(try JSONEncoder().encode(identity), identity)
            }.map(\.value)
        }
    }

    public func revoke(runID: UUID) -> Result<Void, ConfigFileTransactionError> {
        withBoundary {
            guard
                case .success(let bytes) = readRegularFileBounded(
                    at: file, maxBytes: 4096, followSymlink: false),
                let stored = try? JSONDecoder().decode(HostGUIRunIdentity.self, from: bytes),
                stored.runID == runID
            else { return .success(()) }
            do {
                let anchored = try AnchoredFileIO(file: file, preserveFinalSymlink: false)
                let snapshot = try anchored.read(maxBytes: 4096)
                guard snapshot.data == bytes else {
                    return .failure(.concurrentModification(path: file.path))
                }
                try anchored.remove(expected: snapshot)
                return .success(())
            } catch { return .failure(.writeFailure(reason: "GUI 运行注册撤销失败")) }
        }
    }

    private func withBoundary<T>(_ body: () -> Result<T, ConfigFileTransactionError>)
        -> Result<T, ConfigFileTransactionError>
    {
        switch withNonBlockingLock(path: authorizationLockFile.path, body) {
        case .ran(let result): result
        case .skipped: .failure(.lockBusy)
        case .failed(let code): .failure(.lockFailed(errno: code))
        }
    }
}

public struct HostEventAuthorizationToken: Sendable, Equatable {
    public let surface: HostSurfaceID
    public let intent: HostIntegrationIntent
    public let run: HostGUIRunIdentity?
}

public enum HostPublicationEffect: Sendable, Equatable {
    case activity, deduplication, receipt, audio, notice
}

public enum HostPublicationDecision: String, Sendable { case allowed, stale, busy, unavailable }

public struct HostEventAuthorization: Sendable {
    public let intents: HostIntegrationIntentStore
    public let runs: HostGUIRunRegistry

    public init(intents: HostIntegrationIntentStore = .init(), runs: HostGUIRunRegistry = .init()) {
        self.intents = intents
        self.runs = runs
    }

    public func capture(surface: HostSurfaceID, requiresGUI: Bool = true)
        -> HostEventAuthorizationToken?
    {
        guard let intent = intents.intent(for: surface), !requiresGUI || intent.enabled else {
            return nil
        }
        let run = requiresGUI ? runs.current() : nil
        guard !requiresGUI || run != nil else { return nil }
        return HostEventAuthorizationToken(surface: surface, intent: intent, run: run)
    }

    public func isCurrent(_ token: HostEventAuthorizationToken) -> Bool {
        intents.intent(for: token.surface) == token.intent
            && (token.run.map { runs.current() == $0 } ?? true)
    }

    public func accepts(_ notice: HostEventNotice) -> Bool {
        guard let revision = notice.intentRevision,
            let token = capture(surface: notice.surface)
        else { return false }
        return token.intent.revision == revision
    }
}

/// A synchronous publication scope. Only final disk rename/marker, bounded local commits,
/// dedup consumption, spawn and datagram send run inside it. Never version probes or await.
public final class HostPublicationContext: @unchecked Sendable {
    @TaskLocal public static var current: HostPublicationContext?
    public let token: HostEventAuthorizationToken?
    private let authorization: HostEventAuthorization?
    private let lockFile: URL
    private var lease: FileLock?
    private let beforePublication: @Sendable (HostPublicationEffect) -> Void

    public init(
        authorization: HostEventAuthorization, token: HostEventAuthorizationToken,
        beforePublication: @escaping @Sendable (HostPublicationEffect) -> Void = { _ in }
    ) {
        self.authorization = authorization
        self.beforePublication = beforePublication
        self.token = token
        lockFile = authorization.intents.authorizationLockFile
    }

    private init(lockFile: URL) {
        self.lockFile = lockFile
        authorization = nil
        beforePublication = { _ in }
        token = nil
    }

    public static func unconditional(lockFile: URL) -> HostPublicationContext {
        .init(lockFile: lockFile)
    }

    public func acquire() -> HostPublicationDecision {
        if lease != nil { return .allowed }
        let lock = FileLock(path: lockFile.path)
        switch lock.attemptLock() {
        case .busy: return .busy
        case .failed: return .unavailable
        case .acquired:
            if let token, let authorization, !authorization.isCurrent(token) { return .stale }
            lease = lock
            return .allowed
        }
    }

    public func require() throws {
        switch acquire() {
        case .allowed: return
        case .busy: throw ConfigFileTransactionError.lockBusy
        case .stale: throw ConfigFileTransactionError.mutationRejected(reason: "接入意愿或 GUI 运行身份已改变")
        case .unavailable: throw ConfigFileTransactionError.mutationRejected(reason: "事件发布许可不可用")
        }
    }

    public func release() { lease = nil }

    public func willPublish(_ effect: HostPublicationEffect) { beforePublication(effect) }

    public func perform<T>(effect: HostPublicationEffect? = nil, rejected: T, _ body: () -> T) -> T
    {
        if let effect { beforePublication(effect) }
        let alreadyHeld = lease != nil
        guard acquire() == .allowed else { return rejected }
        defer { if !alreadyHeld { release() } }
        return body()
    }

    deinit { lease = nil }
}
