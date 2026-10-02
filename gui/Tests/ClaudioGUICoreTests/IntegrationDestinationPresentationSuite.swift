import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private func integrationHistoryTestReceipt(
    host: HostID,
    installationID: UUID,
    event: Event = .taskStart,
    timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> HostHookReceipt {
    HostHookReceipt(
        installationID: installationID,
        host: host,
        nativeEvent: event == .taskStart ? "UserPromptSubmit" : "Stop",
        semanticEvent: event,
        timestamp: timestamp,
        playbackResult: .played)
}

@MainActor
func runIntegrationDestinationPresentationSuites() {
    suite("集成 destination Agent 行：固定消费 productVisibleCases 顺序，不混入 AX identity") {
        let content = integrationDestinationTestContent()
        expect(
            integrationAgentHostOrder() == [.claudeCode, .codex, .workBuddy],
            "Agent 顺序必须固定为 Claude Code → Codex → WorkBuddy")
        expect(
            content.agents.map(\.host) == HostID.productVisibleCases,
            "destination content 必须按 productVisibleCases 投影 Agent 行")
        expect(
            content.agents.map(\.title) == ["Claude Code", "Codex", "WorkBuddy"],
            "Agent 行只显示产品名称，不显示 AX identity 或宿主 Logo")
        expect(
            Set(content.agents.map(\.host)).isDisjoint(with: [.chatGPTDesktopAX, .claudeDesktopAX]),
            "AX-only identity 不得进入产品 Agent 行")
    }

    suite("集成 destination 五态投影：Toggle、Badge 与连接状态附加动作穷举") {
        let expected:
            [(
                IntegrationDestinationTestStatus, HostSourceRowStatus, String, Bool,
                [IntegrationConnectionRowAction]
            )] = [
                (.ready, .ready, "已激活", true, [.redetect]),
                (.awaitingActivation, .awaitingActivation, "待回执", true, [.redetect]),
                (.legacy, .legacy, "旧版连接", true, [.repair(.workBuddy), .redetect]),
                (.notConnected, .notConnected, "未连接", false, [.redetect]),
                (.needsAttention, .needsAttention, "需要处理", true, [.repair(.workBuddy), .redetect]),
            ]

        for (status, expectedStatus, badge, isOn, _) in expected {
            let content = integrationDestinationTestContent(
                statuses: [.workBuddy: status])
            guard
                let agent = content.agent(for: .workBuddy),
                let facts = content.facts(for: .workBuddy)
            else {
                expect(false, "\(status) 必须生成 WorkBuddy Agent 与 host facts")
                continue
            }
            expect(agent.status == expectedStatus, "\(status) status 必须保持 typed 事实")
            expect(agent.badgeText == badge, "\(status) badge 必须为 \(badge)")
            expect(agent.isOn == isOn, "\(status) Toggle 真值必须来自连接事实")
            expect(agent.isToggleEnabled, "静止状态 Toggle 必须可用")
            expect(
                integrationConnectionStatusActions(for: facts)
                    == integrationConnectionStatusActions(for: facts.row).map {
                        switch $0 {
                        case .copyHooksCommand: IntegrationConnectionRowAction.copyHooks
                        case .redetect: .redetect
                        case .repair(let host): .repair(host)
                        case .connect, .disconnect, .clearReceiptHistory: fatalError()
                        }
                    },
                "\(status) status row 必须来自同一个五态 action projection")
        }

        let codexAwaiting = integrationDestinationTestContent(
            statuses: [.codex: .awaitingActivation])
        expect(
            codexAwaiting.connectionSection(for: .codex)?.row(.connectionStatus)?.actions
                == [.copyHooks, .repair(.codex), .redetect],
            "Codex 待回执必须保留 /hooks 与显式修复入口")
        let codexReady = integrationDestinationTestContent(statuses: [.codex: .ready])
        expect(
            codexReady.connectionSection(for: .codex)?.row(.connectionStatus)?.actions
                == [.repair(.codex), .redetect],
            "Codex 已激活仍须允许用户修复旧 helper 与连接")
    }

    suite("集成 destination 四行 typed contract：顺序、Surface 范围与动作归属固定") {
        let content = integrationDestinationTestContent(statuses: [.workBuddy: .awaitingActivation])
        guard let facts = content.facts(for: .workBuddy),
            let section = content.connectionSection(for: .workBuddy)
        else {
            expect(false, "WorkBuddy 必须生成 connection section")
            return
        }
        expect(
            section.rows.map(\.kind) == IntegrationConnectionRowKind.allCases,
            "连接组必须恰好按连接状态、接入方式、事件与提示音、脱敏回执历史四行渲染")
        expect(section.host == .workBuddy, "四行组必须绑定当前选中的 Host Surface")
        expect(
            facts.mechanism == .nativeHooks
                && hostIntegrationMechanismDisplayName(facts.mechanism) == "原生 hooks",
            "WorkBuddy 接入方式必须来自 descriptor，不伪造 Core 不存在的机制子类型")
        expect(
            section.row(.eventsAndSounds)?.actions == [.manageSoundScopes],
            "声音入口不携带所选 Host；第三行只负责打开默认组／工作区")
        let chinese = ClaudioL10n(language: .zhHans)
        expect(
            section.row(.eventsAndSounds)?.title == chinese.text(.integrationsEventsAndSounds)
                && section.row(.eventsAndSounds)?.caption
                    == chinese.text(.integrationsSurfaceEventsCaption),
            "第三行的基础投影与中文展示应表达相同的默认组／工作区语义")
        for host in HostID.productVisibleCases {
            expect(
                content.connectionSection(for: host)?.row(.eventsAndSounds)?.actions
                    == [.manageSoundScopes],
                "每个 Host 的声音入口都必须是同一个无 Host 目标的动作")
        }
        expect(
            section.row(.receiptHistory)?.actions == [.clearReceiptHistory(.workBuddy)],
            "回执清除只允许从第四行进入确认")
        expect(
            section.row(.mechanism)?.actions == [.copyConfigurationSource(.workBuddy)],
            "配置来源存在时复制动作只允许属于第二行")
        expect(
            section.infoText?.contains("已配置") == true
                && section.infoText?.contains("已激活") == true,
            "信息 callout 必须保留 configured 与 activated 的事实边界")

        let noSource = integrationDestinationTestContent(
            statuses: [.workBuddy: .awaitingActivation],
            configurationSources: [:])
        expect(
            noSource.connectionSection(for: .workBuddy)?.row(.mechanism)?.actions.isEmpty == true,
            "manager 没有提供配置来源时不得伪造复制路径")
        expect(
            noSource.facts(for: .workBuddy)?.connectionCaption.contains("暂无当前安装实例回执")
                == true,
            "没有当前安装实例回执时必须明确显示暂无回执")

        if let awaitingFacts = content.facts(for: .workBuddy) {
            let diagnosticReceipt = HostReceiptEvidence(
                installationID: UUID(uuidString: "00000000-0000-4000-8000-00000000D002")!,
                nativeEvent: "Notification",
                event: .notification,
                timestamp: Date(timeIntervalSince1970: 1_722_000_001),
                playbackResult: .played)
            let awaitingWithDiagnosticReceipt = IntegrationDestinationHostFacts(
                host: .workBuddy,
                row: awaitingFacts.row,
                configurationSource: awaitingFacts.configurationSource,
                latestReceiptText: "WorkBuddy · 待响应 · 2024-08-01 · 已播放",
                latestReceiptEvidence: diagnosticReceipt)
            expect(
                awaitingWithDiagnosticReceipt.connectionDescription.contains("已配置")
                    && !awaitingWithDiagnosticReceipt.connectionDescription.contains("已取得"),
                "非激活事件回执只能作为诊断，不能点亮待回执状态")
        }
    }

    suite("集成 destination 共享事实：矩阵仍可供其他消费者使用，Agent 不读取 GUI 文件") {
        let state = integrationDestinationTestState(
            statuses: [.codex: .awaitingActivation],
            masterVolumeIsZero: true)
        let content = integrationDestinationContent(state: state)
        expect(content.matrix.rows.count == Event.allCases.count, "共享矩阵仍须保留五个事件语义行")
        expect(
            content.matrix.hostColumns == hostSurfacePresentationOrder(from: content.sourceRows),
            "共享矩阵列仍消费既有 source presentation 顺序")
        expect(
            content.matrix.cell(host: .claudeCode, event: .taskStart)?.muteReason
                == .masterVolumeZero,
            "主音量为零的事实仍通过共享矩阵传给非 destination 消费者")
        expect(
            content.agents.map(\.host) == [.claudeCode, .codex, .workBuddy],
            "共享矩阵的历史列顺序不得改变 destination Agent 的固定顺序")
    }

    suite("集成 destination 事件能力：五事件支持／实现／激活分别投影，保留已激活绑定") {
        let content = integrationDestinationTestContent()
        for host in HostID.productVisibleCases {
            guard let facts = content.facts(for: host) else {
                expect(false, "\(host) 必须存在能力事实")
                continue
            }
            expect(
                facts.capabilityReceipts.map(\.binding)
                    == HostCapabilityCatalog.bindings(for: host),
                "\(host) 能力明细必须保留 catalogue 所有绑定，不能只显示可播放项")
            expect(
                Set(facts.capabilityReceipts.map { $0.binding.event }) == Set(Event.allCases),
                "\(host) 能力明细必须覆盖五个公共事件")
            expect(
                facts.capabilityReceipts.filter { $0.binding.isAudibleCapability }
                    == facts.bindingReceipts,
                "\(host) 已有可播放绑定的当前 activation evidence 必须原样保留")
            expect(
                facts.bindingReceipts.allSatisfy {
                    if case .observed = $0.activation { return true }
                    return false
                },
                "ready fixture 的可播放绑定必须继续保留 observed 回执")
        }
        let codexFailure = content.facts(for: .codex)?.capabilityReceipts.first {
            $0.binding.event == .stopFailure
        }
        expect(
            codexFailure?.binding.support == .unsupported
                && codexFailure?.activation == HostActivationEvidence.none,
            "Codex StopFailure 必须显示 unsupported，不得因 Host ready 伪造激活")
        let workBuddyFailure = content.facts(for: .workBuddy)?.capabilityReceipts.first {
            $0.binding.event == .stopFailure
        }
        expect(
            workBuddyFailure?.binding.support == .supported
                && workBuddyFailure?.binding.implementation == .notImplemented
                && workBuddyFailure?.activation == HostActivationEvidence.none,
            "WorkBuddy StopFailure 必须分别保留支持、尚未实现、无当前回执三个事实")
    }

    suite("集成 destination 历史：三来源独立传递完整回执，不提升当前激活") {
        let statuses = Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, IntegrationDestinationTestStatus.awaitingActivation)
            })
        var state = integrationDestinationTestState(statuses: statuses)
        let before = integrationDestinationContent(state: state)
        let snapshotsBefore = state.snapshots
        let previousInstallationID = UUID(
            uuidString: "00000000-0000-4000-8000-00000000D002")!
        for (index, host) in HostID.productVisibleCases.enumerated() {
            let installationID = state.snapshots.first { $0.host == host }!.installationID!
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let current = integrationHistoryTestReceipt(
                host: host, installationID: installationID, timestamp: timestamp)
            let previous = integrationHistoryTestReceipt(
                host: host,
                installationID: previousInstallationID,
                timestamp: timestamp.addingTimeInterval(-1))
            state.receiptHistories[host] = HostHookReceiptHistorySnapshot(
                receipts: [current, previous], state: .available)
        }

        let content = integrationDestinationContent(state: state)

        expect(
            state.snapshots == snapshotsBefore && content.agents == before.agents
                && content.matrix == before.matrix,
            "历史分代只供诊断展示，不能升级 snapshot activation、Agent 或可听矩阵")
        for host in HostID.productVisibleCases {
            let history = content.facts(for: host)?.receiptHistory
            expect(
                history?.entries.map(\.receipt) == state.receiptHistories[host]?.receipts,
                "\(host) 必须显示该来源完整历史，而非 latestReceipt 占位")
            expect(
                history?.entries.allSatisfy { $0.receipt.host == host } == true
                    && history?.entries.map(\.generation) == [.current, .previous],
                "\(host) 历史必须隔离其它来源并区分当前／旧代次")
            expect(
                content.facts(for: host)?.latestReceiptEvidence == nil
                    && content.agent(for: host)?.status == .awaitingActivation,
                "\(host) 当前历史条目不得伪造当前安装实例的 activation evidence")
        }
        expect(
            before.hostFacts.allSatisfy { $0.receiptHistory == nil },
            "未提供 history snapshot 时不得伪造已读取的空历史")
    }

    suite("集成 destination 历史分代与身份：缺少 installation 为 unknown，条目身份稳定且可区分") {
        let snapshot = integrationDestinationTestSnapshot(
            host: .claudeCode, status: .awaitingActivation)
        let currentInstallationID = snapshot.installationID!
        let previousInstallationID = UUID(
            uuidString: "00000000-0000-4000-8000-00000000D002")!
        let current = integrationHistoryTestReceipt(
            host: .claudeCode, installationID: currentInstallationID)
        let previous = integrationHistoryTestReceipt(
            host: .claudeCode, installationID: previousInstallationID)
        let otherBinding = integrationHistoryTestReceipt(
            host: .claudeCode, installationID: currentInstallationID, event: .stop)
        let later = integrationHistoryTestReceipt(
            host: .claudeCode,
            installationID: currentInstallationID,
            timestamp: current.timestamp.addingTimeInterval(0.5))
        let history = HostHookReceiptHistorySnapshot(
            receipts: [current, previous, otherBinding, later], state: .available)
        let presentation = IntegrationReceiptHistoryPresentation(
            host: .claudeCode, snapshot: snapshot, history: history)
        let repeated = IntegrationReceiptHistoryPresentation(
            host: .claudeCode, snapshot: snapshot, history: history)
        expect(
            presentation.entries.map(\.generation) == [.current, .previous, .current, .current],
            "历史分代必须逐条比对 manager snapshot 的 installation ID")
        expect(
            presentation.entries.map(\.id) == repeated.entries.map(\.id)
                && Set(presentation.entries.map(\.id)).count == history.receipts.count,
            "entry 身份必须跨重投影稳定，并区分 installation、binding 和 timestamp")

        for unknownSnapshot in [
            nil,
            HostIntegrationSnapshot.disconnected(host: .claudeCode),
            integrationDestinationTestSnapshot(host: .codex, status: .ready),
        ] as [HostIntegrationSnapshot?] {
            let unknown = IntegrationReceiptHistoryPresentation(
                host: .claudeCode, snapshot: unknownSnapshot, history: history)
            expect(
                unknown.entries.allSatisfy { $0.generation == .unknown }
                    && unknown.entries.map(\.receipt) == history.receipts,
                "没有该来源可信 installation 时必须保留条目并显示 unknown，不能猜测当前代次")
        }

        let foreign = integrationHistoryTestReceipt(
            host: .codex, installationID: currentInstallationID)
        let mixed = IntegrationReceiptHistoryPresentation(
            host: .claudeCode,
            snapshot: snapshot,
            history: HostHookReceiptHistorySnapshot(
                receipts: [current, foreign], state: .available))
        expect(
            mixed.entries.map(\.receipt) == [current],
            "即使调用方提供混合历史，Claude Code presentation 也不得显示 Codex 条目")
    }

    suite("集成 destination 历史读取状态：available、missing、damaged 与 unreadable 保真") {
        let states: [HostHookReceiptHistoryState] = [
            .available, .missing, .damaged(skippedItemCount: 3), .unreadable,
        ]
        for historyState in states {
            var state = integrationDestinationTestState(statuses: [.workBuddy: .awaitingActivation])
            let before = integrationDestinationContent(state: state)
            let receipt = integrationHistoryTestReceipt(
                host: .workBuddy,
                installationID: state.snapshots.first { $0.host == .workBuddy }!.installationID!)
            let receipts: [HostHookReceipt] =
                historyState == .damaged(skippedItemCount: 3) ? [receipt] : []
            state.receiptHistories[.workBuddy] = HostHookReceiptHistorySnapshot(
                receipts: receipts, state: historyState)
            let content = integrationDestinationContent(state: state)
            expect(
                content.facts(for: .workBuddy)?.receiptHistory?.state == historyState
                    && content.facts(for: .workBuddy)?.receiptHistory?.entries.map(\.receipt)
                        == receipts,
                "\(historyState) 必须保留读取状态、损坏计数及同次扫描中的有效条目")
            expect(
                content.agents == before.agents && content.matrix == before.matrix,
                "\(historyState) 不得改变任一来源的激活或可听状态")
            expect(
                content.facts(for: .claudeCode)?.receiptHistory == nil
                    && content.facts(for: .codex)?.receiptHistory == nil,
                "WorkBuddy 读取失败不得制造其它来源的 history snapshot")
        }
    }

    suite("集成 destination 双语动作：可见标题只消费 typed action 与状态") {
        let cases: [(HostIntegrationUserAction, HostSourceRowStatus?, String, String)] = [
            (.redetect, .ready, "Redetect", "重新检测"),
            (.copyHooksCommand, .awaitingActivation, "Copy /hooks", "复制 /hooks"),
            (.connect(.workBuddy), .notConnected, "Connect WorkBuddy", "连接 WorkBuddy"),
            (.repair(.workBuddy), .legacy, "Upgrade connection", "升级连接"),
            (
                .repair(.workBuddy), .needsAttention, "Repair WorkBuddy connection",
                "修复 WorkBuddy 连接"
            ),
            (.disconnect(.workBuddy), .ready, "Disconnect WorkBuddy", "断开 WorkBuddy"),
            (
                .clearReceiptHistory(.workBuddy), .ready, "Clear WorkBuddy receipt history",
                "清除 WorkBuddy 回执历史"
            ),
        ]
        for (action, status, english, chinese) in cases {
            expect(
                localizedHostIntegrationUserActionTitle(
                    action, hostStatus: status, language: .english) == english,
                "\(action) English 标题必须来自 localization seam")
            expect(
                localizedHostIntegrationUserActionTitle(
                    action, hostStatus: status, language: .zhHans) == chinese,
                "\(action) zh-Hans 标题必须来自 localization seam")
        }
    }

    suite("集成 destination 当前动作 projection：目标宿主稳定且 legacy repair 显示升级") {
        let cases: [(HostIntegrationUserAction, HostSourceRowStatus?, HostID, String, Bool)] = [
            (.redetect, .ready, .claudeCode, "重新检测中", false),
            (.connect(.workBuddy), .notConnected, .workBuddy, "连接中", false),
            (.repair(.workBuddy), .needsAttention, .workBuddy, "修复中", false),
            (.repair(.workBuddy), .legacy, .workBuddy, "升级中", true),
            (.disconnect(.codex), .ready, .codex, "断开中", false),
            (.clearReceiptHistory(.workBuddy), .ready, .workBuddy, "清除回执历史中", false),
        ]
        for (action, status, host, text, isUpgrade) in cases {
            let operation = integrationDestinationInFlightPresentation(
                action: action,
                selectedHost: .claudeCode,
                hostStatus: status)
            expect(operation?.host == host, "\(action) 必须归属真实 action.host")
            expect(operation?.statusText == text, "\(action) 必须显示 \(text)")
            expect(operation?.isUpgrade == isUpgrade, "legacy repair 的升级事实必须 typed")
            expect(
                operation?.accessibilityLabel.contains(text) == true, "\(action) VoiceOver 必须包含状态")
        }
        expect(
            integrationDestinationInFlightPresentation(
                action: .copyHooksCommand,
                selectedHost: .codex,
                hostStatus: .awaitingActivation) == nil,
            "同步复制动作不得进入异步 in-flight")
    }

    suite("集成 destination feedback：五秒、代次、逐条回执与 Reduce Motion 语义保留") {
        let now = Date(timeIntervalSince1970: 1_000)
        var feedback = IntegrationsFeedbackModel()
        let first = feedback.present(
            host: .codex,
            kind: .information,
            message: "Claudio 已写好，等待 Codex 确认",
            accessibilityAnnouncement: "Codex，4/5，待回执，仅授权请求",
            now: now)
        expect(first == 1, "第一条反馈必须分配首个 revision")
        expect(
            feedback.current?.expiresAt == now.addingTimeInterval(integrationsFeedbackLifetime),
            "反馈生命周期必须固定为五秒")
        expect(
            feedback.activeFeedback(at: now.addingTimeInterval(integrationsFeedbackLifetime))
                == nil,
            "五秒边界必须立即到期")
        expect(
            integrationsFeedbackTransition(reduceMotionEnabled: false) == .opacity
                && integrationsFeedbackTransition(reduceMotionEnabled: true) == .immediate,
            "Reduce Motion 必须取消位移动画")

        var sequence = IntegrationsFeedbackModel()
        let requests = [
            IntegrationsFeedbackRequest(
                host: .claudeCode, kind: .information, message: "Claude receipt"),
            IntegrationsFeedbackRequest(host: .codex, kind: .information, message: "Codex receipt"),
        ]
        let firstRevision = sequence.presentSequence(requests, now: now)
        let firstHost = sequence.current?.host
        sequence.dismiss(revision: firstRevision!, now: now.addingTimeInterval(1))
        expect(firstHost == .claudeCode && sequence.current?.host == .codex, "回执反馈必须逐条推进")
        expect(sequence.current?.revision != firstRevision, "每条回执必须拥有独立 revision")
        var announcer = IntegrationsFeedbackAnnouncementModel()
        let sentence = announcer.consume(sequence.current)
        expect(sentence == "Codex，Codex receipt", "新 revision 必须产生一次完整播报")
        expect(announcer.consume(sequence.current) == nil, "同一 revision 不得重复播报")
        expect(announcer.consume(nil) == nil, "nil 不得重置播报去重")
    }
}
