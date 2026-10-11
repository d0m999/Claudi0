import ClaudioCore
import Darwin
import Foundation

private func versionFixtureWrite(_ value: String, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(value.utf8).write(to: url, options: .atomic)
}

final class VersionTestRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var result: CommandRunResult
    var action: (@Sendable () -> Void)?
    private var invocations: [String] = []
    private var probeArguments: [[String]] = []
    private var probeTimeouts: [TimeInterval] = []
    init(_ output: String = "2.1.282 (Claude Code)") {
        result = .completed(exitCode: 0, stdout: output)
    }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        lock.lock()
        invocations.append(executablePath)
        probeArguments.append(arguments)
        probeTimeouts.append(timeout)
        lock.unlock()
        action?()
        return result
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return invocations }
    var arguments: [[String]] { lock.lock(); defer { lock.unlock() }; return probeArguments }
    var timeouts: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return probeTimeouts }
}
final class VersionTestSignature: HostVersionSignatureValidating, @unchecked Sendable {
    var allowed = true
    private let lock = NSLock()
    private var count = 0
    func accepts(host: HostID, executable: URL) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        return allowed
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class VersionTestClock: @unchecked Sendable {
    var wall: Double = 10_000
    var uptime: Double = 1_000
    var value: HostVersionObservationTime { .init(wall: wall, uptime: uptime) }
    func advance(_ delta: Double) { wall += delta; uptime += delta }
}
private final class VersionTestObservationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let values: [HostVersionObservationTime]
    init(_ values: [HostVersionObservationTime]) { self.values = values }
    var value: HostVersionObservationTime {
        lock.lock(); defer { lock.unlock() }
        let result = values[min(index, values.count - 1)]
        index += 1
        return result
    }
}
private final class VersionTestHookScope: @unchecked Sendable {
    private let lock = NSLock()
    private let host: HostID
    private let resolver: HostVersionResolver
    private var resolved = false
    private var stored: String?
    private var count = 0
    init(host: HostID, resolver: HostVersionResolver) {
        self.host = host; self.resolver = resolver
    }
    var value: String? {
        lock.lock(); defer { lock.unlock() }
        if !resolved {
            stored = HostActivationScope.current(
                for: host, versionResolver: resolver, mode: .reuseValidated)
            resolved = true
            count += 1
        }
        return stored
    }
    var resolutions: Int { lock.lock(); defer { lock.unlock() }; return count }
}
struct VersionTestFixture {
    let root: URL
    let host: HostID
    let target: URL
    let call: URL
    let metadata: URL?
    let runner: VersionTestRunner
    let signer = VersionTestSignature()
    let clock = VersionTestClock()
    var cache: URL { root.appendingPathComponent("cache") }
    var file: URL { cache.appendingPathComponent("\(host.rawValue).json") }
    var locator: HostExecutableLocator {
        .init(searchDirectories: [call.deletingLastPathComponent()])
    }
    init(_ root: URL, host: HostID = .claudeCode, version: String = "2.1.282") {
        self.root = root; self.host = host
        let command = host == .claudeCode ? "claude" : "codex"
        call = root.appendingPathComponent("bin/\(command)")
        if host == .claudeCode {
            target = root.appendingPathComponent(".local/share/claude/versions/\(version)")
            metadata = nil
            runner = VersionTestRunner("\(version) (Claude Code)")
        } else {
            target = root.appendingPathComponent("package/bin/codex")
            metadata = root.appendingPathComponent("package/codex-package.json")
            runner = VersionTestRunner("codex-cli \(version)")
        }
        versionFixtureWrite("#!/bin/sh\nprintf 'fixture'\n", to: target)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: target.path)
        try! FileManager.default.createDirectory(
            at: call.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(
            atPath: call.path, withDestinationPath: target.path)
        if let metadata {
            versionFixtureWrite(
                """
                {"layoutVersion":1,"version":"\(version)","target":"aarch64-apple-darwin","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}
                """, to: metadata)
            for name in ["codex-resources", "codex-path"] {
                try! FileManager.default.createDirectory(
                    at: metadata.deletingLastPathComponent().appendingPathComponent(name),
                    withIntermediateDirectories: true)
            }
        }
    }
    func resolver(cache override: URL? = nil, maximumAge: Double = 600) -> HostVersionResolver {
        .init(
            cacheDirectory: override ?? cache, homeDirectory: root,
            executableLocator: locator, commandRunner: runner, signatureValidator: signer,
            maximumAge: maximumAge, now: { [clock] in clock.value })
    }
    func refresh() -> HostVersionRefreshResult { resolver().refresh(host) }
    func resolve(_ mode: HostVersionResolutionMode = .reuseValidated) -> String? {
        resolver().resolve(host, mode: mode)
    }
}

@MainActor
func runHostVersionResolverSuites() {
    suite("version cache: explicit refresh qualifies observations; forced probes never renew") {
        for host in [HostID.claudeCode] {
            withTempDirectory { root in
                let f = VersionTestFixture(root, host: host)
                let first = f.refresh().version
                expect(
                    first != nil && f.runner.calls == [f.call.path],
                    "explicit refresh uses original call path once")
                expect(
                    f.resolve() == first && f.runner.calls.count == 1 && f.signer.calls == 1,
                    "new resolver instance hits disk without probe or signature validation")
                let original = try! Data(contentsOf: f.file)
                f.clock.advance(20)
                expect(
                    f.resolve(.forceProbe) == first && f.runner.calls.count == 2
                        && f.signer.calls == 1 && (try? Data(contentsOf: f.file)) == original,
                    "force mode probes without signature, write or renewal")
                expect(
                    f.refresh().status == .published && f.runner.calls.count == 3
                        && f.signer.calls == 2, "only explicit refresh renews the observation")
                expect(
                    f.resolve() == first && f.runner.calls.count == 3,
                    "explicitly refreshed observation is reusable")
                let bytes = try! Data(contentsOf: f.file)
                expect(
                    !String(decoding: bytes, as: UTF8.self).contains(root.path),
                    "cache stores digests, not private paths or complete scopes")
                let mode =
                    try! FileManager.default.attributesOfItem(atPath: f.file.path)[
                        .posixPermissions] as! NSNumber
                expect(mode.intValue == 0o600 && bytes.count < 16_384, "bounded private cache")
            }
        }
    }
    suite("version cache: independent helper processes share only validated disk observation") {
        for host in [HostID.claudeCode, .codex] {
            withTempDirectory { root in
                _ = VersionTestFixture(root, host: host)
                for action in ["refresh", "resolve"] {
                    let expectedProbes = host == .codex || action == "refresh" ? 1 : 0
                    let expectedSignatures = host == .claudeCode && action == "refresh" ? 1 : 0
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    process.arguments = [
                        "--host-version-cache-child", root.path, host.rawValue,
                        action,
                    ]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try! process.run()
                    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                    expect(
                        process.terminationStatus == 0
                            && result?["probes"] as? Int == expectedProbes
                            && result?["signatures"] as? Int == expectedSignatures
                            && result?["resolved"] as? Bool == true,
                        "separate process: qualified Claude hit or real Codex fallback")
                }
            }
        }
    }
    suite("version cache: clock rollback during a hit requires a real probe") {
        for host in [HostID.claudeCode] {
            withTempDirectory { root in
                let f = VersionTestFixture(root, host: host)
                let version = f.refresh().version
                let clock = VersionTestObservationSequence([
                    .init(wall: 10_100, uptime: 1_100),
                    .init(wall: 10_099, uptime: 1_100.001),
                ])
                let resolver = HostVersionResolver(
                    cacheDirectory: f.cache, homeDirectory: root,
                    executableLocator: f.locator, commandRunner: f.runner,
                    signatureValidator: f.signer, now: { clock.value })
                expect(
                    resolver.resolve(host, mode: .reuseValidated) == version, "probe remains usable"
                )
                expect(
                    f.runner.calls.count == 2,
                    "in-call wall rollback cannot reuse a cached observation")
            }
        }
    }
    suite("version cache: expiry, rollback, reboot and clock skew miss without negative cache") {
        for anomaly in ["expiry", "wall-back", "uptime-back", "skew"] {
            withTempDirectory { root in
                let f = VersionTestFixture(root)
                _ = f.refresh()
                switch anomaly {
                case "expiry": f.clock.advance(600)
                case "wall-back": f.clock.wall -= 1
                case "uptime-back": f.clock.uptime -= 1
                default: f.clock.wall += 60
                }
                expect(f.resolve() != nil && f.runner.calls.count == 2, "\(anomaly) must probe")
                f.runner.result = .timedOut
                expect(
                    f.refresh().version == nil,
                    "failed forced probe rejects instead of stale fallback")
                expect(
                    f.resolve() == nil && f.runner.calls.count == 4,
                    "failure removes obsolete observation; next call probes again")
                f.runner.result = .completed(exitCode: 0, stdout: "2.1.282 (Claude Code)")
                expect(
                    f.resolve() != nil && f.runner.calls.count == 5,
                    "failure is not negatively cached")
            }
        }
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            _ = f.resolver(maximumAge: 60_000).refresh(.claudeCode)
            f.clock.advance(600)
            _ = f.resolver(maximumAge: 60_000).resolve(.claudeCode, mode: .reuseValidated)
            expect(f.runner.calls.count == 2, "caller cannot extend ten-minute ceiling")
        }
    }
    suite("version cache: Claude identities invalidate; Codex metadata stays ineligible") {
        for change in ["target", "link", "metadata", "layout"] {
            withTempDirectory { root in
                let f = VersionTestFixture(
                    root, host: change == "metadata" || change == "layout" ? .codex : .claudeCode)
                _ = f.refresh()
                if change == "target" { versionFixtureWrite("#!/bin/sh\nexit 0\n", to: f.target) }
                if change == "link" {
                    try! FileManager.default.removeItem(at: f.call)
                    try! FileManager.default.createSymbolicLink(
                        atPath: f.call.path, withDestinationPath: f.target.path)
                }
                if let metadata = f.metadata {
                    var text = try! String(contentsOf: metadata, encoding: .utf8)
                    text += "\n"
                    if change == "layout" {
                        text = text.replacingOccurrences(
                            of: "\"layoutVersion\":1", with: "\"layoutVersion\":2")
                    }
                    versionFixtureWrite(text, to: metadata)
                }
                expect(
                    f.resolve() != nil && f.runner.calls.count == 2,
                    "\(change) cannot reuse old identity")
            }
        }
    }
    suite("version cache: same-inode mutation and PATH selection cannot keep old observation") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            _ = f.refresh()
            let before = try! FileManager.default.attributesOfItem(atPath: f.target.path)
            let bytes = try! Data(contentsOf: f.target)
            let handle = try! FileHandle(forWritingTo: f.target)
            try! handle.write(contentsOf: bytes)
            try! handle.close()
            try! FileManager.default.setAttributes(
                [.modificationDate: before[.modificationDate]!], ofItemAtPath: f.target.path)
            let after = try! FileManager.default.attributesOfItem(atPath: f.target.path)
            expect(
                (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber),
                "mutation fixture preserves inode")
            expect(
                f.resolve() != nil && f.runner.calls.count == 2,
                "ctime invalidates even if inode/size/mtime are restored")
            let preferred = root.appendingPathComponent("preferred")
            let resolver = HostVersionResolver(
                cacheDirectory: f.cache, homeDirectory: root,
                executableLocator: .init(searchDirectories: [
                    preferred, f.call.deletingLastPathComponent(),
                ]), commandRunner: f.runner, signatureValidator: f.signer, now: { f.clock.value })
            _ = resolver.resolve(.claudeCode, mode: .reuseValidated)
            let shim = preferred.appendingPathComponent("claude")
            versionFixtureWrite("#!/bin/sh\nexit 0\n", to: shim)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: shim.path)
            _ = resolver.resolve(.claudeCode, mode: .reuseValidated)
            expect(
                f.runner.calls.last == shim.path && f.runner.calls.count == 4,
                "re-locate PATH on every invocation")
        }
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let validator = SystemHostVersionSignatureValidator()
            expect(
                !validator.accepts(host: .claudeCode, executable: f.target),
                "unsigned fixture fails real Security API")
            expect(
                !validator.accepts(host: .codex, executable: URL(fileURLWithPath: "/usr/bin/true")),
                "other signed vendor is ineligible")
        }
    }
    suite("version cache: probe-time upgrade rejects result and never publishes it") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            f.runner.action = { versionFixtureWrite("changed during probe", to: f.target) }
            expect(
                f.resolve() == nil && !FileManager.default.fileExists(atPath: f.file.path),
                "changing dependencies cannot publish an observation or obsolete scope")
        }
    }
    suite("version cache: untrusted signature and mismatching package version only probe") {
        for invalid in ["signature", "version"] {
            withTempDirectory { root in
                let f = VersionTestFixture(root)
                if invalid == "signature" {
                    f.signer.allowed = false
                } else {
                    f.runner.result = .completed(exitCode: 0, stdout: "2.1.283 (Claude Code)")
                }
                expect(
                    f.refresh().status == .ineligible && f.resolve() != nil
                        && f.runner.calls.count == 2,
                    "\(invalid) cannot obtain reusable identity")
                expect(
                    !FileManager.default.fileExists(atPath: f.file.path),
                    "no unqualified cached version")
            }
        }
    }
    suite(
        "version cache: malformed, oversize, symlink, permissions and lock contention preserve probe result"
    ) {
        for corruption in [
            "json", "oversize", "symlink", "permissions", "busy", "root-symlink", "root-file",
        ] {
            withTempDirectory { root in
                let f = VersionTestFixture(root)
                let expected = f.refresh().version!
                var held: FileLock?
                switch corruption {
                case "json": versionFixtureWrite("not json", to: f.file)
                case "oversize":
                    versionFixtureWrite(String(repeating: "x", count: 20_000), to: f.file)
                case "symlink":
                    try! FileManager.default.removeItem(at: f.file)
                    let outside = root.appendingPathComponent("outside")
                    versionFixtureWrite("must remain", to: outside)
                    try! FileManager.default.createSymbolicLink(
                        atPath: f.file.path, withDestinationPath: outside.path)
                case "permissions":
                    try! FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: f.file.path)
                case "busy":
                    held = FileLock(path: f.cache.appendingPathComponent("claude-code.lock").path)
                    expect(held!.tryLock(), "hold writer lock")
                case "root-symlink":
                    let moved = root.appendingPathComponent("moved")
                    try! FileManager.default.moveItem(at: f.cache, to: moved)
                    try! FileManager.default.createSymbolicLink(
                        atPath: f.cache.path, withDestinationPath: moved.path)
                default:
                    try! FileManager.default.removeItem(at: f.cache)
                    versionFixtureWrite("unwritable cache root", to: f.cache)
                }
                if corruption == "busy" { f.clock.advance(600) }
                let start = ProcessInfo.processInfo.systemUptime
                expect(
                    f.resolve() == expected && f.runner.calls.count == 2,
                    "\(corruption): cache failure cannot discard successful probe")
                expect(
                    ProcessInfo.processInfo.systemUptime - start < 1, "writer never waits for lock")
                held?.unlock()
                if corruption == "symlink" {
                    expect(
                        (try? String(
                            contentsOf: root.appendingPathComponent("outside"), encoding: .utf8))
                            == "must remain", "never modify symlink target")
                }
            }
        }
    }
    suite("version cache: bounded retention, concurrent fills and no-cache default") {
        withTempDirectory { root in
            let cache = root.appendingPathComponent("shared-cache")
            for index in 0..<6 {
                let f = VersionTestFixture(
                    root.appendingPathComponent("v\(index)"), version: "2.1.\(index)")
                expect(
                    f.resolver(cache: cache).refresh(.claudeCode).status == .published,
                    "fill independent identity")
            }
            let object =
                try! JSONSerialization.jsonObject(
                    with: Data(contentsOf: cache.appendingPathComponent("claude-code.json")))
                as! [String: Any]
            expect((object["entries"] as? [Any])?.count == 4, "only four observations per host")
            let f = VersionTestFixture(root.appendingPathComponent("concurrent"))
            let resolver = f.resolver()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                _ = resolver.refresh(.claudeCode)
            }
            let filledCalls = f.runner.calls.count
            expect(
                f.resolve() != nil && f.runner.calls.count == filledCalls,
                "concurrent writes yield intact usable document")
            let noCache = HostVersionResolver(
                homeDirectory: f.root, executableLocator: f.locator, commandRunner: f.runner,
                signatureValidator: f.signer)
            _ = noCache.resolve(.claudeCode, mode: .reuseValidated)
            _ = noCache.resolve(.claudeCode, mode: .reuseValidated)
            expect(
                f.runner.calls.count == filledCalls + 2,
                "nil cache directory never activates persistence")
        }
    }
    suite("version cache: cached scope cannot replace live reception eligibility") {
        for host in [HostID.claudeCode, .codex] {
            for condition in ["allowed", "old-installation", "off", "gui-exited", "unverifiable"] {
                withTempDirectory { root in
                    let f = VersionTestFixture(root, host: host)
                    let resolver = f.resolver()
                    let scope = HostActivationScope.fingerprint(
                        host: host,
                        hostVersion: host == .codex
                            ? "cli=codex-cli 2.1.282" : "2.1.282 (Claude Code)")!
                    let config = root.appendingPathComponent("config.json")
                    let pack = root.appendingPathComponent("packs/test")
                    versionFixtureWrite(
                        "{\"id\":\"test\",\"name\":\"Test\",\"author\":\"Test\",\"version\":\"1\",\"events\":{\"task_start\":\"test.mp3\"}}",
                        to: pack.appendingPathComponent("manifest.json"))
                    versionFixtureWrite(
                        "synthetic sound", to: pack.appendingPathComponent("test.mp3"))
                    try! JSONEncoder().encode(ClaudioConfig(selectedPack: "test")).write(
                        to: config, options: .atomic)
                    let intents = HostIntegrationIntentStore(
                        configFile: config, lockFile: root.appendingPathComponent("config.lock"))
                    _ = try! intents.setEnabled(
                        surface: host.surfaceID, enabled: condition != "off"
                    ).get()
                    let runs = HostGUIRunRegistry(
                        file: root.appendingPathComponent("run.json"),
                        authorizationLockFile: intents.authorizationLockFile)
                    if condition != "gui-exited" { _ = try! runs.register().get() }
                    if condition == "unverifiable" {
                        versionFixtureWrite("{}", to: root.appendingPathComponent("run.json"))
                    }
                    let store = HostHookReceiptStore(
                        receiptsRoot: root.appendingPathComponent("receipts"),
                        locksRoot: root.appendingPathComponent("receipt-locks"))
                    let id = UUID()
                    _ = try! store.activate(host: host, installationID: id, scopeFingerprint: scope)
                        .get()
                    let activity = LocalActivitySummaryStore(
                        summaryFile: root.appendingPathComponent("activity.json"),
                        lockFile: root.appendingPathComponent("activity.lock"),
                        pendingDirectory: root.appendingPathComponent("pending"))
                    let effects = VersionTestEffects()
                    let play = PlayEnvironment(
                        surfaceID: host.surfaceID, afplayPath: "/synthetic/afplay",
                        lockFile: root.appendingPathComponent("play.lock"), configFile: config,
                        userPacksDirectory: root.appendingPathComponent("packs"),
                        systemSoundDirectory: root.appendingPathComponent("system-sounds"),
                        spawner: effects,
                        debounceStateFile: root.appendingPathComponent("play.state"),
                        logFile: root.appendingPathComponent("log"),
                        logLockFile: root.appendingPathComponent("log.lock"))
                    // Fixture preparation can secure parent permissions, which correctly
                    // changes the dependency identity. Prime only after all setup is complete.
                    expect(
                        resolver.refresh(host).status
                            == (host == .claudeCode ? .published : .ineligible),
                        "prime qualified Claude scope or probe ineligible Codex scope")
                    expect(
                        HostActivationScope.current(
                            for: host, versionResolver: resolver, mode: .reuseValidated) == scope
                            && HostActivationScope.current(
                                for: host, versionResolver: resolver, mode: .reuseValidated)
                                == scope
                            && f.runner.calls.count == (host == .claudeCode ? 1 : 3),
                        "Claude scope reuses cache; Codex scope probes every invocation")
                    let probesBeforeHook = f.runner.calls.count
                    let signaturesBeforeHook = f.signer.calls
                    let invocation = VersionTestHookScope(host: host, resolver: resolver)
                    let environment = HostHookEnvironment(
                        host: host, authorization: .init(intents: intents, runs: runs),
                        playEnvironment: play,
                        receiptStore: store, activityStore: activity,
                        eventNoticeChannel: .init(
                            sourcePayload: nil, receiverEpoch: UUID(),
                            sender: { _ in effects.notice() }),
                        scopeFingerprint: { invocation.value },
                        questionScopeFingerprint: { invocation.value })
                    let outcome = handleHostHook(
                        host: host, nativeEvent: "UserPromptSubmit",
                        installationID: condition == "old-installation" ? UUID() : id,
                        environment: environment)
                    let allowed = condition == "allowed"
                    expect(
                        invocation.resolutions
                            == (allowed || condition == "old-installation" ? 1 : 0),
                        "\(condition): hook resolves its own cached scope only after live admission"
                    )
                    expect(
                        outcome?.receiptWritten
                            == (allowed ? true : condition == "old-installation" ? false : nil),
                        "\(condition): receipt decision remains live")
                    expect(
                        effects.starts == (allowed ? 1 : 0) && effects.notices == (allowed ? 1 : 0),
                        "\(condition): cached scope cannot authorize audio/notice")
                    if case .ready(let document) = activity.read().state {
                        expect(
                            document.buckets.reduce(0) {
                                $0 + $1.count(host: host, event: .taskStart)
                            } == (allowed ? 1 : 0), "\(condition): live activity eligibility")
                    } else {
                        expect(!allowed, "accepted event commits activity")
                    }
                    expect(
                        f.runner.calls.count == probesBeforeHook
                            + (host == .codex && (allowed || condition == "old-installation")
                                ? 1 : 0)
                            && f.signer.calls == signaturesBeforeHook,
                        "Claude hits without probe; Codex probes only after live admission; neither signs"
                    )
                }
            }
        }
    }
    suite(
        "version cache: unknown dispatcher retains original argv0; publication lease forbids probing"
    ) {
        withTempDirectory { root in
            let tool = root.appendingPathComponent("bin/claude")
            let dispatcher = root.appendingPathComponent("bin/dispatch")
            versionFixtureWrite(
                "#!/bin/sh\ncase ${0##*/} in claude) printf '2.1.282 (Claude Code)' ;; *) exit 64 ;; esac\n",
                to: dispatcher)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dispatcher.path)
            try! FileManager.default.createSymbolicLink(
                atPath: tool.path, withDestinationPath: dispatcher.path)
            let resolver = HostVersionResolver(
                cacheDirectory: root.appendingPathComponent("cache"), homeDirectory: root,
                executableLocator: .init(searchDirectories: [tool.deletingLastPathComponent()]))
            expect(
                resolver.resolve(.claudeCode, mode: .reuseValidated) == "2.1.282 (Claude Code)",
                "real shim preserves argv0")
            expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path),
                "unknown shim never obtains cache")
            let f = VersionTestFixture(root.appendingPathComponent("known"))
            let context = HostPublicationContext.unconditional(
                lockFile: root.appendingPathComponent("auth.lock"))
            expect(context.acquire() == .allowed, "fixture publication lease")
            HostPublicationContext.$current.withValue(context) {
                expect(
                    f.resolve() == nil && f.runner.calls.isEmpty, "never spawn in publication lease"
                )
            }
            context.release()
        }
    }
}

private final class VersionTestEffects: ProcessSpawning, @unchecked Sendable {
    var starts = 0
    var notices = 0
    func spawn(executablePath: String, arguments: [String]) -> Bool { starts += 1; return true }
    func notice() -> EventNoticeSendOutcome { notices += 1; return .sent }
}

func runVersionCacheChild(root: URL, host value: String, action: String) {
    guard let host = HostID(rawValue: value), host == .claudeCode || host == .codex else { exit(2) }
    let runner = VersionTestRunner(
        host == .claudeCode ? "2.1.282 (Claude Code)" : "codex-cli 2.1.282")
    let signer = VersionTestSignature()
    let resolver = HostVersionResolver(
        cacheDirectory: root.appendingPathComponent("cache"), homeDirectory: root,
        executableLocator: .init(searchDirectories: [root.appendingPathComponent("bin")]),
        commandRunner: runner, signatureValidator: signer)
    if action == "hold-refresh" {
        runner.action = {
            try! Data().write(to: root.appendingPathComponent("entered"))
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("release").path)
            {
                if Date() > deadline { exit(3) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    let refreshed = action != "resolve" ? resolver.refresh(host) : nil
    let version =
        action == "resolve" ? resolver.resolve(host, mode: .reuseValidated) : refreshed?.version
    let bytes = try! JSONSerialization.data(withJSONObject: [
        "resolved": version != nil, "probes": runner.calls.count, "signatures": signer.calls,
        "refreshStatus": refreshed?.status.rawValue ?? "not-requested",
    ])
    print(String(decoding: bytes, as: UTF8.self))
}

@MainActor
func runCodexVersionFallbackSuites() {
    suite("version cache: Codex remains a bounded original-path probe without cache qualification")
    {
        withTempDirectory { root in
            let f = VersionTestFixture(root, host: .codex)
            let result = f.refresh()
            expect(
                result.status == .ineligible && result.version == "codex-cli 2.1.282",
                "unproven Codex dependency layout cannot qualify an observation")
            expect(
                f.signer.calls == 0 && !FileManager.default.fileExists(atPath: f.cache.path),
                "ineligible refresh does not sign or create the cache root")
            for mode in [HostVersionResolutionMode.reuseValidated, .forceProbe] {
                expect(f.resolve(mode) == "codex-cli 2.1.282", "both modes retain the real result")
            }
            expect(
                f.runner.calls == Array(repeating: f.call.path, count: 3)
                    && f.runner.arguments == Array(repeating: ["--version"], count: 3)
                    && f.runner.timeouts == Array(repeating: 1.0, count: 3),
                "probe preserves invocation path, version arguments and bounded timeout")
        }
    }
    suite("version cache: Codex legacy bytes and changing resources never supply a fallback value")
    {
        for change in ["resources", "path", "metadata", "missing-metadata"] {
            withTempDirectory { root in
                let f = VersionTestFixture(root, host: .codex)
                let legacy = Data(
                    "{\"schema\":1,\"entries\":[{\"identity\":\"legacy\",\"version\":\"codex-cli 0.1.0\",\"wall\":10000,\"uptime\":1000}]}"
                        .utf8)
                try! FileManager.default.createDirectory(
                    at: f.cache, withIntermediateDirectories: true)
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: f.cache.path)
                try! legacy.write(to: f.file)
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: f.file.path)
                if change == "missing-metadata" {
                    try! FileManager.default.removeItem(at: f.metadata!)
                } else if change == "metadata" {
                    versionFixtureWrite("{}", to: f.metadata!)
                } else {
                    let directory = change == "resources" ? "codex-resources" : "codex-path"
                    versionFixtureWrite(
                        "changed dependency",
                        to: root.appendingPathComponent("package/\(directory)/item"))
                }
                expect(
                    f.resolve() == "codex-cli 2.1.282" && f.runner.calls == [f.call.path],
                    "\(change): reuse always performs the actual probe")
                f.runner.result = .timedOut
                expect(f.resolve() == nil, "\(change): failed probe never uses old cache")
                let failed = f.refresh()
                expect(
                    failed.status == .ineligible && failed.version == nil,
                    "\(change): explicit refresh preserves failed version result")
                expect(
                    f.signer.calls == 0 && (try? Data(contentsOf: f.file)) == legacy,
                    "\(change): legacy bytes are preserved without signature work")
                expect(
                    (try! FileManager.default.contentsOfDirectory(atPath: f.cache.path)) == [
                        "codex.json"
                    ],
                    "\(change): no operation or write locks are created")
            }
        }
    }
}
