import ClaudioCore
import ClaudioGUICore
import Foundation

private struct BridgeSoundSpawner: ProcessSpawning {
    func spawn(executablePath: String, arguments: [String]) -> Bool { true }
}

private let bridgeHistoryCurrentInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000B1")!
private let bridgeHistoryPreviousInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000B2")!
private let bridgeHistoryScope = "bridge-history-test"

@MainActor
private func storeBridgeHistoryReceipt(
    store: HostHookReceiptStore,
    host: HostID,
    installationID: UUID = bridgeHistoryCurrentInstallationID,
    timestamp: Date = Date()
) -> HostHookReceipt {
    if case .failure(let error) = store.activate(
        host: host,
        installationID: installationID,
        scopeFingerprint: bridgeHistoryScope)
    {
        expect(false, "测试前提：\(host) installation 必须发布：\(error.description)")
    }
    let receipt = HostHookReceipt(
        installationID: installationID,
        host: host,
        nativeEvent: "UserPromptSubmit",
        semanticEvent: .taskStart,
        timestamp: Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down)),
        playbackResult: .played)
    expect(
        store.store(receipt, scopeFingerprint: { bridgeHistoryScope }) == .success(.written),
        "测试前提：\(host) 临时历史回执必须写入")
    return receipt
}

private final class BridgeBootstrapper: SharedRuntimeBootstrapping, @unchecked Sendable {
    private let lock = NSLock()
    private var bootstrapCalls = 0
    private var inspectCalls = 0
    private let failsBootstrap: Bool

    init(failsBootstrap: Bool = false) {
        self.failsBootstrap = failsBootstrap
    }

    func inspect() -> SharedRuntimeHealth {
        lock.lock()
        inspectCalls += 1
        lock.unlock()
        return .ready
    }

    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        lock.lock()
        bootstrapCalls += 1
        lock.unlock()
        if failsBootstrap {
            return .failure(.binaryCopyFailure(reason: "fixture helper update failed"))
        }
        return .success(
            SharedRuntimeBootstrapOutcome(
                copiedBinary: false,
                copiedPacks: [],
                salvaged: [],
                packSelection: .untouched))
    }

    func counts() -> (bootstrap: Int, inspect: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (bootstrapCalls, inspectCalls)
    }
}

private actor BridgeAdapter: HostIntegrationAdapter {
    nonisolated let host: HostID
    nonisolated let capabilities: [HostCapabilityBinding]
    private var connected: Bool
    private var inspectCalls = 0
    private var connectCalls = 0
    private var disconnectCalls = 0
    private let failsConnect: Bool
    private let observesReceipt: Bool
    private let bootstrapper: BridgeBootstrapper?
    private var bootstrapCountAtConnect: Int?

    init(
        host: HostID,
        connected: Bool = false,
        failsConnect: Bool = false,
        observesReceipt: Bool = true,
        bootstrapper: BridgeBootstrapper? = nil
    ) {
        self.host = host
        self.capabilities = HostCapabilityCatalog.bindings(for: host)
        self.connected = connected
        self.failsConnect = failsConnect
        self.observesReceipt = observesReceipt
        self.bootstrapper = bootstrapper
    }

    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectCalls += 1
        return snapshot(runtime: runtime)
    }

    func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        connectCalls += 1
        bootstrapCountAtConnect = bootstrapper?.counts().bootstrap
        if failsConnect {
            return .failure(.configuration(reason: "fixture 拒绝连接"))
        }
        connected = true
        return .success(snapshot(runtime: runtime))
    }

    func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        disconnectCalls += 1
        connected = false
        return .success(snapshot(runtime: runtime))
    }

    func counts() -> (inspect: Int, connect: Int, disconnect: Int) {
        (inspectCalls, connectCalls, disconnectCalls)
    }

    func bootstrapCallsSeenAtConnect() -> Int? { bootstrapCountAtConnect }

    private func snapshot(runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        guard connected else {
            return HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .available,
                configuration: .notConfigured,
                writability: .writable,
                activation: .none)
        }
        let installationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
        let binding = capabilities.first(where: { $0.isAudibleCapability })!
        let activation: HostActivationEvidence =
            observesReceipt
            ? .observed(
                HostReceiptEvidence(
                    bindingID: binding.id,
                    installationID: installationID,
                    nativeEvent: binding.nativeEvent!,
                    event: binding.event,
                    timestamp: Date(timeIntervalSince1970: 123),
                    playbackResult: .played))
            : .awaitingReceipt(installationID: installationID)
        return HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: .configured,
            writability: .writable,
            activation: activation,
            bindingActivations: observesReceipt
                ? Dictionary(
                    uniqueKeysWithValues: capabilities.filter(\.isAudibleCapability).map {
                        (
                            $0.id,
                            .observed(
                                HostReceiptEvidence(
                                    bindingID: $0.id, installationID: installationID,
                                    nativeEvent: $0.nativeEvent!, event: $0.event,
                                    timestamp: Date(timeIntervalSince1970: 123),
                                    playbackResult: .played))
                        )
                    }) : [:],
            installationID: installationID)
    }
}

private func bridgeFixture(
    root: URL,
    initiallyConnected: Bool = false,
    claudeFailsConnect: Bool = false,
    codexObservesReceipt: Bool = true,
    failsBootstrap: Bool = false
) -> (
    bridge: HostIntegrationManagerBridge,
    bootstrapper: BridgeBootstrapper,
    claude: BridgeAdapter,
    codex: BridgeAdapter,
    workBuddy: BridgeAdapter,
    receiptStore: HostHookReceiptStore,
    configFile: URL,
    packDirectory: URL
) {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    let pack = packs.appendingPathComponent("dual", isDirectory: true)
    let config = root.appendingPathComponent("config.json")
    let bootstrapper = BridgeBootstrapper(failsBootstrap: failsBootstrap)
    let claude = BridgeAdapter(
        host: .claudeCode,
        connected: initiallyConnected,
        failsConnect: claudeFailsConnect)
    let codex = BridgeAdapter(
        host: .codex,
        connected: initiallyConnected,
        observesReceipt: codexObservesReceipt,
        bootstrapper: bootstrapper)
    let workBuddy = BridgeAdapter(
        host: .workBuddy,
        connected: initiallyConnected,
        observesReceipt: false)
    let manager = HostIntegrationManager(
        adapters: [claude, codex, workBuddy],
        bootstrapper: bootstrapper)
    let audioEnvironment = AudioImportEnvironment(
        userPacksDirectory: packs,
        durationProbe: StubDurationProbe(fixedDuration: 0.1),
        packsLockFile: root.appendingPathComponent("packs.lock"))
    let receiptStore = HostHookReceiptStore(
        receiptsRoot: root.appendingPathComponent("integrations/receipts"),
        locksRoot: root.appendingPathComponent("integrations/receipt-locks"))
    let bridge = HostIntegrationManagerBridge(
        manager: manager,
        configFile: config,
        audioEnvironment: audioEnvironment,
        receiptStore: receiptStore,
        systemSoundCatalog: SystemSoundCatalog(directory: root.appendingPathComponent("system")))
    return (bridge, bootstrapper, claude, codex, workBuddy, receiptStore, config, pack)
}

@MainActor
func runHostIntegrationManagerBridgeSuites() async {
    await suite("HostIntegrationManagerBridge 首启：只 bootstrap 共享 runtime + inspect，绝不自动连接宿主") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            let state = await fixture.bridge.bootstrapSharedRuntime()
            let bootstrapCounts = fixture.bootstrapper.counts()
            let claudeCounts = await fixture.claude.counts()
            let codexCounts = await fixture.codex.counts()
            let workBuddyCounts = await fixture.workBuddy.counts()

            expect(bootstrapCounts.bootstrap == 1, "首启必须恰好调用一次共享 bootstrap")
            expect(bootstrapCounts.inspect >= 2, "manager 初始化与 bootstrap 后必须探测 runtime")
            expect(claudeCounts.connect == 0, "首启不得自动 connect Claude Code")
            expect(codexCounts.connect == 0, "首启不得自动 connect Codex")
            expect(workBuddyCounts.connect == 0, "首启不得自动 connect WorkBuddy")
            expect(claudeCounts.inspect == 1, "首启必须 inspect Claude Code")
            expect(codexCounts.inspect == 1, "首启必须 inspect Codex")
            expect(workBuddyCounts.inspect == 1, "首启必须 inspect WorkBuddy")
            expect(
                state.snapshots.map(\.host) == HostID.productVisibleCases,
                "首启状态必须同代返回三条产品宿主快照")
            expect(
                hostSourceRowPresentations(from: state.matrix).map(\.host)
                    == [.codex, .claudeCode, .workBuddy],
                "首启产品来源必须服从唯一视觉序，且不得显示 AX identity")
        }
    }

    await suite(
        "HostIntegrationManagerBridge 动作：repair 先修共享 runtime，再只重连目标 adapter"
    ) {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            _ = await fixture.bridge.refresh()

            _ = try? await fixture.bridge.perform(.connect(.claudeCode))
            var claudeCounts = await fixture.claude.counts()
            var codexCounts = await fixture.codex.counts()
            var workBuddyCounts = await fixture.workBuddy.counts()
            expect(claudeCounts.connect == 1, "connect Claude Code 必须只调用 Claude adapter")
            expect(codexCounts.connect == 0, "connect Claude Code 不得写 Codex")
            expect(workBuddyCounts.connect == 0, "connect Claude Code 不得写 WorkBuddy")

            let repair = try? await fixture.bridge.perform(.repair(.codex))
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            workBuddyCounts = await fixture.workBuddy.counts()
            expect(claudeCounts.connect == 1, "repair Codex 不得再次 connect Claude Code")
            expect(codexCounts.connect == 1, "repair 必须复用目标 adapter 的 connect")
            expect(workBuddyCounts.connect == 0, "repair Codex 不得 connect WorkBuddy")
            let bootstrapCallsAtCodexConnect =
                await fixture.codex.bootstrapCallsSeenAtConnect()
            expect(
                fixture.bootstrapper.counts().bootstrap == 1
                    && bootstrapCallsAtCodexConnect == 1,
                "repair 必须先修复共享 helper，再重建 Codex 连接")
            expect(
                repair?.feedbackMessage == "Codex 已连接，当前代次已收到真实回执",
                "刷新后已有当前代次回执时，反馈不得还说等待确认")

            let disconnected = try? await fixture.bridge.perform(.disconnect(.claudeCode))
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            workBuddyCounts = await fixture.workBuddy.counts()
            expect(claudeCounts.disconnect == 1, "disconnect 必须调用目标 Claude adapter")
            expect(codexCounts.disconnect == 0, "disconnect Claude Code 不得写 Codex")
            expect(workBuddyCounts.disconnect == 0, "disconnect Claude Code 不得写 WorkBuddy")
            expect(
                disconnected?.state.snapshots.first(where: { $0.host == .codex })?
                    .configuration == .configured,
                "断开一侧后刷新不得清空另一侧状态")
        }
    }

    await suite("Codex repair：helper 更新失败时不改写宿主连接") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(
                root: root, initiallyConnected: true, failsBootstrap: true)
            _ = await fixture.bridge.refresh()

            let repair = try? await fixture.bridge.perform(.repair(.codex))
            expect(fixture.bootstrapper.counts().bootstrap == 1, "显式修复必须尝试更新 helper")
            let codexCounts = await fixture.codex.counts()
            expect(
                codexCounts.connect == 0,
                "helper 修复失败时不得重建 Codex hooks 或连接代次")
            expect(repair?.feedbackKind == .failure, "修复失败必须呈现失败反馈")
        }
    }

    await suite("WorkBuddy 动作：只改变连接事实，不创建或删除 Surface 声音覆盖") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            let originalConfig = Data(
                """
                {
                  "selected_pack": "dual",
                  "events": { "task_start": true, "stop": true },
                  "surface_overrides": {
                    "workbuddy": { "selected_pack": "workbuddy-custom" }
                  },
                  "future_field": { "preserve": true }
                }
                """.utf8)
            writeFixture(originalConfig, to: fixture.configFile)

            let connected = try? await fixture.bridge.perform(.connect(.workBuddy))
            var workBuddyCounts = await fixture.workBuddy.counts()
            var claudeCounts = await fixture.claude.counts()
            var codexCounts = await fixture.codex.counts()
            expect(workBuddyCounts.connect == 1, "Connect 必须只调用 WorkBuddy adapter")
            expect(
                claudeCounts.connect == 0 && codexCounts.connect == 0,
                "Connect WorkBuddy 不得写 Claude Code 或 Codex adapter")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == originalConfig,
                "Connect 不得隐式创建、重写或删除 Surface 声音覆盖")
            expect(
                connected?.state.matrix.summary(for: .workBuddy)
                    == .awaitingActivation(supported: 4, total: 5),
                "Connect 后 WorkBuddy 必须进入 4/5 awaiting，不得伪造真实回执")

            let repaired = try? await fixture.bridge.perform(.repair(.workBuddy))
            workBuddyCounts = await fixture.workBuddy.counts()
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            expect(workBuddyCounts.connect == 2, "Repair 必须复用 WorkBuddy connect seam")
            expect(
                claudeCounts.connect == 0 && codexCounts.connect == 0,
                "Repair WorkBuddy 不得 connect Claude Code 或 Codex adapter")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == originalConfig,
                "Repair 不得把连接动作扩张成声音偏好写入")
            let expectedRepair = PreviewFixtures.workBuddyVisualScenarios.first {
                $0.phase == .repairedAwaitingActivation
            }
            let repairedRow = repaired.flatMap {
                hostSourceRowPresentations(from: $0.state.matrix).first { $0.host == .workBuddy }
            }
            let expectedRepairRow = expectedRepair.flatMap {
                hostSourceRowPresentations(from: $0.state.matrix).first { $0.host == .workBuddy }
            }
            expect(
                repairedRow == expectedRepairRow,
                "真实 Repair outcome 必须接入 repaired-awaiting fixture 的 WorkBuddy 来源行")
            expect(
                Event.allCases.map {
                    repaired?.state.matrix.cell(host: .workBuddy, event: $0)?.state
                }
                    == Event.allCases.map {
                        expectedRepair?.state.matrix.cell(host: .workBuddy, event: $0)?.state
                    },
                "真实 Repair outcome 的五格状态必须与 repaired-awaiting fixture 完全一致")

            let disconnected = try? await fixture.bridge.perform(.disconnect(.workBuddy))
            workBuddyCounts = await fixture.workBuddy.counts()
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            expect(workBuddyCounts.disconnect == 1, "Disconnect 必须只调用 WorkBuddy adapter")
            expect(
                claudeCounts.disconnect == 0 && codexCounts.disconnect == 0,
                "Disconnect WorkBuddy 不得写 Claude Code 或 Codex adapter")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == originalConfig,
                "Disconnect 不得删除既有 Surface 声音覆盖或未来字段")
            expect(
                disconnected?.state.matrix.summary(for: .workBuddy)
                    == .notConnected(supported: 4, total: 5),
                "Disconnect 后必须回到 WorkBuddy 4/5 未连接态")
        }
    }

    await suite("WorkBuddy Connect：缺少 Surface override 时也不隐式创建") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            let originalConfig = Data(
                """
                {
                  "selected_pack": "dual",
                  "events": { "task_start": true, "stop": true },
                  "future_field": { "preserve": true }
                }
                """.utf8)
            writeFixture(originalConfig, to: fixture.configFile)

            _ = try? await fixture.bridge.perform(.connect(.workBuddy))

            expect(
                (try? Data(contentsOf: fixture.configFile)) == originalConfig,
                "Connect 不得在缺少 override 时创建 WorkBuddy Surface 声音覆盖")
        }
    }

    await suite("HostIntegrationManagerBridge Codex 待确认：只在无当前代次回执时显示固定文案") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, codexObservesReceipt: false)
            let outcome = try? await fixture.bridge.perform(.connect(.codex))
            expect(
                outcome?.feedbackMessage == "claudi0 已写好，等待 Codex 确认",
                "Codex 配置完成但没有真实回执时，必须保留固定待确认文案")
            expect(
                outcome?.state.snapshots.first(where: { $0.host == .codex })?.activation
                    == .awaitingReceipt(
                        installationID: UUID(
                            uuidString: "00000000-0000-4000-8000-0000000000B1")!),
                "反馈必须与同一份 awaiting snapshot 一致")
        }
    }

    await suite("HostIntegrationManagerBridge 历史：bootstrap 与 refresh 读取三来源真实旧／当前回执") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(
                root: root, initiallyConnected: true, codexObservesReceipt: false)
            let now = Date()
            var expected: [HostID: [HostHookReceipt]] = [:]
            for (index, host) in HostID.productVisibleCases.enumerated() {
                let previous = storeBridgeHistoryReceipt(
                    store: fixture.receiptStore,
                    host: host,
                    installationID: bridgeHistoryPreviousInstallationID,
                    timestamp: now.addingTimeInterval(-Double(index + 10)))
                let current = storeBridgeHistoryReceipt(
                    store: fixture.receiptStore,
                    host: host,
                    timestamp: now.addingTimeInterval(-Double(index)))
                expected[host] = [current, previous]
            }

            let bootstrapped = await fixture.bridge.bootstrapSharedRuntime()
            let refreshed = await fixture.bridge.refresh()
            for state in [bootstrapped, refreshed] {
                let content = integrationDestinationContent(state: state)
                expect(
                    Set(state.receiptHistories.keys) == Set(HostID.productVisibleCases),
                    "bridge 历史必须恰好来自三个产品来源，不混入 AX identity")
                for host in HostID.productVisibleCases {
                    expect(
                        state.receiptHistories[host]
                            == fixture.receiptStore.receiptHistorySnapshot(host: host),
                        "\(host) bridge 历史必须保留同一真实 store 的 snapshot")
                    expect(
                        state.receiptHistories[host]?.receipts == expected[host],
                        "\(host) 旧／当前回执必须按时间保留且不得串入其它来源")
                    expect(
                        content.facts(for: host)?.receiptHistory?.entries.map(\.receipt)
                            == expected[host],
                        "\(host) content 必须消费 bridge 的完整历史，不能只复制 latestReceipt")
                    expect(
                        content.facts(for: host)?.receiptHistory?.entries.map(\.generation)
                            == [.current, .previous],
                        "\(host) content 必须相对 manager installation 区分当前／旧代次")
                }
                for host in [HostID.codex, .workBuddy] {
                    expect(
                        state.snapshots.first(where: { $0.host == host })?.activation
                            == .awaitingReceipt(installationID: bridgeHistoryCurrentInstallationID),
                        "\(host) 当前 history 回执不得替代 adapter 的 awaiting activation")
                    expect(
                        content.agent(for: host)?.status == .awaitingActivation,
                        "\(host) history 不得点亮 Agent 的当前激活状态")
                }
            }
        }
    }

    await suite("HostIntegrationManagerBridge 历史读取：损坏、不可读与缺失仍保留各来源事实") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            let receipt = storeBridgeHistoryReceipt(store: fixture.receiptStore, host: .claudeCode)
            _ = storeBridgeHistoryReceipt(store: fixture.receiptStore, host: .workBuddy)
            let damagedDirectory = fixture.receiptStore.historyRoot.appendingPathComponent(
                HostID.claudeCode.surfaceID.rawValue, isDirectory: true)
            writeFixture("{broken", to: damagedDirectory.appendingPathComponent("broken.json"))
            let unreadableDirectory = fixture.receiptStore.historyRoot.appendingPathComponent(
                HostID.workBuddy.surfaceID.rawValue, isDirectory: true)
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path)
            } catch {
                expect(false, "测试前提：WorkBuddy 历史目录必须设为不可读：\(error)")
                return
            }
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path)
            }

            let state = await fixture.bridge.refresh()
            let content = integrationDestinationContent(state: state)
            expect(
                state.receiptHistories[.claudeCode]
                    == HostHookReceiptHistorySnapshot(
                        receipts: [receipt], state: .damaged(skippedItemCount: 1)),
                "损坏项必须保留计数与同次扫描中的可用回执")
            expect(
                state.receiptHistories[.workBuddy]
                    == HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable),
                "不可读历史不得被伪装成正常空列表")
            expect(
                state.receiptHistories[.codex]
                    == HostHookReceiptHistorySnapshot(receipts: [], state: .missing),
                "从未生成的 Codex 历史必须保留 missing 事实")
            for host in HostID.productVisibleCases {
                expect(
                    content.facts(for: host)?.receiptHistory?.state
                        == state.receiptHistories[host]?.state,
                    "\(host) content 必须保持损坏／不可读／缺失状态，不冻结其它来源")
            }
        }
    }

    await suite("HostIntegrationManagerBridge 清除历史：逐来源读回真实空历史，其它来源与激活不变") {
        for target in HostID.productVisibleCases {
            await withTempDirectory { root in
                let fixture = bridgeFixture(root: root)
                for host in HostID.productVisibleCases {
                    _ = storeBridgeHistoryReceipt(store: fixture.receiptStore, host: host)
                }
                let before = await fixture.bridge.refresh()
                let receiptFile = fixture.receiptStore.receiptFile(
                    host: target, nativeEvent: "UserPromptSubmit")!
                let stableReceipt = try? Data(contentsOf: receiptFile)

                let outcome = try? await fixture.bridge.perform(.clearReceiptHistory(target))

                expect(outcome != nil, "\(target) 清除成功必须返回刷新后的 outcome")
                expect(
                    outcome?.feedbackMessage == "已清除 \(target.displayName) 回执历史",
                    "清除成功必须返回可见、宿主限定反馈")
                expect(
                    outcome?.state.receiptHistories[target]
                        == fixture.receiptStore.receiptHistorySnapshot(host: target)
                        && outcome?.state.receiptHistories[target]?.receipts.isEmpty == true,
                    "\(target) 清除成功必须读取实际 store 空历史，不能只清空 UI")
                expect(
                    outcome.map { integrationDestinationContent(state: $0.state) }
                        .flatMap { $0.facts(for: target)?.receiptHistory }?.entries.isEmpty == true,
                    "\(target) 清除后的 content 必须不再显示旧条目")
                expect(
                    fixture.receiptStore.currentInstallationID(host: target)
                        == bridgeHistoryCurrentInstallationID
                        && (try? Data(contentsOf: receiptFile)) == stableReceipt,
                    "\(target) 清除历史不得撤销 marker 或删除稳定回执")
                expect(
                    outcome?.state.snapshots == before.snapshots,
                    "清除历史不得更改任何来源的连接与 activation snapshot")
                for other in HostID.productVisibleCases where other != target {
                    expect(
                        outcome?.state.receiptHistories[other] == before.receiptHistories[other]
                            && fixture.receiptStore.receiptHistorySnapshot(host: other)
                                == before.receiptHistories[other],
                        "清除 \(target) 不得删除或重写 \(other) 历史")
                }
            }
        }
    }

    await suite("HostIntegrationManagerBridge 清除历史锁忙：返回 failure 与真实历史，允许重试") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            for host in HostID.productVisibleCases {
                _ = storeBridgeHistoryReceipt(store: fixture.receiptStore, host: host)
            }
            let before = await fixture.bridge.refresh()
            let lock = FileLock(
                path: fixture.receiptStore.installationLockFile(host: .codex).path)
            guard lock.attemptLock() == .acquired else {
                expect(false, "测试前提：Codex installation lock 必须占用")
                return
            }
            defer { lock.unlock() }

            let outcome = try? await fixture.bridge.perform(.clearReceiptHistory(.workBuddy))

            expect(outcome?.feedbackKind == .failure, "lockBusy 必须返回可见失败 outcome")
            expect(
                outcome?.feedbackMessage.contains(HostHookReceiptStoreError.lockBusy.description)
                    == true,
                "失败反馈必须保留锁忙的可重试原因")
            expect(
                outcome?.state.receiptHistories == before.receiptHistories,
                "清除失败必须同代读回并保留三来源历史，不能显示虚假空列表")
            expect(
                outcome?.state.snapshots == before.snapshots,
                "清除失败不得改变各来源连接与当前激活事实")
            for host in HostID.productVisibleCases {
                expect(
                    fixture.receiptStore.receiptHistorySnapshot(host: host)
                        == before.receiptHistories[host],
                    "lockBusy 必须让 \(host) 磁盘历史保持原样")
            }

            lock.unlock()
            let retried = try? await fixture.bridge.perform(.clearReceiptHistory(.workBuddy))
            expect(
                retried?.feedbackKind == .information
                    && retried?.state.receiptHistories[.workBuddy]?.receipts.isEmpty == true,
                "锁释放后重试必须成功清除并读取真实空历史")
        }
    }

    await suite("HostIntegrationManagerBridge 动作失败：仍返回全产品新状态与 failure 反馈，不冻结另一侧") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, claudeFailsConnect: true)
            _ = await fixture.bridge.refresh()
            let codexBefore = await fixture.codex.counts().inspect

            let outcome = try? await fixture.bridge.perform(.connect(.claudeCode))
            let codexAfter = await fixture.codex.counts().inspect

            expect(outcome?.feedbackKind == .failure, "adapter 失败必须成为可见 failure outcome")
            expect(
                outcome?.feedbackMessage.contains("fixture 拒绝连接") == true,
                "失败反馈必须保留 manager 的具体原因")
            expect(
                outcome?.state.snapshots.map(\.host) == HostID.productVisibleCases,
                "单侧失败仍必须同代返回三条产品宿主快照")
            expect(
                codexAfter > codexBefore,
                "Claude 连接失败后仍必须刷新 Codex，不能把另一侧冻结在旧状态")
        }
    }

    await suite(
        "HostIntegrationManagerBridge 矩阵：真实 config + manifest 依次投影 audible、muted、missingSound"
    ) {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, initiallyConnected: true)
            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":true}}"#,
                to: fixture.configFile)
            writeFixture(
                #"{"id":"dual","events":{"stop":"stop.mp3","stop_failure":"failure.mp3","notification":"notification.mp3","subagent_stop":"subagent.mp3"}}"#,
                to: fixture.packDirectory.appendingPathComponent("manifest.json"))
            for file in ["stop.mp3", "failure.mp3", "notification.mp3", "subagent.mp3"] {
                writeFixture(Data([0x01]), to: fixture.packDirectory.appendingPathComponent(file))
            }

            var state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .audible,
                "当前包真实存在且事件启用时，Codex PermissionRequest 必须是 audible")

            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":false}}"#,
                to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .notification)?.state == .muted
                    && state.matrix.cell(host: .codex, event: .notification)?.state == .muted,
                "静音配置变化必须同时进入两个宿主的同一语义格")

            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":true}}"#,
                to: fixture.configFile)
            try? FileManager.default.removeItem(
                at: fixture.packDirectory.appendingPathComponent("notification.mp3"))
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .notification)?.state
                    == .missingSound
                    && state.matrix.cell(host: .codex, event: .notification)?.state
                        == .missingSound,
                "manifest 声明文件消失后必须投影 missingSound，不得沿用 all-false 占位矩阵")

            writeFixture(
                #"{"selected_pack":"dual","master_volume":0,"events":{"notification":true}}"#,
                to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .stop)?.state == .muted
                    && state.matrix.cell(host: .codex, event: .stop)?.state == .muted,
                "master_volume == 0 必须把所有 supported 格投影为 muted")
            expect(state.masterVolumeIsZero, "bridge 必须保留 muted 来自总音量为零的原因")
            let projected = hostCapabilityMatrixPresentation(
                from: state.matrix,
                mutedReason: state.masterVolumeIsZero ? .masterVolumeZero : .eventDisabled)
            expect(
                projected.cell(host: .claudeCode, event: .stop)?.muteReason
                    == .masterVolumeZero,
                "presentation 格必须保留总音量原因，恢复层不得再猜成逐事件静音")
            expect(
                state.matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
                "全局静音不得把 Codex 不支持的 StopFailure 误画成 muted")
        }
    }

    await suite("HostIntegrationManagerBridge uses the selected system sound for audibility") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, initiallyConnected: true)
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            let sound = sounds.appendingPathComponent("Basso.aiff")
            writeFixture("system", to: sound)
            writeFixture(
                #"{"id":"dual","events":{"stop":"stop.mp3","notification":{"system_sound":"Basso"}}}"#,
                to: fixture.packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("pack", to: fixture.packDirectory.appendingPathComponent("stop.mp3"))
            var config = ClaudioConfig(
                selectedPack: "dual", systemSounds: ["notification": "Basso"])
            try! JSONEncoder().encode(config).write(to: fixture.configFile)
            let environment = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"), configFile: fixture.configFile,
                userPacksDirectory: fixture.packDirectory.deletingLastPathComponent(),
                systemSoundDirectory: sounds, spawner: BridgeSoundSpawner(),
                debounceStateFile: root.appendingPathComponent("debounce"), debounceInterval: 0,
                logFile: root.appendingPathComponent("log"),
                logLockFile: root.appendingPathComponent("log.lock"))

            expect(
                playSoundEvent("notification", environment: environment)
                    == .played(event: .notification, filePath: sound.path),
                "the selected system sound plays while its pack event file is missing")
            var state = await fixture.bridge.refresh()
            for host in [HostID.claudeCode, .codex] {
                expect(
                    state.matrix.cell(host: host, event: .notification)?.state == .audible,
                    "\(host) must report the available system sound as audible")
                expect(
                    state.matrix.cell(host: host, event: .stop)?.state == .audible,
                    "events without a system choice retain pack coverage")
            }

            writeFixture(
                "pack", to: fixture.packDirectory.appendingPathComponent("notification.mp3"))
            try! FileManager.default.removeItem(at: sound)
            expect(
                playSoundEvent("notification", environment: environment) == .notReady,
                "missing selected system sound fails closed despite available pack audio")
            state = await fixture.bridge.refresh()
            for host in [HostID.claudeCode, .codex] {
                expect(
                    state.matrix.cell(host: host, event: .notification)?.state == .missingSound,
                    "\(host) must refresh system availability without falling back to pack coverage"
                )
            }

            config.eventsEnabled["notification"] = false
            try! JSONEncoder().encode(config).write(to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .muted,
                "the event switch still takes priority over source availability")
            config.eventsEnabled["notification"] = true
            config.masterVolume = 0
            try! JSONEncoder().encode(config).write(to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .muted,
                "zero group volume still mutes the selected system sound")
            expect(
                state.matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
                "source selection does not change host capability")

            config.masterVolume = 0.8
            writeFixture(
                #"{"id":"dual","events":{"stop":"stop.mp3","notification":"notification.mp3"}}"#,
                to: fixture.packDirectory.appendingPathComponent("manifest.json"))
            try! JSONEncoder().encode(config).write(to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .audible,
                "clearing the selection explicitly restores available pack audio")
        }
    }

    await suite("HostIntegrationManagerBridge 矩阵：每个 surface 消费自己的 effective pack") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, initiallyConnected: true)
            let codexPack = fixture.packDirectory.deletingLastPathComponent()
                .appendingPathComponent("codex-only")
            writeFixture(
                """
                {
                  "selected_pack": "dual",
                  "events": { "notification": true },
                  "surface_overrides": {
                    "codex": { "selected_pack": "codex-only" }
                  }
                }
                """,
                to: fixture.configFile)
            writeFixture(
                #"{"id":"dual","events":{"notification":"notification.mp3"}}"#,
                to: fixture.packDirectory.appendingPathComponent("manifest.json"))
            writeFixture(
                "audio", to: fixture.packDirectory.appendingPathComponent("notification.mp3"))
            writeFixture(
                #"{"id":"codex-only","events":{}}"#,
                to: codexPack.appendingPathComponent("manifest.json"))

            let state = await fixture.bridge.refresh()

            expect(
                state.matrix.cell(host: .claudeCode, event: .notification)?.state == .audible,
                "Claude Code 未覆盖时必须继续继承全局 dual pack")
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .audible,
                "无目录上下文的矩阵只报告默认组，旧来源覆盖不再生效")
        }
    }
}
