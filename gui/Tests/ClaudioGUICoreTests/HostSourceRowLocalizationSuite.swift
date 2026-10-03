import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private let hostSourceRowLocalizationInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000B7")!

private func hostSourceRowLocalizationSnapshot(
    _ host: HostID,
    configuration: HostConfigurationState = .configured,
    activation: HostActivationEvidence = .none
) -> HostIntegrationSnapshot {
    HostIntegrationSnapshot(
        host: host,
        runtime: .ready,
        availability: .available,
        configuration: configuration,
        writability: .writable,
        activation: activation)
}

private func hostSourceRowLocalizationMatrix(
    snapshots: [HostIntegrationSnapshot]
) -> AudibilityMatrix {
    AudibilityMatrix.make(
        snapshots: snapshots,
        capabilities: Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, HostCapabilityCatalog.bindings(for: $0))
            }),
        soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
        enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
}

private func hostSourceRowLocalizationRow(
    host: HostID,
    snapshots: [HostIntegrationSnapshot]
) -> HostSourceRowPresentation? {
    hostSourceRowPresentations(from: hostSourceRowLocalizationMatrix(snapshots: snapshots))
        .first(where: { $0.host == host })
}

@MainActor
func runHostSourceRowLocalizationSuites() {
    suite("声音来源行：emitter 只产出类型化详情事实，不再预渲染文字") {
        let readyCodex = hostSourceRowLocalizationSnapshot(
            .codex,
            activation: .observed(
                HostReceiptEvidence(
                    bindingID: HostCapabilityCatalog.bindings(for: .codex)
                        .first(where: \.isAudibleCapability)!.id,
                    installationID: hostSourceRowLocalizationInstallationID,
                    nativeEvent: "Stop",
                    event: .stop,
                    timestamp: Date(timeIntervalSince1970: 100),
                    playbackResult: .played)))
        expect(
            hostSourceRowLocalizationRow(host: .codex, snapshots: [readyCodex])?.detail
                == .codexInterruptionEventUnavailable,
            "Codex ready 必须投影为类型化执行中断事实")
        expect(
            hostSourceRowLocalizationRow(
                host: .workBuddy,
                snapshots: [hostSourceRowLocalizationSnapshot(.workBuddy)])?.detail
                == .workBuddyAwaitingFirstPrompt,
            "WorkBuddy 待激活必须投影为类型化提示词事实")
        expect(
            hostSourceRowLocalizationRow(
                host: .claudeCode,
                snapshots: [hostSourceRowLocalizationSnapshot(.claudeCode)])?.detail
                == .claudeCodeAwaitingFirstPrompt,
            "Claude Code 待激活必须投影为类型化提示词事实")
        expect(
            hostSourceRowLocalizationRow(
                host: .codex,
                snapshots: [hostSourceRowLocalizationSnapshot(.codex)])?.detail
                == .codexAwaitingHooksConfirmation,
            "Codex 待激活必须投影为类型化 /hooks 事实")
        expect(
            hostSourceRowLocalizationRow(
                host: .claudeCode,
                snapshots: [
                    hostSourceRowLocalizationSnapshot(
                        .claudeCode, configuration: .legacyConnected)
                ])?.detail == .claudeCodeLegacyPartialHooks,
            "Claude Code 旧版连接必须投影为类型化部分 hook 事实")
        expect(
            hostSourceRowLocalizationRow(
                host: .workBuddy,
                snapshots: [
                    hostSourceRowLocalizationSnapshot(
                        .workBuddy, configuration: .legacyConnected)
                ])?.detail == .legacyAudibleWithoutReceipt,
            "WorkBuddy 旧版连接必须投影为类型化无回执事实")
        let attention = hostSourceRowLocalizationRow(
            host: .codex,
            snapshots: [
                HostIntegrationSnapshot(
                    host: .codex,
                    runtime: .ready,
                    availability: .unavailable(reason: "无法读取 Codex 配置目录"),
                    configuration: .configured,
                    writability: .writable,
                    activation: .none)
            ])
        expect(
            attention?.detail == .needsAttention(reason: "无法读取 Codex 配置目录")
                && attention?.status == .needsAttention,
            "needsAttention 必须逐字携带 adapter 诊断")
        let notConnected = hostSourceRowLocalizationRow(host: .codex, snapshots: [])
        expect(
            notConnected?.detail == nil && notConnected?.status == .notConnected
                && notConnected?.supportedCount == 4
                && notConnected?.totalCount == Event.allCases.count,
            "未连接行无详情但必须保留类型化计数")
    }

    suite("声音来源行 localized seam：类型化详情枚举双语精确渲染") {
        let expectedDetails: [(HostSourceRowDetail, String, String)] = [
            (.codexInterruptionEventUnavailable, "执行中断暂无事件", "Execution interruption has no event"),
            (
                .workBuddyNotificationScopeOnly, "通知仅覆盖授权与空闲提醒；执行中断尚未实现",
                "Notifications cover permission and idle prompts only; interruption is not implemented"
            ),
            (
                .claudeCodeAwaitingFirstPrompt, "请向 Claude Code 提交一次提示词以确认连接",
                "Submit a prompt to Claude Code to confirm the connection"
            ),
            (
                .codexAwaitingHooksConfirmation, "在 Codex 输入 /hooks，确认后再提交一次提示词",
                "Enter /hooks in Codex, confirm it, then submit another prompt"
            ),
            (
                .workBuddyAwaitingFirstPrompt, "请向 WorkBuddy 提交一次提示词以确认连接",
                "Submit a prompt to WorkBuddy to confirm the connection"
            ),
            (
                .claudeCodeLegacyPartialHooks,
                "四个旧版 hook 已接入；Notification 仍可播放；PreToolUse 提问入口和任务开始未安装，请升级连接",
                "Four legacy hooks remain installed; Notification can still play; the PreToolUse question hook and task start are not installed, so upgrade the connection"
            ),
            (.legacyAudibleWithoutReceipt, "可听，但暂无真实回执", "Audible, but no real receipt yet"),
        ]
        for (detail, chinese, english) in expectedDetails {
            expect(
                localizedHostSourceRowDetail(detail, language: .zhHans) == chinese
                    && localizedHostSourceRowDetail(detail, language: .english) == english,
                "\(detail) 必须在唯一 seam 双语精确渲染")
        }
        let reason = "缺少 hook：Stop"
        expect(
            localizedHostSourceRowDetail(.needsAttention(reason: reason), language: .zhHans)
                == reason
                && localizedHostSourceRowDetail(
                    .needsAttention(reason: reason), language: .english) == reason,
            "adapter 诊断原文两种语言都必须逐字保留")
        expect(
            localizedHostSourceRowDetail(nil, language: .zhHans) == nil
                && localizedHostSourceRowDetail(nil, language: .english) == nil,
            "无详情事实不得凭空生成文字")
    }

    suite("声音来源行 localized seam：五态 readiness 双语渲染与 placeholder 同构") {
        let expectedReadiness: [(HostSourceRowStatus, String, String)] = [
            (.ready, "4/5 已就绪", "4/5 ready"),
            (.awaitingActivation, "4/5 已配置", "4/5 configured"),
            (.legacy, "4/5 旧版连接", "4/5 legacy connection"),
            (.notConnected, "4/5 未连接", "4/5 not connected"),
            (.needsAttention, "4/5 需要处理", "4/5 needs attention"),
        ]
        for (status, chinese, english) in expectedReadiness {
            let row = HostSourceRowPresentation(
                host: .codex,
                title: "Codex",
                status: status,
                detail: status == .needsAttention ? .needsAttention(reason: "诊断") : nil,
                supportedCount: 4,
                totalCount: 5)
            let chineseRow = localizedHostSourceRow(row, language: .zhHans)
            let englishRow = localizedHostSourceRow(row, language: .english)
            expect(
                chineseRow.readinessText == chinese && englishRow.readinessText == english,
                "\(status) 双语 readiness 必须由 catalog 渲染")
            expect(
                !chineseRow.readinessText.contains("%")
                    && !englishRow.readinessText.contains("%"),
                "\(status) 双语 placeholder 必须同构替换，不得残留格式占位符")
            expect(
                chineseRow.accessibilityLabel.contains(chinese)
                    && englishRow.accessibilityLabel.contains(english),
                "\(status) VoiceOver 必须消费同一 localized 投影")
            expect(
                row.coverageText == "4/5" && chineseRow.coverageText == "4/5"
                    && englishRow.coverageText == "4/5",
                "\(status) 覆盖事实必须保持语言中立")
        }
    }

    suite("声音来源行：端到端类型化事实经唯一 seam 双语渲染") {
        let readyCodex = hostSourceRowLocalizationSnapshot(
            .codex,
            activation: .observed(
                HostReceiptEvidence(
                    bindingID: HostCapabilityCatalog.bindings(for: .codex)
                        .first(where: \.isAudibleCapability)!.id,
                    installationID: hostSourceRowLocalizationInstallationID,
                    nativeEvent: "Stop",
                    event: .stop,
                    timestamp: Date(timeIntervalSince1970: 100),
                    playbackResult: .played)))
        guard let row = hostSourceRowLocalizationRow(host: .codex, snapshots: [readyCodex])
        else {
            expect(false, "Codex ready 行必须存在")
            return
        }
        let chinese = localizedHostSourceRow(row, language: .zhHans)
        let english = localizedHostSourceRow(row, language: .english)
        expect(
            chinese.detailText == "执行中断暂无事件"
                && english.detailText == "Execution interruption has no event",
            "ready Codex 详情必须经唯一 seam 双语渲染")
        expect(
            chinese.accessibilityLabel.contains("执行中断暂无事件")
                && english.accessibilityLabel.contains("Execution interruption has no event"),
            "VoiceOver 不得绕过 localized 投影读取行文字")
    }
}
