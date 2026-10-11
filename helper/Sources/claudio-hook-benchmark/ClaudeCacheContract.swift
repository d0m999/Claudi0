import ClaudioCore
import Foundation

// Only synthetic native-layout fixtures. This entry has no measurement or real-host mode.
private let contractVersion = "2.1.282 (Claude Code)"

private final class ContractClock: @unchecked Sendable {
    private let lock = NSLock()
    private var age: TimeInterval = 0
    func advance(_ value: TimeInterval) { lock.lock(); age += value; lock.unlock() }
    func read() -> HostVersionObservationTime {
        lock.lock(); defer { lock.unlock() }
        return .init(wall: 10_000 + age, uptime: 1_000 + age)
    }
}

private struct ContractVersionRunner: CommandRunning {
    let call: String
    var succeeds = true
    var action: @Sendable () -> Void = {}
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        guard executablePath == call, arguments == ["--version"], timeout == 1 else {
            return .launchFailed
        }
        action()
        return succeeds ? .completed(exitCode: 0, stdout: contractVersion) : .launchFailed
    }
}

private final class ContractSignature: HostVersionSignatureValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let acceptsSignature: Bool
    let action: @Sendable () -> Void
    init(acceptsSignature: Bool = true, action: @escaping @Sendable () -> Void = {}) {
        self.acceptsSignature = acceptsSignature; self.action = action
    }
    func accepts(host: HostID, executable: URL) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        action()
        return host == .claudeCode && acceptsSignature
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct ContractCacheFile: Equatable {
    let bytes: Data
    let modified: Date
}

private final class ContractInstallation: @unchecked Sendable {
    let root: URL
    let home: URL
    let target: URL
    let call: URL
    let cache: URL
    let clock = ContractClock()
    let locator: HostExecutableLocator
    init(root: URL) throws {
        self.root = root
        home = root.appendingPathComponent("home")
        target = home.appendingPathComponent(".local/share/claude/versions/2.1.282")
        call = root.appendingPathComponent("bin/claude")
        cache = root.appendingPathComponent("cache")
        locator = HostExecutableLocator(searchDirectories: [call.deletingLastPathComponent()])
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: call.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replaceTarget()
        try FileManager.default.createSymbolicLink(at: call, withDestinationURL: target)
    }
    func replaceTarget(at destination: URL? = nil) throws {
        let file = destination ?? target
        try Data("synthetic native identity; never executed".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    func runner(succeeds: Bool = true, action: @escaping @Sendable () -> Void = {})
        -> ObservedRunner
    {
        ObservedRunner(
            base: ContractVersionRunner(call: call.path, succeeds: succeeds, action: action))
    }
    func resolver(
        runner: ObservedRunner, signature: ContractSignature, enabled: Bool = true
    ) -> HostVersionResolver {
        HostVersionResolver(
            cacheDirectory: enabled ? cache : nil, homeDirectory: home,
            executableLocator: locator, commandRunner: runner, signatureValidator: signature,
            now: { [clock] in clock.read() })
    }
    func snapshot() throws -> [String: ContractCacheFile] {
        guard FileManager.default.fileExists(atPath: cache.path) else { return [:] }
        var result: [String: ContractCacheFile] = [:]
        for file in try FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: [.contentModificationDateKey])
        {
            result[file.lastPathComponent] = ContractCacheFile(
                bytes: try Data(contentsOf: file),
                modified: try file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate!)
        }
        return result
    }
    func fill() throws {
        let runner = runner(); let signature = ContractSignature()
        let result = resolver(runner: runner, signature: signature).refresh(.claudeCode)
        try require(
            result.status == .published && result.version == contractVersion
                && runner.snapshot.count == 1 && signature.calls == 1,
            "synthetic strict-refresh contract failed")
    }
}

private struct CacheHookContract: Encodable {
    let scenario: String
    let cacheCase: String
    let observer: Bool
    let playback: String
    let accepted: Int
    let playerStarts: Int
    let receipts: Int
    let archives: Int
    let notices: Int
    let activity: Int
    let probeCalls: Int
    let signatureCalls: Int
}

func runClaudeCacheContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-claude-cache-contract-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var hooks: [CacheHookContract] = []
    for scenario in scenarioNames {
        for cacheCase in ["off", "empty", "hit"] {
            for observer in [false, true] {
                let cell = root.appendingPathComponent("\(scenario)-\(cacheCase)-\(observer)")
                let installation = try ContractInstallation(
                    root: cell.appendingPathComponent("native"))
                if cacheCase == "hit" { try installation.fill() }
                let before = try installation.snapshot()
                let runner = installation.runner(); let signature = ContractSignature()
                let resolver = installation.resolver(
                    runner: runner, signature: signature, enabled: cacheCase != "off")
                let fixture = try Fixture(
                    root: cell.appendingPathComponent("hook"), scenario: scenario, mode: "instant",
                    scopeVersion: contractVersion)
                let row = try fixture.run(
                    observer: observer, round: 0, pair: 0, position: 0, contract: true,
                    versionProbe: Probe(resolver: resolver, runner: runner),
                    expectedProbeCount: cacheCase == "hit" ? 0 : 1)
                try require(
                    row.nanoseconds == 0 && signature.calls == 0, "hook did timed or signature work"
                )
                let after = try installation.snapshot()
                try require(after == before, "hook changed cache bytes or mtime")
                hooks.append(
                    CacheHookContract(
                        scenario: scenario, cacheCase: cacheCase, observer: observer,
                        playback: row.playback, accepted: row.accepted,
                        playerStarts: row.playerStarts,
                        receipts: row.receipts, archives: row.archives, notices: row.notices,
                        activity: row.activity, probeCalls: row.probeCalls,
                        signatureCalls: signature.calls))
            }
        }
    }
    var resolverCases: [String] = []
    func verify(_ name: String, _ body: (ContractInstallation) throws -> Void) throws {
        let installation = try ContractInstallation(root: root.appendingPathComponent(name))
        try body(installation)
        resolverCases.append(name)
    }
    try verify("repeated-empty-miss") { installation in
        let runner = installation.runner(); let signature = ContractSignature()
        let resolver = installation.resolver(runner: runner, signature: signature)
        for _ in 0..<3 {
            try require(
                resolver.resolve(.claudeCode, mode: .reuseValidated) == contractVersion,
                "miss version")
        }
        try require(runner.snapshot.count == 3 && signature.calls == 0, "miss did not probe only")
        try require(
            !FileManager.default.fileExists(atPath: installation.cache.path), "miss created root")
    }
    try verify("force-does-not-renew") { installation in
        try installation.fill(); let before = try installation.snapshot()
        let runner = installation.runner(); let signature = ContractSignature()
        let resolver = installation.resolver(runner: runner, signature: signature)
        try require(
            resolver.resolve(.claudeCode, mode: .forceProbe) == contractVersion, "force version")
        try require(runner.snapshot.count == 1 && signature.calls == 0, "force did not probe only")
        let after = try installation.snapshot()
        try require(after == before, "force renewed cache")
    }
    for name in ["expired", "identity-change", "corrupt", "unknown-wrapper"] {
        try verify(name) { installation in
            try installation.fill()
            if name == "expired" { installation.clock.advance(601) }
            if name == "identity-change" { try installation.replaceTarget() }
            if name == "corrupt" {
                try Data("{broken".utf8).write(
                    to: installation.cache.appendingPathComponent("claude-code.json"),
                    options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: installation.cache.appendingPathComponent("claude-code.json").path
                )
            }
            if name == "unknown-wrapper" {
                let wrapper = installation.root.appendingPathComponent("wrapper")
                try installation.replaceTarget(at: wrapper)
                try FileManager.default.removeItem(at: installation.call)
                try FileManager.default.createSymbolicLink(
                    at: installation.call, withDestinationURL: wrapper)
            }
            let before = try installation.snapshot()
            let runner = installation.runner(); let signature = ContractSignature()
            let resolver = installation.resolver(runner: runner, signature: signature)
            try require(
                resolver.resolve(.claudeCode, mode: .reuseValidated) == contractVersion,
                "fallback version")
            try require(
                runner.snapshot.count == 1 && signature.calls == 0, "fallback did not probe only")
            let after = try installation.snapshot()
            try require(after == before, "fallback rewrote cache")
        }
    }
    try verify("signature-rejected") { installation in
        let runner = installation.runner();
        let signature = ContractSignature(acceptsSignature: false)
        let resolver = installation.resolver(runner: runner, signature: signature)
        try require(
            resolver.refresh(.claudeCode).status == .ineligible, "signature refusal not honored")
        try require(
            resolver.resolve(.claudeCode, mode: .reuseValidated) == contractVersion,
            "unsigned fallback")
        try require(
            runner.snapshot.count == 2 && signature.calls == 1, "unsigned observation was reused")
    }
    try verify("refresh-operation-busy") { installation in
        try installation.fill(); let before = try installation.snapshot()
        let lock = FileLock(
            path: installation.cache.appendingPathComponent("claude-code.refresh.lock").path)
        try require(lock.attemptLock() == .acquired, "operation lock fixture")
        defer { lock.unlock() }
        let runner = installation.runner(); let signature = ContractSignature()
        let resolver = installation.resolver(runner: runner, signature: signature)
        try require(resolver.refresh(.claudeCode).status == .busy, "refresh waited or ignored lock")
        try require(runner.snapshot.isEmpty && signature.calls == 0, "busy refresh ran slow work")
        let after = try installation.snapshot()
        try require(after == before, "busy refresh changed cache")
    }
    try verify("cancel-before-refresh") { installation in
        let runner = installation.runner(); let signature = ContractSignature()
        let resolver = installation.resolver(runner: runner, signature: signature)
        try require(
            resolver.refresh(.claudeCode, isCurrent: { false }).status == .cancelled,
            "cancel ignored")
        try require(runner.snapshot.isEmpty && signature.calls == 0, "cancelled refresh ran work")
        try require(
            !FileManager.default.fileExists(atPath: installation.cache.path), "cancel created root")
    }
    try verify("identity-change-during-signature") { installation in
        let runner = installation.runner()
        let signature = ContractSignature(action: { try? installation.replaceTarget() })
        let resolver = installation.resolver(runner: runner, signature: signature)
        try require(
            resolver.refresh(.claudeCode).status == .identityChanged, "changed target published")
        let probe = installation.runner(); let noSignature = ContractSignature()
        try require(
            installation.resolver(runner: probe, signature: noSignature)
                .resolve(.claudeCode, mode: .reuseValidated) == contractVersion,
            "changed target fallback")
        try require(
            probe.snapshot.count == 1 && noSignature.calls == 0, "changed target remained hit")
    }
    try verify("late-failed-probe-keeps-new-refresh") { installation in
        try installation.fill(); installation.clock.advance(601)
        let runner = installation.runner(succeeds: false, action: { try? installation.fill() })
        let signature = ContractSignature()
        try require(
            installation.resolver(runner: runner, signature: signature)
                .resolve(.claudeCode, mode: .reuseValidated) == nil,
            "failed probe accepted old value")
        let hitRunner = installation.runner(); let hitSignature = ContractSignature()
        try require(
            installation.resolver(runner: hitRunner, signature: hitSignature)
                .resolve(.claudeCode, mode: .reuseValidated) == contractVersion,
            "late probe removed new refresh")
        try require(
            hitRunner.snapshot.isEmpty && hitSignature.calls == 0, "new refresh was not preserved")
    }
    struct Report: Encodable {
        let evidence = "claude-native-cache-synthetic-contract"
        let host = "claude-code"
        let hooks: [CacheHookContract]
        let resolverCases: [String]
        let performanceMeasured = false
        let realHostProbed = false
        let realSignatureChecked = false
        let audioPlayed = false
        let lifecycleWiring = false
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print(
        String(
            decoding: try encoder.encode(Report(hooks: hooks, resolverCases: resolverCases)),
            as: UTF8.self))
}
