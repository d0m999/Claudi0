import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runAdditionalHostPresentationSuites() {
    suite("Grok Build：命令行末行、4/5 公共覆盖与六条独立能力事实") {
        let content = integrationDestinationTestContent()
        let facts = content.facts(for: .grokBuild)!
        expect(content.agents.last?.host == .grokBuild, "新增命令行放在末尾")
        expect(integrationToolKind(for: .grokBuild) == .cli, "归属命令行工具")
        expect(
            facts.mechanism == .nativeHooks && facts.row.coverageText == "4/5", "五条 binding 覆盖四类事件"
        )
        expect(
            facts.capabilityReceipts.count == 6 && facts.bindingReceipts.count == 5,
            "支持、实现和当前回执独立呈现")
        let awaiting = integrationDestinationContent(
            state: integrationDestinationTestState(statuses: [.grokBuild: .awaitingActivation]))
        expect(
            awaiting.facts(for: .grokBuild)?.row.detail == .grokBuildAwaitingSupportedEvent,
            "不把普通用户提交当作 Grok 激活证据")
        for event in [Event.taskStart, .stop] {
            let binding = facts.capabilityReceipts.first { $0.binding.event == event }
            expect(binding?.binding.implementation == .implemented, "开始／结束已实现")
        }
        let subagent = facts.capabilityReceipts.first { $0.binding.event == .subagentStop }
        expect(
            subagent?.binding.implementation == .notImplemented
                && subagent?.activation == HostActivationEvidence.none, "子任务结束仍未实现")
        for language in [ClaudioAppLanguage.english, .zhHans] {
            expect(
                localizedHostSourceRowDetail(.grokBuildReliableEventsOnly, language: language)?
                    .isEmpty == false, "可靠事件边界双语齐全")
        }
        for key: ClaudioL10nKey in [
            .hostGrokBuildReadyDetail, .hostGrokBuildAwaitingDetail,
            .qualificationPromptOriginUnavailable,
            .qualificationCompletionGateOnly, .qualificationMainSessionAPIErrorOnly,
        ] {
            expect(ClaudioL10nKey.allKnown.contains(key), "文案登记 allKnown")
            for language in [ClaudioAppLanguage.english, .zhHans] {
                expect(ClaudioL10n(language: language).text(key) != key.rawValue, "双语不回退 key")
            }
        }
    }

    suite("Grok Build：授权需要你，提问意图只瞬时展示，错误保留中断提醒") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let installation = UUID()
        let permission = attentionNotice(
            epoch: model.receiverEpoch, installation: installation,
            native: "Notification", host: .grokBuild, reason: .permission)
        expect(model.accept(permission) == .accepted, "Grok 原生授权投影可接收")
        expect(model.snapshot.attentionReminders.first?.kind == .permission, "授权等待保留需要你")
        let version = model.snapshot.attentionReminders.first?.version
        model.dismiss(animated: false)
        let question = attentionNotice(
            epoch: model.receiverEpoch, installation: installation,
            native: "PreToolUse", host: .grokBuild, reason: .questionIntent)
        expect(model.accept(question) == .accepted, "精确提问绑定可展示")
        expect(
            model.snapshot.current?.kind == .transient
                && model.snapshot.attentionReminders.count == 1,
            "提问不能创建待接手提醒")
        expect(model.snapshot.attentionReminders.first?.version == version, "提问不修改授权提醒版本")
        expect(
            EventNoticeProjection.primaryLine(for: model.snapshot.current!, language: .zhHans)
                .contains("即将向你提问"), "提问标题明确限定意图")
        model.dismiss(animated: false)
        let error = attentionNotice(
            epoch: model.receiverEpoch, installation: installation,
            native: "StopFailure", host: .grokBuild, reason: nil)
        expect(model.accept(error) == .accepted, "主会话 API 错误可接收")
        expect(model.snapshot.attentionReminders.contains { $0.kind == .interrupted }, "错误形成中断提醒")
    }

    suite("Grok Build：沿用可信终端导航；仅打开应用时保留提醒") {
        let clock = ManualEventNoticeScheduler()
        let process = HostProcessIdentity(pid: 12, startSeconds: 100, startMicroseconds: 0)
        let application = HostProcessIdentity(pid: 13, startSeconds: 100, startMicroseconds: 0)
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action, process: application,
                    bundleIdentifier: "com.apple.Terminal",
                    applicationURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
                    name: "Terminal")
            })
        let base = attentionNotice(
            epoch: model.receiverEpoch, native: "Notification", host: .grokBuild,
            reason: .permission, processAncestors: [process, application])
        let notice = base.replacingNavigationEvidence(
            HostNavigationEvidence(process: process, terminalProcess: process, tty: "/dev/ttys001"),
            ancestors: [process, application])
        expect(model.accept(notice) == .accepted, "可信终端证据进入既有模型")
        let action = model.snapshot.current!.action!
        expect(
            model.navigationTarget(for: action)?.route == .terminal(tty: "/dev/ttys001"),
            "复用终端目标解析器")
        let coordinator = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(),
            navigateHost: { _, _, _, _, complete in
                complete(.unavailable); return EventNoticeCancellation {}
            },
            openApplication: { _, _, complete in
                complete(.opened); return EventNoticeCancellation {}
            })
        coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
        expect(
            coordinator.result == .applicationFallback && model.snapshot.totalCount == 1,
            "应用切换不代表精确返回，不删除提醒")
    }

    suite("新增来源呈现：接入机制、公共覆盖与实际绑定分别读取共享快照") {
        let content = integrationDestinationTestContent()
        for host in [HostID.opencode, .kimiCode] {
            guard let facts = content.facts(for: host), let agent = content.agent(for: host) else {
                expect(false, "验收候选必须有独立来源行")
                continue
            }
            expect(
                agent.title == host.displayName && agent.status == .ready,
                "来源产品名与状态来自 typed facts")
            expect(
                facts.mechanism == (host == .opencode ? .pluginBridge : .nativeHooks),
                "OpenCode 插件桥接不冒充原生 hooks")
            expect(
                facts.row.coverageText == (host == .opencode ? "5/5" : "4/5"),
                "多条 notification 绑定不重复计算公共事件覆盖")
            expect(facts.capabilityReceipts.count == 6, "保留每条独立 binding 的支持和回执")
            for event in Event.allCases {
                let cell = content.matrix.cell(host: host, event: event)
                let localized = cell.map { localizedCapabilityCell($0, language: .english) }
                expect(localized?.accessibilityLabel.isEmpty == false, "每格具有对应的英文无障碍文案")
            }
        }
        let kimiStop = content.facts(for: .kimiCode)?.capabilityReceipts.first {
            $0.binding.event == .stop
        }
        let kimiStopObserved: Bool = {
            if case .observed = kimiStop?.activation { return true }
            return false
        }()
        expect(
            kimiStop?.binding.implementation == .implemented
                && kimiStop?.binding.qualification == .transcriptMainTurnOnly
                && kimiStopObserved,
            "Kimi Stop 通过主 agent 落盘轨迹启用，ready fixture 保留 observed 回执")
        let kimiStopFailure = content.facts(for: .kimiCode)?.capabilityReceipts.first {
            $0.binding.event == .stopFailure
        }
        expect(
            kimiStopFailure?.binding.implementation == .notImplemented
                && kimiStopFailure?.activation == HostActivationEvidence.none,
            "Kimi StopFailure 仍无主／子失败身份，尚未实现")
        expect(hostIntegrationMechanismDisplayName(.pluginBridge) == "Claudio 插件桥接", "机制文案独立存在")
        expect(
            content.facts(for: .opencode)?.capabilityReceipts.first {
                $0.binding.event == .taskStart
            }?.binding.qualification == .bridgeExecutionEvidenceOnly,
            "开始事件需要实际执行证据，不得声称等待终态")
    }

    suite("Kimi Stop：主轮轨迹限定语在能力格、指示器与逐绑定说明中双语一致") {
        let content = integrationDestinationTestContent()
        guard let cell = content.matrix.cell(host: .kimiCode, event: .stop),
            let indicator = eventHostIndicatorPresentations(event: .stop, matrix: content.matrix)
                .first(where: { $0.host == .kimiCode }),
            let binding = content.facts(for: .kimiCode)?.capabilityReceipts.first(where: {
                $0.binding.event == .stop
            })
        else {
            expect(false, "Kimi Stop 的三处公开呈现都必须存在")
            return
        }
        let key = ClaudioL10nKey(rawValue: "qualification.transcript-main-turn-only")
        expect(ClaudioL10nKey.allKnown.contains(key), "主轮轨迹限定语必须注册 allKnown")
        for (language, expected) in [
            (ClaudioAppLanguage.zhHans, "按主 agent 落盘轨迹判断；仅主轮结束提醒"),
            (
                ClaudioAppLanguage.english,
                "Uses the main agent’s persisted transcript; alerts only when the main turn ends"
            ),
        ] {
            expect(ClaudioL10n(language: language).text(key) == expected, "限定语双语目录文案准确")
            let localizedCell = localizedCapabilityCell(cell, language: language)
            expect(localizedCell.qualificationText == expected, "能力格保留主轮限定语")
            expect(localizedCell.accessibilityLabel.contains(expected), "能力格无障碍文本使用同一限定语")
            let localizedIndicator = localizedEventHostIndicator(indicator, language: language)
            expect(localizedIndicator.qualificationText == expected, "事件指示器保留主轮限定语")
            expect(
                localizedIndicator.accessibilityLabel.contains(expected),
                "事件指示器无障碍文本使用同一限定语")
            expect(binding.capabilityText(language: language).contains(expected), "逐绑定说明保留主轮限定语")
        }
    }

    suite("新增来源呈现：配置完成不制造回执，双语说明可靠事件边界") {
        let state = integrationDestinationTestState(statuses: [
            .opencode: .awaitingActivation,
            .kimiCode: .awaitingActivation,
        ])
        let content = integrationDestinationContent(state: state)
        for host in [HostID.opencode, .kimiCode] {
            guard let facts = content.facts(for: host) else { expect(false, "独立快照"); continue }
            expect(
                facts.row.status == .awaitingActivation
                    && facts.row.detail == .additionalHostAwaitingFirstTurn,
                "安装完成仅展示待回执")
            expect(
                facts.bindingReceipts.allSatisfy {
                    if case .awaitingReceipt = $0.activation { return true }
                    return false
                }, "各绑定逐条等待真实 callback")
            for language in [ClaudioAppLanguage.english, .zhHans] {
                let localized = localizedHostSourceRow(facts.row, language: language)
                expect(localized.detailText?.isEmpty == false, "待回执详情两种语言齐全")
                let detail = localizedHostSourceRowDetail(
                    host == .opencode
                        ? .opencodeReliableEventsOnly : .kimiCodeReliableEventsOnly,
                    language: language)
                expect(detail?.isEmpty == false, "可靠事件范围两种语言齐全")
            }
        }
        let keys: [ClaudioL10nKey] = [
            .hostOpenCodeReadyDetail, .hostKimiCodeReadyDetail,
            .hostAdditionalAwaitingDetail, .qualificationBridgeTerminalEvidence,
            .qualificationBridgeExecutionEvidence,
            .qualificationUserOriginOnly,
            .qualificationMainAgentUnavailable, .qualificationSubagentUnavailable,
            .integrationsMechanismPluginBridge,
        ]
        for key in keys {
            expect(ClaudioL10nKey.allKnown.contains(key), "新增 key 必须注册")
            for language in [ClaudioAppLanguage.english, .zhHans] {
                expect(
                    ClaudioL10n(language: language).text(key) != key.rawValue,
                    "新增文案不得回退原始 key")
            }
        }
    }
}
