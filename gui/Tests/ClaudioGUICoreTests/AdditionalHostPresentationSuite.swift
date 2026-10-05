import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runAdditionalHostPresentationSuites() {
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
                facts.row.coverageText == (host == .opencode ? "5/5" : "3/5"),
                "多条 notification 绑定不重复计算公共事件覆盖")
            expect(facts.capabilityReceipts.count == 6, "保留每条独立 binding 的支持和回执")
            for event in Event.allCases {
                let cell = content.matrix.cell(host: host, event: event)
                let localized = cell.map { localizedCapabilityCell($0, language: .english) }
                expect(localized?.accessibilityLabel.isEmpty == false, "每格具有对应的英文无障碍文案")
            }
        }
        for event in [Event.stop, .stopFailure] {
            let binding = content.facts(for: .kimiCode)?.capabilityReceipts.first {
                $0.binding.event == event
            }
            expect(
                binding?.binding.implementation == .notImplemented
                    && binding?.activation == HostActivationEvidence.none,
                "Kimi 终态缺少主子身份时保持尚未实现、无激活")
        }
        expect(hostIntegrationMechanismDisplayName(.pluginBridge) == "Claudio 插件桥接", "机制文案独立存在")
        expect(
            content.facts(for: .opencode)?.capabilityReceipts.first {
                $0.binding.event == .taskStart
            }?.binding.qualification == .bridgeExecutionEvidenceOnly,
            "开始事件需要实际执行证据，不得声称等待终态")
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
