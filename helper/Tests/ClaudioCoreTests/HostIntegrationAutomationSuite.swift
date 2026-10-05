import ClaudioCore
import Darwin
import Foundation

@MainActor
func runHostIntegrationAutomationSuites() async {
    suite("接入意愿：迁移保留声音、第三方及未来来源；显式关闭跨迁移不复活") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            writeFixture(
                #"{"selected_pack":"mine","master_volume":0.4,"unknown":{"x":1},"host_integrations":{"policy_version":1,"surfaces":{"future-agent":{"opaque":"retain"}}}}"#,
                to: store.configFile)
            let original = try! Data(contentsOf: store.configFile)
            let migrated = try! store.migrate(installedSurfaces: [.claudeCode, .codex]).get()
            expect(migrated[.claudeCode]?.enabled == true, "首次升级应开启已安装来源")
            let enabled = migrated[.claudeCode]!
            let off = try! store.setEnabled(surface: .claudeCode, enabled: false).get()
            expect(off.revision != enabled.revision && !off.enabled, "意愿改变生成新 revision")
            expect(
                try! store.setEnabled(surface: .claudeCode, enabled: false).get() == off, "重复关闭幂等")
            _ = store.migrate(installedSurfaces: [.claudeCode, .codex, .workBuddy])
            expect(store.intent(for: .claudeCode) == off, "重启升级和重新发现不得覆盖关闭")
            let json =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile))
                as! [String: Any]
            expect(
                json["selected_pack"] as? String == "mine"
                    && json["master_volume"] as? Double == 0.4, "声音事实保留")
            let section = json["host_integrations"] as! [String: Any]
            let surfaces = section["surfaces"] as! [String: Any]
            expect(
                (surfaces["future-agent"] as? [String: String])?["opaque"] == "retain"
                    && json["unknown"] != nil, "未知字段保留")
            expect(
                try! Data(
                    contentsOf: store.configFile.appendingPathExtension("host-integrations.bak"))
                    == original, "首次迁移备份不被后续写入覆盖")
        }
    }
    suite("接入意愿：损坏和锁忙均拒写，不解释成默认开启") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            for json in [
                #"{"host_integrations":null}"#,
                #"{"host_integrations":{"policy_version":2,"surfaces":{}}}"#,
                #"{"host_integrations":{"policy_version":1,"surfaces":{"codex":{"enabled":1,"revision":"bad"}}}}"#,
            ] {
                writeFixture(json, to: store.configFile)
                let original = try! Data(contentsOf: store.configFile)
                expect(store.intent(for: .codex) == nil, "损坏读失败关闭")
                if case .success = store.migrate(installedSurfaces: [.codex]) {
                    expect(false, "损坏不得迁移")
                }
                expect(try! Data(contentsOf: store.configFile) == original, "损坏字节原样保留")
            }
            writeFixture("{}", to: store.configFile)
            let lock = FileLock(path: store.authorizationLockFile.path)
            expect(lock.tryLock(), "取得许可锁")
            if case .failure(.transaction(.lockBusy)) = store.setEnabled(
                surface: .codex, enabled: false)
            {
                expect(store.intent(for: .codex) == nil, "锁忙不制造已保存关闭")
            } else {
                expect(false, "许可锁忙必须拒写")
            }
        }
    }
    suite("运行资格：独立于横幅接收器，内核启动身份/用户/损坏/撤销失败关闭") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            writeFixture("{}", to: store.configFile)
            _ = store.migrate(installedSurfaces: [.codex])
            let registry = automationRunRegistry(root, store)
            let run = try! registry.register().get()
            let authorization = HostEventAuthorization(intents: store, runs: registry)
            let token = authorization.capture(surface: .codex)!
            expect(token.run == run, "无横幅 receiver 也能取得运行资格")
            let reused = HostGUIRunRegistry(
                file: registry.file, authorizationLockFile: store.authorizationLockFile,
                readProcess: { pid in
                    HostProcessSnapshot(
                        identity: HostProcessIdentity(
                            pid: pid, startSeconds: 1, startMicroseconds: 0), parentPID: 1,
                        userID: getuid())
                })
            expect(reused.current() == nil, "PID 复用拒收")
            let dead = HostGUIRunRegistry(
                file: registry.file, authorizationLockFile: store.authorizationLockFile,
                readProcess: { _ in nil })
            expect(dead.current() == nil, "死亡/zombie/不可验证拒收")
            _ = registry.revoke(runID: UUID())
            expect(registry.current() == run, "旧 run 不能撤销新 run")
            _ = registry.revoke(runID: run.runID)
            expect(
                !authorization.isCurrent(token) && authorization.capture(surface: .codex) == nil,
                "退出使旧 token 失效")
            _ = registry.register()
            writeFixture("broken", to: registry.file)
            expect(authorization.capture(surface: .codex) == nil, "损坏运行注册拒收")
        }
    }
    suite("发布许可：最终 rename 前关闭；off→on 后旧安装和旧清理均失败") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            writeFixture("{}", to: store.configFile)
            _ = store.migrate(installedSurfaces: [.codex])
            let authorization = HostEventAuthorization(
                intents: store, runs: automationRunRegistry(root, store))
            let on = authorization.capture(surface: .codex, requiresGUI: false)!
            let file = root.appendingPathComponent("hooks.json")
            writeFixture(#"{"foreign":true}"#, to: file)
            let original = try! Data(contentsOf: file)
            let boundary = HostPublicationContext(authorization: authorization, token: on)
            let result = HostPublicationContext.$current.withValue(boundary) {
                ConfigFileTransaction(
                    file: file, lockFile: root.appendingPathComponent("hooks.lock")
                ).update(
                    { _ in .replace(["new": true]) }, betweenReadAndWrite: nil,
                    beforeFinalPublish: { _ = store.setEnabled(surface: .codex, enabled: false) })
            }
            if case .failure(.mutationRejected) = result {
            } else {
                expect(false, "最后发布必须拒绝旧 ON token")
            }
            expect(try! Data(contentsOf: file) == original, "关闭前 staging 不得发布")
            let off = authorization.capture(surface: .codex, requiresGUI: false)!
            _ = store.setEnabled(surface: .codex, enabled: true)
            expect(boundary.acquire() == .stale, "旧安装不能覆盖重新开启")
            let cleanup = HostPublicationContext(authorization: authorization, token: off)
            expect(
                cleanup.perform(rejected: false) {
                    try! FileManager.default.removeItem(at: file); return true
                } == false, "旧清理不能删除新开启的接入")
            let current = HostPublicationContext(
                authorization: authorization,
                token: authorization.capture(surface: .codex, requiresGUI: false)!)
            expect(current.acquire() == .allowed, "取得当前发布许可")
            if case .failure(.transaction(.lockBusy)) = store.setEnabled(
                surface: .codex, enabled: false)
            {
            } else {
                expect(false, "许可内不能成功保存关闭")
            }
            current.release()
            expect(
                (try? store.setEnabled(surface: .codex, enabled: false).get())?.enabled == false,
                "许可释放后可以可靠关闭")
        }
    }
    suite("事件门禁：GUI 不运行及关闭来源时活动、回执、去重、日志、音频和通知均零副作用") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            writeFixture(#"{"selected_pack":"missing","events":{}}"#, to: store.configFile)
            _ = store.migrate(installedSurfaces: [.codex])
            let registry = automationRunRegistry(root, store)
            let authorization = HostEventAuthorization(intents: store, runs: registry)
            let receiptStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("receipt-locks"))
            let installation = UUID()
            _ = receiptStore.activate(
                host: .codex, installationID: installation, scopeFingerprint: "fixture")
            let spawner = AutomationSpawner()
            let environment = HostHookEnvironment(
                host: .codex, authorization: authorization,
                playEnvironment: PlayEnvironment(
                    lockFile: root.appendingPathComponent("play.lock"),
                    configFile: store.configFile,
                    userPacksDirectory: root.appendingPathComponent("packs"), spawner: spawner,
                    debounceStateFile: root.appendingPathComponent("play.state"),
                    logFile: root.appendingPathComponent("log"),
                    logLockFile: root.appendingPathComponent("log.lock")),
                receiptStore: receiptStore,
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: nil, receiverEpoch: UUID(),
                    sender: { _ in
                        spawner.notice(); return .sent
                    }))
            expect(
                handleHostHook(
                    host: .codex, nativeEvent: "Stop", installationID: installation,
                    environment: environment) == nil, "退出期间安静丢弃")
            let run = try! registry.register().get()
            _ = store.setEnabled(surface: .codex, enabled: false)
            expect(
                handleHostHook(
                    host: .codex, nativeEvent: "Stop", installationID: installation,
                    environment: environment) == nil, "关闭期间安静丢弃")
            expect(spawner.count == 0 && spawner.notices == 0, "音频和通知零副作用")
            expect(
                receiptStore.receiptEvidence(
                    host: .codex, nativeEvent: "Stop", installationID: installation,
                    scopeFingerprint: "fixture") == nil, "不生成回执")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("play.state").path)
                    && !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("log").path),
                "不消费去重或写日志")
            _ = registry.revoke(runID: run.runID)
        }
    }
    suite("真实可执行文件发现：配置目录缺失仍已安装；目录和不可验证版本不证明安装") {
        withTempDirectory { root in
            let locator = HostExecutableLocator(searchDirectories: [root])
            expect(
                HostDiscovery.detect(.codex, locator: locator) == .notInstalled, "配置目录存在也不能当安装证据")
            let executable = root.appendingPathComponent("codex")
            writeFixture("#!/bin/sh\nexit 0\n", to: executable)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: executable.path)
            expect(
                HostDiscovery.detect(
                    .codex, locator: locator,
                    runner: AutomationVersionRunner(output: "codex-cli 0.134.0")) == .installed,
                "未创建宿主配置也能发现真实可执行文件")
            if case .blocked = HostDiscovery.detect(
                .codex, locator: locator, runner: AutomationVersionRunner(output: "broken"))
            {
            } else {
                expect(false, "不可验证版本拒绝自动准备")
            }
            expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path),
                "发现只读不创建配置")
        }
    }
    suite("真实 hook 发布竞争：各副作用发布前关闭，拒绝后续活动/去重/回执/音频/通知") {
        for effect in [HostPublicationEffect.activity, .deduplication, .audio, .receipt, .notice] {
            withTempDirectory { root in
                let store = automationIntentStore(root)
                writeFixture(
                    #"{"selected_pack":"test","master_volume":0.8,"events":{}}"#,
                    to: store.configFile)
                let pack = root.appendingPathComponent("packs/test")
                try! FileManager.default.createDirectory(
                    at: pack, withIntermediateDirectories: true)
                writeFixture(
                    #"{"id":"test","name":"Test","author":"Tests","version":"1","events":{"stop":"stop.mp3"}}"#,
                    to: pack.appendingPathComponent("manifest.json"))
                writeFixture("sound", to: pack.appendingPathComponent("stop.mp3"))
                _ = store.migrate(installedSurfaces: [.codex])
                let registry = automationRunRegistry(root, store)
                _ = registry.register()
                let authorization = HostEventAuthorization(intents: store, runs: registry)
                let token = authorization.capture(surface: .codex)!
                let receipts = HostHookReceiptStore(
                    receiptsRoot: root.appendingPathComponent("receipts"),
                    locksRoot: root.appendingPathComponent("receipt-locks"))
                let installation = UUID()
                _ = receipts.activate(
                    host: .codex, installationID: installation, scopeFingerprint: "fixture")
                let spawner = AutomationSpawner()
                let activity = LocalActivitySummaryStore(
                    summaryFile: root.appendingPathComponent("summary.json"),
                    lockFile: root.appendingPathComponent("summary.lock"),
                    pendingDirectory: root.appendingPathComponent("pending"))
                let environment = HostHookEnvironment(
                    host: .codex, authorization: authorization, authorizationToken: token,
                    beforePublication: {
                        if $0 == effect { _ = store.setEnabled(surface: .codex, enabled: false) }
                    },
                    playEnvironment: PlayEnvironment(
                        lockFile: root.appendingPathComponent("play.lock"),
                        configFile: store.configFile,
                        userPacksDirectory: root.appendingPathComponent("packs"), spawner: spawner,
                        debounceStateFile: root.appendingPathComponent("play.state"),
                        logFile: root.appendingPathComponent("log"),
                        logLockFile: root.appendingPathComponent("log.lock")),
                    receiptStore: receipts, activityStore: activity,
                    eventNoticeChannel: HostEventNoticeChannel(
                        sourcePayload: nil, receiverEpoch: UUID(),
                        sender: { _ in
                            spawner.notice(); return .sent
                        }), scopeFingerprint: { "fixture" })
                _ = handleHostHook(
                    host: .codex, nativeEvent: "Stop", installationID: installation,
                    environment: environment)
                expect(store.intent(for: .codex)?.enabled == false, "\(effect) seam 实际保存关闭")
                expect(spawner.notices == 0, "\(effect) 关闭后通知不得发送")
                if effect != .notice {
                    expect(
                        receipts.receiptEvidence(
                            host: .codex, nativeEvent: "Stop", installationID: installation,
                            scopeFingerprint: "fixture") == nil, "\(effect) 关闭后回执不得发布")
                }
                if effect == .activity || effect == .deduplication || effect == .audio {
                    expect(spawner.count == 0, "\(effect) 关闭后不得启动音频")
                }
                if effect == .activity {
                    expect(
                        !FileManager.default.fileExists(atPath: activity.summaryFile.path)
                            && !FileManager.default.fileExists(
                                atPath: activity.pendingDirectory.path),
                        "拒绝的活动不得提交或暂存")
                }
                if effect == .activity || effect == .deduplication {
                    expect(
                        !FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("play.state").path), "关闭前未消费的去重不得写入"
                    )
                }
                expect(
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("log").path), "被拒绝事件不写日志")
                _ = store.setEnabled(surface: .codex, enabled: true)
                expect(
                    handleHostHook(
                        host: .codex, nativeEvent: "Stop", installationID: installation,
                        environment: environment) == nil, "off→on 不赋予旧入口新 revision")
            }
        }
    }
    suite("文件变化提示：无关活动/日志不重试来源，单来源意愿和配置变化保持隔离") {
        withTempDirectory { root in
            let store = automationIntentStore(root)
            writeFixture("{}", to: store.configFile)
            _ = store.migrate(
                installedSurfaces: Set(HostIntegrationManager.automaticHosts.map(\.surfaceID)))
            let receipts = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("locks"))
            let claudeFile = root.appendingPathComponent("claude-settings.json")
            let codexFile = root.appendingPathComponent("codex-hooks.json")
            let files: [HostID: [URL]] = [
                .claudeCode: [claudeFile], .codex: [codexFile], .workBuddy: [],
            ]
            let capture = {
                HostMaintenanceFileFacts.capture(
                    intentStore: store,
                    locator: HostExecutableLocator(searchDirectories: [root]),
                    sharedHelper: root.appendingPathComponent("helper"),
                    receiptStore: receipts, configurationFiles: files,
                    workBuddyURL: root.appendingPathComponent("NoWorkBuddy.app"))
            }
            let first = capture()
            writeFixture("activity", to: root.appendingPathComponent("activity-summary.json"))
            writeFixture("diagnostic", to: root.appendingPathComponent("claudio.log"))
            expect(capture() == first, "无关父目录变更不能清除永久失败或触发自有接入重装")
            _ = store.setEnabled(surface: .claudeCode, enabled: false)
            let off = capture()
            expect(
                off[.claudeCode] != first[.claudeCode] && off[.codex] == first[.codex]
                    && off[.workBuddy] == first[.workBuddy], "意愿只触发对应来源")
            writeFixture("{}", to: codexFile)
            let configured = capture()
            expect(
                configured[.codex] != off[.codex] && configured[.claudeCode] == off[.claudeCode],
                "配置只触发对应来源")
        }
    }
    await asyncSuite("维护锁忙：1/3/10 有限重试，耗尽后等事实变化或用户重试") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = automationIntentStore(root)
        writeFixture("{}", to: store.configFile)
        let adapter = AutomationAdapter(host: .codex, busyAttempts: 4)
        let delays = AutomationDelayRecorder()
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: AutomationBootstrapper(),
            authorization: HostEventAuthorization(
                intents: store, runs: automationRunRegistry(root, store)),
            maintenanceDelay: { delays.record($0) })
        _ = await manager.startAutomaticMaintenance()
        await manager.waitForMaintenance()
        expect(await adapter.connectCount == 4, "首次加三次有限重试")
        expect(delays.values.filter { $0 >= 1 } == [1, 3, 10], "正式重试时序")
        await manager.requestMaintenance(trigger: .discoveryFallback)
        await manager.waitForMaintenance()
        expect(await adapter.connectCount == 4, "兜底不无限重试耗尽的失败")
        await manager.retryMaintenance(surface: .codex)
        await manager.waitForMaintenance()
        expect(await adapter.connectCount == 5, "用户可恢复维护")
        _ = await manager.setEnabled(surface: .codex, enabled: false)
        await manager.waitForMaintenance()
        await manager.stopAutomaticMaintenance()
        _ = store.setEnabled(surface: .codex, enabled: true)
        await manager.requestMaintenance(trigger: .fileChanged)
        await manager.waitForMaintenance()
        expect(await adapter.connectCount == 5, "退出后排队触发不能发布接入")
    }
    await asyncSuite("启动失败：兜底等待事实变化，未取得运行注册不发布后台接入") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = automationIntentStore(root)
        writeFixture("{}", to: store.configFile)
        let adapter = AutomationAdapter(host: .codex)
        let attempts = AutomationDelayRecorder()
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: AutomationBootstrapper(failureRecorder: attempts),
            authorization: HostEventAuthorization(
                intents: store, runs: automationRunRegistry(root, store)),
            maintenanceDelay: { _ in })
        _ = await manager.startAutomaticMaintenance()
        expect(attempts.values.count == 1, "启动准备失败")
        _ = await manager.startAutomaticMaintenance(trigger: .discoveryFallback)
        expect(attempts.values.count == 1, "定时兜底不重复失败的准备")
        _ = await manager.startAutomaticMaintenance(trigger: .fileChanged)
        expect(attempts.values.count == 2, "相关事实变化允许重试")
        _ = await manager.setEnabled(surface: .codex, enabled: true)
        await manager.waitForMaintenance()
        expect(await adapter.connectCount == 0, "没有运行资格和共享 runtime 时不写宿主配置")
        await manager.retryMaintenance(surface: .codex)
        await manager.waitForMaintenance()
        expect(attempts.values.count == 3, "用户重试可再次准备")
        expect(await adapter.connectCount == 0, "准备失败后重试不能绕过运行门禁")
        await manager.stopAutomaticMaintenance()
    }
    await asyncSuite("后续新安装：意愿迁移锁忙也有限重试，保存成功前不发布接入") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = automationIntentStore(root)
        writeFixture("{}", to: store.configFile)
        let adapter = AutomationAdapter(host: .codex, installed: false)
        let delays = AutomationDelayRecorder()
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: AutomationBootstrapper(),
            authorization: HostEventAuthorization(
                intents: store, runs: automationRunRegistry(root, store)),
            maintenanceDelay: { delays.record($0) })
        _ = await manager.startAutomaticMaintenance()
        await manager.waitForMaintenance()
        await adapter.setInstalled(true)
        let lock = FileLock(path: store.lockFile.path)
        expect(lock.tryLock(), "占用共享配置锁")
        await manager.requestMaintenance(trigger: .fileChanged, surface: .codex)
        await manager.waitForMaintenance()
        expect(delays.values.filter { $0 >= 1 } == [1, 3, 10], "后续迁移保留锁忙原因并有限重试")
        let blockedConnects = await adapter.connectCount
        expect(
            store.intent(for: .codex) == nil && blockedConnects == 0,
            "迁移失败不写宿主配置")
        await manager.requestMaintenance(trigger: .discoveryFallback, surface: .codex)
        await manager.waitForMaintenance()
        expect(delays.values.filter { $0 >= 1 }.count == 3, "迁移耗尽后不被兜底反复重试")
        lock.unlock()
        await manager.retryMaintenance(surface: .codex)
        await manager.waitForMaintenance()
        let connected = await adapter.connectCount
        expect(
            store.intent(for: .codex)?.enabled == true && connected == 1,
            "用户重试完成首次意愿和接入")
        await manager.stopAutomaticMaintenance()
    }
    await asyncSuite("自动维护：准备不制造回执，重复检测不重装；单来源失败隔离，未安装保留关闭") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = automationIntentStore(root)
        writeFixture("{}", to: store.configFile)
        let claude = AutomationAdapter(host: .claudeCode)
        let codex = AutomationAdapter(host: .codex, fail: true)
        let buddy = AutomationAdapter(host: .workBuddy, installed: false)
        let manager = HostIntegrationManager(
            adapters: [claude, codex, buddy], bootstrapper: AutomationBootstrapper(),
            authorization: HostEventAuthorization(
                intents: store, runs: automationRunRegistry(root, store)))
        _ = await manager.startAutomaticMaintenance()
        await manager.waitForMaintenance()
        let snapshots = await manager.snapshots()
        expect(
            store.intent(for: .claudeCode)?.enabled == true
                && store.intent(for: .codex)?.enabled == true, "迁移自动开启已安装来源")
        expect(store.intent(for: .workBuddy) == nil, "未安装来源不开启")
        expect(
            snapshots.first { $0.host == .claudeCode }?.configuration == .configured,
            "另一来源失败不阻断 Claude")
        expect(snapshots.first { $0.host == .claudeCode }?.latestReceipt == nil, "准备不制造真实证据")
        await manager.requestMaintenance(trigger: .discoveryFallback)
        await manager.waitForMaintenance()
        expect(await claude.connectCount == 1, "无回执不触发反复重装")
        expect(await codex.connectCount == 1, "永久失败等待事实变化或用户重试")
        _ = await manager.setEnabled(surface: .claudeCode, enabled: false)
        expect(store.intent(for: .claudeCode)?.enabled == false, "先可靠保存关闭")
        await manager.waitForMaintenance()
        let cleanups = await claude.disconnectCount
        expect(cleanups == 1, "后台清理自有接入，实际 \(cleanups)")
        await manager.requestMaintenance(trigger: .activation)
        await manager.waitForMaintenance()
        expect(await claude.connectCount == 1, "重新激活不得打开显式关闭")
        await manager.stopAutomaticMaintenance()
    }
}

private func automationIntentStore(_ root: URL) -> HostIntegrationIntentStore {
    .init(
        configFile: root.appendingPathComponent("config.json"),
        lockFile: root.appendingPathComponent("config.lock"))
}
private func automationRunRegistry(_ root: URL, _ store: HostIntegrationIntentStore)
    -> HostGUIRunRegistry
{
    .init(
        file: root.appendingPathComponent("run.json"),
        authorizationLockFile: store.authorizationLockFile)
}
private final class AutomationSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var notices = 0
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }; count += 1; return true
    }
    func notice() { lock.lock(); defer { lock.unlock() }; notices += 1 }
}
private struct AutomationBootstrapper: SharedRuntimeBootstrapping {
    var failureRecorder: AutomationDelayRecorder? = nil
    func inspect() -> SharedRuntimeHealth {
        failureRecorder == nil ? .ready : .damaged(reason: "fixture runtime unavailable")
    }
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        if let failureRecorder {
            failureRecorder.record(-1)
            return .failure(.binaryCopyFailure(reason: "fixture runtime unavailable"))
        }
        return .success(
            SharedRuntimeBootstrapOutcome(
                copiedBinary: false, copiedPacks: [], salvaged: [], packSelection: .untouched))
    }
}
private actor AutomationAdapter: HostIntegrationAdapter {
    nonisolated let host: HostID
    nonisolated var capabilities: [HostCapabilityBinding] {
        HostCapabilityCatalog.bindings(for: host)
    }
    let fail: Bool
    var installed: Bool
    var busyAttempts: Int
    var configured = false
    var connectCount = 0, disconnectCount = 0
    init(host: HostID, fail: Bool = false, installed: Bool = true, busyAttempts: Int = 0) {
        self.host = host; self.fail = fail; self.installed = installed;
        self.busyAttempts = busyAttempts
    }
    func setInstalled(_ installed: Bool) { self.installed = installed }
    func inspect(runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        .init(
            host: host, runtime: runtime,
            availability: installed ? .available : .notInstalled,
            configuration: configured ? .configured : .notConfigured, writability: .writable,
            activation: .none)
    }
    func connect(runtime: SharedRuntimeHealth) -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        connectCount += 1
        if busyAttempts > 0 { busyAttempts -= 1; return .failure(.transaction(.lockBusy)) }
        if fail { return .failure(.configuration(reason: "fixture conflict")) }
        configured = true
        return .success(inspect(runtime: runtime))
    }
    func disconnect(runtime: SharedRuntimeHealth) -> Result<
        HostIntegrationSnapshot, HostIntegrationActionError
    > {
        disconnectCount += 1; configured = false
        return .success(inspect(runtime: runtime))
    }
}

private struct AutomationVersionRunner: CommandRunning {
    let output: String
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        .completed(exitCode: 0, stdout: output)
    }
}

private final class AutomationDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    func record(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; recorded.append(seconds)
    }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }
}
