import ClaudioCore
import Foundation

@MainActor
func runHostIntegrationReviewRegressionSuites() async {
    await asyncSuite("宿主目录：首次创建为私有目录，既有权限与只读配置保持原样") {
        for host in HostIntegrationManager.automaticHosts {
            await withReviewTempDirectory { root in
                let fixture = ReviewIntegrationFixture(root: root)
                let adapter = fixture.adapter(host)
                let file = fixture.configurationFile(host)
                let directory = file.deletingLastPathComponent()
                let created = await adapter.connect(runtime: .ready)
                expect((try? created.get())?.configuration == .configured, "\(host) 缺失目录允许首次安装")
                expect(reviewDirectoryMode(directory) == 0o700, "\(host) 新建目录为 0700")
                let original = try! Data(contentsOf: file)
                _ = await adapter.disconnect(runtime: .ready)
                try! original.write(to: file)
                for mode in [0o750, 0o500] {
                    _ = await adapter.disconnect(runtime: .ready)
                    try! original.write(to: file)
                    try! FileManager.default.setAttributes(
                        [.posixPermissions: mode], ofItemAtPath: directory.path)
                    defer {
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    }
                    let result = await adapter.connect(runtime: .ready)
                    expect(
                        reviewDirectoryMode(directory) == mode,
                        "\(host) 不改动既有 \(String(mode, radix: 8)) 权限")
                    if mode == 0o500 {
                        if case .success = result { expect(false, "\(host) 只读目录应报告写入失败") }
                        expect(try! Data(contentsOf: file) == original, "\(host) 只读配置字节不变")
                    }
                }
            }
        }
    }
    await asyncSuite("关闭来源：配置或 hooks 消失仍撤销 marker，恢复旧配置不复用旧激活") {
        for host in HostIntegrationManager.automaticHosts {
            for removeFile in [true, false] {
                await withReviewTempDirectory { root in
                    let fixture = ReviewIntegrationFixture(root: root)
                    writeFixture("{}", to: fixture.intents.configFile)
                    let adapter = fixture.adapter(host)
                    let manager = HostIntegrationManager(
                        adapters: [adapter], bootstrapper: ReviewReadyRuntime(),
                        authorization: fixture.authorization)
                    guard case .success(let connected) = await manager.connect(host),
                        let oldID = connected.installationID
                    else { expect(false, "\(host) 连接前提"); return }
                    let file = fixture.configurationFile(host)
                    let oldConfiguration = try! Data(contentsOf: file)
                    let receipt = HostHookReceipt(
                        installationID: oldID, host: host, nativeEvent: "UserPromptSubmit",
                        semanticEvent: .taskStart, timestamp: Date(), playbackResult: .played)
                    expect(
                        fixture.receipts.store(
                            receipt, expectedScopeFingerprint: "review-scope",
                            scopeFingerprint: { "review-scope" })
                            == .success(.written), "旧代次回执前提")
                    if removeFile {
                        try! FileManager.default.removeItem(at: file)
                    } else {
                        writeFixture(#"{"foreign":"retain"}"#, to: file)
                    }
                    let inspected = await adapter.inspect(runtime: .ready)
                    expect(
                        inspected.configuration == .notConfigured
                            && inspected.installationID == nil,
                        "配置缺失与 marker 仍在是独立事实")
                    let result = await manager.disconnect(host)
                    expect((try? result.get()) != nil, "\(host) 关闭清理成功")
                    expect(fixture.intents.intent(for: host.surfaceID)?.enabled == false, "关闭先持久化")
                    expect(
                        fixture.receipts.currentInstallationID(host: host) == nil,
                        "\(host) 孤儿 marker 必须撤销")
                    if !removeFile {
                        expect(
                            try! String(contentsOf: file, encoding: .utf8)
                                == #"{"foreign":"retain"}"#,
                            "第三方配置不变")
                    }
                    try! oldConfiguration.write(to: file)
                    let reconnect = await manager.connect(host)
                    guard case .success(let restored) = reconnect else {
                        expect(false, "\(host) 恢复旧配置后重新连接：\(reconnect)"); return
                    }
                    expect(
                        restored.installationID != nil && restored.installationID != oldID,
                        "\(host) 恢复旧配置必须轮换 installation")
                    if case .awaitingReceipt = restored.activation {
                        expect(restored.latestReceipt == nil, "\(host) 恢复后没有当前回执")
                    } else {
                        expect(false, "\(host) 关闭前回执不能成为恢复后的当前激活：\(restored.activation)")
                    }
                }
            }
        }
    }
    await asyncSuite("单来源维护：无关来源 inspect 挂起不延迟目标连接或关闭") {
        await withReviewTempDirectory { root in
            let fixture = ReviewIntegrationFixture(root: root)
            writeFixture("{}", to: fixture.intents.configFile)
            let unrelated = ReviewMaintenanceAdapter(host: .claudeCode)
            let target = ReviewMaintenanceAdapter(host: .codex)
            let runtime = ReviewRepairableRuntime()
            let manager = HostIntegrationManager(
                adapters: [unrelated, target], bootstrapper: runtime,
                authorization: fixture.authorization, maintenanceDelay: { _ in })
            _ = await manager.startAutomaticMaintenance()
            await manager.waitForMaintenance()
            await unrelated.blockInspections()
            let refresh = Task { await manager.refresh() }
            await unrelated.waitUntilBlocked()
            await target.removeConfiguration()
            runtime.damage()
            for enabled in [true, false] {
                let before = await target.operationCount
                if enabled {
                    await manager.requestMaintenance(trigger: .fileChanged, surface: .codex)
                } else {
                    _ = await manager.setEnabled(surface: .codex, enabled: false)
                }
                let completion = ReviewCompletion()
                let maintenance = Task {
                    await manager.waitForMaintenance()
                    await completion.finish(true)
                }
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled { await completion.finish(false) }
                }
                let finished = await completion.wait()
                timeout.cancel()
                expect(finished, "Codex \(enabled ? "连接" : "关闭") 应在 Claude inspect 释放前完成")
                let after = await target.operationCount
                expect(after == before + 1, "目标来源实际执行维护")
                if !finished { await unrelated.releaseInspections() }
                await maintenance.value
            }
            let beforeFailure = await target.operationCount
            runtime.damage(repairFails: true)
            await manager.requestMaintenance(trigger: .fileChanged, surface: .codex)
            await manager.waitForMaintenance()
            expect(await target.operationCount == beforeFailure, "共享 runtime 准备失败不写宿主配置")
            let snapshots = await manager.snapshots()
            expect(
                snapshots.first { $0.host == .codex }?.runtime != .ready,
                "单来源维护也更新共享 runtime 故障投影")
            await unrelated.releaseInspections()
            _ = await refresh.value
            await manager.stopAutomaticMaintenance()
        }
    }
    await asyncSuite("doctor：当前回执不覆盖已保存 OFF、损坏意愿、待迁移或退出门禁") {
        for host in HostIntegrationManager.automaticHosts {
            await withReviewTempDirectory { root in
                let fixture = ReviewIntegrationFixture(root: root)
                writeFixture("{}", to: fixture.intents.configFile)
                let manager = HostIntegrationManager(
                    adapters: [fixture.adapter(host)], bootstrapper: ReviewReadyRuntime(),
                    authorization: fixture.authorization)
                let connected = try! await manager.connect(host).get()
                let run = try! fixture.authorization.runs.register().get()
                let receipt = HostHookReceipt(
                    installationID: connected.installationID!, host: host,
                    nativeEvent: "UserPromptSubmit", semanticEvent: .taskStart,
                    timestamp: Date(), playbackResult: .played)
                expect(
                    fixture.receipts.store(
                        receipt, expectedScopeFingerprint: "review-scope",
                        scopeFingerprint: { "review-scope" }) == .success(.written),
                    "doctor 回执 fixture 前提")
                let file = fixture.configurationFile(host)
                let bytes = try! Data(contentsOf: file)
                let on = try! Data(contentsOf: fixture.intents.configFile)
                let result = {
                    hostIntegrationDoctorResults(environment: fixture.doctorEnvironment)
                        .first { $0.name == "host-\(host.rawValue)" }!
                }
                expect(result().severity == .ok, "启用、GUI 运行且有当前回执时诊断正常")
                _ = fixture.intents.setEnabled(surface: host.surfaceID, enabled: false)
                let off = result()
                expect(
                    off.severity == .warning && off.message.contains("已关闭"),
                    "已保存 OFF、hooks 尚未清理时 doctor 明确关闭")
                for invalid in [
                    #"{"host_integrations":{"policy_version":99,"surfaces":{}}}"#,
                    #"{"host_integrations":null}"#,
                ] {
                    writeFixture(invalid, to: fixture.intents.configFile)
                    let damaged = result()
                    expect(
                        damaged.severity == .failure && damaged.message.contains("接收已阻断"),
                        "损坏或不支持版本的意愿阻断接收，doctor 不得假绿")
                    expect(
                        try! String(contentsOf: fixture.intents.configFile, encoding: .utf8)
                            == invalid,
                        "doctor 不迁移或改写损坏意愿")
                }
                writeFixture("{}", to: fixture.intents.configFile)
                let pending = result()
                expect(
                    pending.severity == .warning && pending.message.contains("接收已阻断"),
                    "没有已保存意愿不能从静态 hooks 推断开启")
                try! on.write(to: fixture.intents.configFile)
                _ = fixture.authorization.runs.revoke(runID: run.runID)
                let stopped = result()
                expect(
                    stopped.severity == .warning && stopped.message.contains("接收已暂停"),
                    "没有 GUI 运行资格时报告暂停接收")
                expect(try! Data(contentsOf: file) == bytes, "全部 doctor 检查保持宿主配置字节")
                expect(
                    fixture.receipts.currentInstallationID(host: host) == connected.installationID,
                    "只读诊断保留 marker 和回执")
            }
        }
    }
    await asyncSuite("单来源异步检查：退出或重新开启使已经开始的旧清理失效") {
        for stopRun in [true, false] {
            await withReviewTempDirectory { root in
                let fixture = ReviewIntegrationFixture(root: root)
                writeFixture("{}", to: fixture.intents.configFile)
                let gate = ReviewMaintenanceAdapter(host: .codex)
                let adapter = ReviewGatedAdapter(base: fixture.adapter(.codex), gate: gate)
                let manager = HostIntegrationManager(
                    adapters: [adapter], bootstrapper: ReviewReadyRuntime(),
                    authorization: fixture.authorization, maintenanceDelay: { _ in })
                _ = await manager.startAutomaticMaintenance()
                await manager.waitForMaintenance()
                let file = fixture.configurationFile(.codex)
                let original = try! Data(contentsOf: file)
                let installation = fixture.receipts.currentInstallationID(host: .codex)
                await gate.blockInspections()
                let cleanup = Task { await manager.disconnect(.codex) }
                await gate.waitUntilBlocked()
                if stopRun {
                    await manager.stopAutomaticMaintenance()
                } else {
                    _ = fixture.intents.setEnabled(surface: .codex, enabled: true)
                }
                await gate.releaseInspections()
                if case .success = await cleanup.value {
                    expect(false, "异步检查不能赋予旧清理新的意愿 revision 或运行身份")
                }
                expect(try! Data(contentsOf: file) == original, "失效清理保持配置字节")
                expect(
                    fixture.receipts.currentInstallationID(host: .codex) == installation,
                    "失效清理不撤销新资格下的 marker")
                await manager.stopAutomaticMaintenance()
            }
        }
    }
}

private struct ReviewIntegrationFixture {
    let root: URL
    var claudioRoot: URL { root.appendingPathComponent(".claudio") }
    var binary: String { claudioRoot.appendingPathComponent("bin/claudio").path }
    var intents: HostIntegrationIntentStore {
        .init(
            configFile: claudioRoot.appendingPathComponent("config.json"),
            lockFile: claudioRoot.appendingPathComponent("config.lock"))
    }
    var authorization: HostEventAuthorization {
        .init(
            intents: intents,
            runs: .init(
                file: claudioRoot.appendingPathComponent("gui-run.json"),
                authorizationLockFile: intents.authorizationLockFile))
    }
    var receipts: HostHookReceiptStore {
        .init(
            receiptsRoot: claudioRoot.appendingPathComponent("receipts"),
            locksRoot: claudioRoot.appendingPathComponent("receipt-locks"))
    }
    var doctorEnvironment: DoctorIntegrationsEnvironment {
        .init(
            claudeSettingsFile: configurationFile(.claudeCode),
            codexHooksFile: configurationFile(.codex),
            workBuddySettingsFile: configurationFile(.workBuddy),
            claudioRoot: claudioRoot.path, claudioBinaryPath: binary, receiptStore: receipts,
            claudeAvailability: { .available }, codexAvailability: { .available },
            workBuddyAvailability: { .available }, claudeScopeFingerprint: { "review-scope" },
            codexScopeFingerprint: { "review-scope" }, workBuddyScopeFingerprint: { "review-scope" }
        )
    }
    func configurationFile(_ host: HostID) -> URL {
        root.appendingPathComponent(host.rawValue).appendingPathComponent(
            host == .codex ? "hooks.json" : "settings.json")
    }
    func adapter(_ host: HostID) -> any HostIntegrationAdapter {
        let file = configurationFile(host)
        let lock = claudioRoot.appendingPathComponent("\(host.rawValue).lock")
        switch host {
        case .claudeCode:
            return ClaudeCodeIntegrationAdapter(
                environment: .init(
                    settingsFile: file, lockFile: lock, claudioBinaryPath: binary,
                    claudioRoot: claudioRoot.path, receiptStore: receipts,
                    scopeFingerprint: { "review-scope" }, availability: { .available }))
        case .codex:
            return CodexIntegrationAdapter(
                environment: .init(
                    hooksFile: file, lockFile: lock,
                    configFile: file.deletingLastPathComponent().appendingPathComponent(
                        "config.toml"),
                    legacyNotifyWrapper: claudioRoot.appendingPathComponent("bin/codex-notify"),
                    claudioBinaryPath: binary, claudioRoot: claudioRoot.path,
                    receiptStore: receipts,
                    scopeFingerprint: { "review-scope" }, availability: { .available }))
        case .workBuddy:
            return WorkBuddyIntegrationAdapter(
                environment: .init(
                    settingsFile: file, lockFile: lock, claudioBinaryPath: binary,
                    claudioRoot: claudioRoot.path, receiptStore: receipts,
                    scopeFingerprint: { "review-scope" }, availability: { .available }))
        default: fatalError("仅正式自动维护来源")
        }
    }
}

private struct ReviewReadyRuntime: SharedRuntimeBootstrapping {
    func inspect() -> SharedRuntimeHealth { .ready }
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        .success(
            .init(copiedBinary: false, copiedPacks: [], salvaged: [], packSelection: .untouched))
    }
}

private final class ReviewRepairableRuntime: SharedRuntimeBootstrapping, @unchecked Sendable {
    private let lock = NSLock()
    private var ready = true
    private var repairFails = false
    func damage(repairFails: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        ready = false; self.repairFails = repairFails
    }
    func inspect() -> SharedRuntimeHealth {
        lock.lock(); defer { lock.unlock() }
        return ready ? .ready : .damaged(reason: "fixture runtime unavailable")
    }
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        lock.lock(); defer { lock.unlock() }
        if repairFails { return .failure(.binaryCopyFailure(reason: "fixture repair failed")) }
        ready = true
        return ReviewReadyRuntime().bootstrap()
    }
}

private actor ReviewMaintenanceAdapter: HostIntegrationAdapter {
    nonisolated let host: HostID
    nonisolated var capabilities: [HostCapabilityBinding] {
        HostCapabilityCatalog.bindings(for: host)
    }
    private var configured = false
    private var blocked = false
    private var inspections: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?
    var operationCount = 0
    init(host: HostID) { self.host = host }
    func blockInspections() { blocked = true }
    func waitUntilBlocked() async {
        if !inspections.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseInspections() {
        blocked = false
        let pending = inspections
        inspections.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func removeConfiguration() { configured = false }
    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        if blocked {
            await withCheckedContinuation { continuation in
                inspections.append(continuation)
                started?.resume(); started = nil
            }
        }
        return snapshot(runtime)
    }
    private func snapshot(_ runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        .init(
            host: host, runtime: runtime, availability: .available,
            configuration: configured ? .configured : .notConfigured,
            writability: .writable, activation: .none)
    }
    func connect(runtime: SharedRuntimeHealth) async -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        operationCount += 1; configured = true
        return .success(snapshot(runtime))
    }
    func disconnect(runtime: SharedRuntimeHealth) async -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        operationCount += 1; configured = false
        return .success(snapshot(runtime))
    }
}

private struct ReviewGatedAdapter: HostIntegrationAdapter {
    let base: any HostIntegrationAdapter
    let gate: ReviewMaintenanceAdapter
    var host: HostID { base.host }
    var capabilities: [HostCapabilityBinding] { base.capabilities }
    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        _ = await gate.inspect(runtime: runtime)
        return await base.inspect(runtime: runtime)
    }
    func connect(runtime: SharedRuntimeHealth) async -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        await base.connect(runtime: runtime)
    }
    func disconnect(runtime: SharedRuntimeHealth) async -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        await base.disconnect(runtime: runtime)
    }
}

private actor ReviewCompletion {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value; continuation?.resume(returning: value); continuation = nil
    }
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

private func reviewDirectoryMode(_ directory: URL) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        as! NSNumber).intValue & 0o777
}

@MainActor
private func withReviewTempDirectory(_ body: (URL) async -> Void) async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    await body(root)
}
