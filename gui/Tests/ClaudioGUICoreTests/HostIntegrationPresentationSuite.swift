import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private let hostPresentationInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000A1")!

private func hostPresentationSnapshot(
    _ host: HostID,
    activation: HostActivationEvidence? = nil
) -> HostIntegrationSnapshot {
    guard
        let binding = HostCapabilityCatalog.bindings(for: host).first(where: \.isAudibleCapability)
    else {
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .unavailable(reason: "Beta candidate unavailable"),
            configuration: .notConfigured,
            writability: .unknown,
            activation: .none)
    }
    let evidence = HostReceiptEvidence(
        bindingID: binding.id,
        installationID: hostPresentationInstallationID,
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        timestamp: Date(timeIntervalSince1970: 100.123),
        playbackResult: .played)
    let resolvedActivation = activation ?? .observed(evidence)
    let latestReceipt: HostReceiptEvidence?
    if case .observed(let observed) = resolvedActivation {
        latestReceipt = observed
    } else {
        latestReceipt = nil
    }
    return HostIntegrationSnapshot(
        host: host,
        runtime: .ready,
        availability: .available,
        configuration: .configured,
        writability: .writable,
        activation: resolvedActivation,
        bindingActivations: activation == nil
            ? Dictionary(
                uniqueKeysWithValues: HostCapabilityCatalog.bindings(for: host)
                    .filter(\.isAudibleCapability).map {
                        (
                            $0.id,
                            .observed(
                                HostReceiptEvidence(
                                    bindingID: $0.id,
                                    installationID: hostPresentationInstallationID,
                                    nativeEvent: $0.nativeEvent!, event: $0.event,
                                    timestamp: evidence.timestamp, playbackResult: .played))
                        )
                    }) : [:],
        latestReceipt: latestReceipt,
        installationID: hostPresentationInstallationID)
}

private func hostPresentationMatrix(
    snapshots: [HostIntegrationSnapshot]? = nil,
    capabilities: [HostID: [HostCapabilityBinding]]? = nil
) -> AudibilityMatrix {
    AudibilityMatrix.make(
        snapshots: snapshots ?? HostID.productVisibleCases.map { hostPresentationSnapshot($0) },
        capabilities: capabilities
            ?? Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map {
                    ($0, HostCapabilityCatalog.bindings(for: $0))
                }),
        soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
        enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
}

@MainActor
func runHostIntegrationPresentationSuites() {
    suite("宿主事件文案：五个 UI 名称统一为声音语义，不泄漏原生事件名") {
        expect(
            Event.allCases.map(\.displayName)
                == ["用户发起", "响应结束", "执行中断", "等待介入", "子任务结束"],
            "Event displayName 必须保持产品声音语义顺序")
        let codex = localizedCapabilityCell(
            HostCapabilityCellPresentation(
                host: .codex,
                event: .notification,
                state: .awaitingActivation,
                qualificationText: "仅授权请求"),
            language: .english)
        expect(
            codex.qualificationText == "Authorization request only"
                && !codex.accessibilityLabel.contains("PermissionRequest"),
            "原生事件 key 不得泄漏到能力 label")
    }

    suite("宿主来源共享 presentation：产品 registry 永久出现，AX identity 只留在诊断层") {
        let rows = hostSourceRowPresentations(from: hostPresentationMatrix())
        expect(rows.map(\.host) == [.codex, .claudeCode, .workBuddy], "共享来源仍保持 Product 分组顺序")
        expect(
            rows.map(\.supportedCount) == [4, 5, 4]
                && rows.allSatisfy { $0.totalCount == Event.allCases.count },
            "能力数量必须来自 adapter/catalog 事实")
        expect(
            hostSourceRowPresentations(
                from: hostPresentationMatrix(
                    snapshots: [hostPresentationSnapshot(.claudeCode)])
            )
            .map(\.host) == [.codex, .claudeCode, .workBuddy],
            "缺少快照也不能隐藏其他产品宿主")
        expect(
            Set(rows.map(\.host)).isDisjoint(with: [.chatGPTDesktopAX, .claudeDesktopAX]),
            "AX-only identity 不得进入普通来源行")
    }

    suite("共享能力矩阵：严格由五个语义行和产品宿主单元组成，缺失映射保持 fail closed") {
        let matrix = hostCapabilityMatrixPresentation(from: hostPresentationMatrix())
        expect(matrix.rows.map(\.event) == Event.allCases, "矩阵必须保持五个事件语义行")
        expect(matrix.hostColumns == hostSurfacePresentationOrder(), "矩阵列继续消费共享 Product 顺序")
        let codexStopFailure = matrix.cell(host: .codex, event: .stopFailure)
        expect(
            codexStopFailure?.state == .unsupported
                && codexStopFailure?.nativeEventText == nil,
            "Codex 未声明的 stop_failure 不得由 UI 硬编码补回")
        let noCodexMapping = hostPresentationMatrix(
            capabilities: [
                .claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode),
                .codex: HostCapabilityCatalog.bindings(for: .codex).filter {
                    $0.event != .stop
                },
                .workBuddy: HostCapabilityCatalog.bindings(for: .workBuddy),
            ])
        expect(
            hostCapabilityMatrixPresentation(from: noCodexMapping)
                .cell(host: .codex, event: .stop)?.state == .unsupported,
            "删除 adapter 映射必须暴露 unsupported，而非补写声音能力")
    }

    suite("旧版 Claude 任务开始与通知：共享矩阵和面板详情保留逐绑定事实") {
        let legacy = HostIntegrationSnapshot(
            host: .claudeCode,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .writable,
            activation: .none)
        let matrix = hostPresentationMatrix(snapshots: [legacy])
        let presentation = hostCapabilityMatrixPresentation(from: matrix)
        guard let taskStart = presentation.cell(host: .claudeCode, event: .taskStart) else {
            expect(false, "旧版 Claude 必须保留 task_start 格")
            return
        }
        let taskStartEnglish = localizedCapabilityCell(taskStart, language: .english)
        let missingEventEnglish =
            "This event is not installed by the legacy connection; "
            + "upgrade the connection"
        expect(
            taskStartEnglish.detailText == missingEventEnglish
                && taskStartEnglish.accessibilityLabel.contains(missingEventEnglish),
            "英文能力矩阵与 VoiceOver 须翻译旧版未安装的任务开始事件")
        let taskStartIndicator = eventHostIndicatorPresentations(
            event: .taskStart, matrix: presentation
        ).first(where: { $0.host == .claudeCode })
        if let taskStartIndicator {
            let english = localizedEventHostIndicator(taskStartIndicator, language: .english)
            let chinese = localizedEventHostIndicator(taskStartIndicator, language: .zhHans)
            expect(
                english.detailText == missingEventEnglish
                    && english.helpText.contains(missingEventEnglish)
                    && english.accessibilityLabel.contains(missingEventEnglish)
                    && chinese.detailText == "旧版连接未安装此事件，请升级连接",
                "英文面板详情须翻译并进入帮助与 VoiceOver；中文原文保持不变")
        } else {
            expect(false, "旧版 Claude task_start 须有面板宿主指示器")
        }
        guard let cell = presentation.cell(host: .claudeCode, event: .notification) else {
            expect(false, "旧版 Claude 必须保留 notification 格")
            return
        }
        let english = localizedCapabilityCell(cell, language: .english)
        expect(
            english.detailText
                == "Notification: audible through the legacy hook without a current receipt; PreToolUse question hook: not installed by the legacy connection, upgrade the connection",
            "英文矩阵详情必须分别说明仍可听的旧通知和未安装的提问绑定")
        expect(
            english.accessibilityLabel.contains("Notification: audible")
                && english.accessibilityLabel.contains("PreToolUse question hook: not installed")
                && !english.accessibilityLabel.contains("inaudible"),
            "英文无障碍文案不得抹掉旧通知可听的事实")
        let indicator = eventHostIndicatorPresentations(
            event: .notification,
            matrix: hostCapabilityMatrixPresentation(from: matrix)
        ).first(where: { $0.host == .claudeCode })
        expect(
            indicator?.state == .legacy
                && indicator?.state.usesActiveColor == true
                && indicator?.detailText?.contains("Notification：旧版可听") == true
                && indicator?.detailText?.contains("PreToolUse 提问入口：旧版未安装") == true
                && indicator?.helpText.contains("Notification：旧版可听") == true
                && indicator?.accessibilityLabel.contains("PreToolUse 提问入口：旧版未安装")
                    == true,
            "面板 Claude 标签须保持旧版可听颜色，并说明新增提问入口待升级")
        if let indicator {
            let localized = localizedEventHostIndicator(indicator, language: .english)
            let upgradeText = "PreToolUse question hook: not installed"
            expect(
                localized.detailText?.contains("Notification: audible") == true
                    && localized.detailText?.contains(upgradeText) == true
                    && localized.helpText.contains("Notification: audible")
                    && localized.accessibilityLabel.contains("Notification: audible")
                    && localized.accessibilityLabel.contains(upgradeText),
                "面板英文帮助与 VoiceOver 须同时保留旧绑定可听和新绑定待升级")
        }
        guard
            let row = hostSourceRowPresentations(from: matrix)
                .first(where: { $0.host == .claudeCode })
        else {
            expect(false, "集成页必须保留 Claude Code 来源行")
            return
        }
        expect(
            row.detailText?.contains("Notification 仍可播放") == true
                && row.detailText?.contains("PreToolUse 提问入口") == true
                && row.detailText?.contains("请升级连接") == true,
            "集成页旧版连接说明必须同时交代旧通知与新增提问入口")
        let englishRow = localizedHostSourceRow(row, language: .english)
        expect(
            englishRow.detailText?.contains("Notification can still play") == true
                && englishRow.detailText?.contains("PreToolUse question hook") == true,
            "集成页英文说明必须保留逐绑定事实")
    }

    suite("工作区通知静音：面板旧版绑定详情不借用默认组可听状态") {
        let legacy = HostIntegrationSnapshot(
            host: .claudeCode,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .writable,
            activation: .none)
        let content = integrationDestinationContent(
            state: HostIntegrationPresentationState(
                snapshots: [legacy],
                matrix: hostPresentationMatrix(snapshots: [legacy])))
        let workspaceRow = panelEventPresentations(
            rows: [
                EventRow(
                    event: .notification,
                    coverage: .present(fileName: "notification.aiff"),
                    enabled: false)
            ],
            scope: .workspace(UUID()),
            masterVolume: 0.8,
            language: .english
        ).first(where: { $0.event == .notification })
        let indicator = localizedPanelEventHostIndicators(
            event: .notification, content: content, language: .english
        ).first(where: { $0.host == .claudeCode })
        let bindingDetail =
            "Notification: legacy hook installed without a current receipt; PreToolUse question hook: "
            + "not installed by the legacy connection, upgrade the connection"
        expect(workspaceRow?.enabled == false, "工作区事件行必须使用自己的静音配置")
        expect(
            indicator?.state == .legacy
                && indicator?.detailText == bindingDetail
                && indicator?.helpText.contains(bindingDetail) == true
                && indicator?.accessibilityLabel.contains(bindingDetail) == true,
            "面板旧版详情只说明安装事实，帮助与 VoiceOver 不借用默认组可听状态")
        expect(
            indicator?.detailText?.contains("audible") == false,
            "默认组通知可听时，工作区静音行不得宣称旧版可听")
        let chinese = localizedPanelEventHostIndicators(
            event: .notification, content: content, language: .zhHans
        ).first(where: { $0.host == .claudeCode })
        expect(
            chinese?.detailText
                == "Notification：旧版 hook 已安装，无当前回执；PreToolUse 提问入口：旧版未安装，请升级连接"
                && chinese?.accessibilityLabel.contains("旧版可听") == false,
            "中文可见详情与 VoiceOver 也须只陈述绑定安装事实")

        let defaultMutedMatrix = AudibilityMatrix.make(
            snapshots: [legacy],
            capabilities: [.claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode)],
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, false) }))
        let defaultMutedContent = integrationDestinationContent(
            state: HostIntegrationPresentationState(
                snapshots: [legacy], matrix: defaultMutedMatrix))
        let workspaceEnabled = panelEventPresentations(
            rows: [
                EventRow(
                    event: .notification,
                    coverage: .present(fileName: "notification.aiff"),
                    enabled: true)
            ],
            scope: .workspace(UUID()),
            masterVolume: 0.8,
            language: .english
        ).first(where: { $0.event == .notification })
        let oppositeIndicator = localizedPanelEventHostIndicators(
            event: .notification, content: defaultMutedContent, language: .english
        ).first(where: { $0.host == .claudeCode })
        expect(
            workspaceEnabled?.enabled == true
                && oppositeIndicator?.state == .legacy
                && oppositeIndicator?.detailText == bindingDetail,
            "默认组静音而工作区开启时，面板也不得借用默认组的静音诊断")

        let readOnlyLegacy = HostIntegrationSnapshot(
            host: .claudeCode,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .notWritable(reason: "配置只读"),
            activation: .none)
        let readOnlyContent = integrationDestinationContent(
            state: HostIntegrationPresentationState(
                snapshots: [readOnlyLegacy],
                matrix: hostPresentationMatrix(snapshots: [readOnlyLegacy])))
        let readOnlyCell = readOnlyContent.matrix.rows.first(where: { $0.event == .notification })?
            .cells.first(where: { $0.host == .claudeCode })
        let readOnlyIndicator = localizedPanelEventHostIndicators(
            event: .notification, content: readOnlyContent, language: .english
        ).first(where: { $0.host == .claudeCode })
        expect(
            readOnlyContent.sourceRows.first(where: { $0.host == .claudeCode })?.status
                == .needsAttention
                && readOnlyCell?.detailText?.contains("旧版可听") == true,
            "只读旧版连接的来源汇总会遮住 legacy 状态，但矩阵仍带默认组声音详情")
        expect(
            workspaceRow?.enabled == false
                && readOnlyIndicator?.state == .legacy
                && readOnlyIndicator?.detailText == bindingDetail
                && readOnlyIndicator?.accessibilityLabel.contains("旧版可听") == false,
            "只读旧版连接也不得在静音工作区的面板与 VoiceOver 泄漏默认组可听状态")
    }

    suite("旧版事件状态：面板可见文字与 VoiceOver 不显示来源计数占位符") {
        for (language, expected) in [
            (ClaudioAppLanguage.english, "Legacy connection"),
            (.zhHans, "旧版连接"),
        ] {
            let status = localizedEventHostIndicatorStatus(.legacy, language: language)
            expect(status == expected, "旧版事件状态须使用无需计数的双语文案")
            expect(!status.contains("%lld"), "面板详情与 VoiceOver 不得读出计数占位符")
        }
    }

    suite("Accessibility Beta qualification：能力格和事件指示器共享双语限定语") {
        let source = "Accessibility Beta 候选尚未实现"
        let cell = HostCapabilityCellPresentation(
            host: .chatGPTDesktopAX,
            event: .taskStart,
            state: .unsupported,
            qualificationText: source)
        let indicator = EventHostIndicatorPresentation(
            host: .chatGPTDesktopAX,
            state: .unsupported,
            qualificationText: source)
        expect(
            localizedCapabilityCell(cell, language: .english).qualificationText
                == "Accessibility Beta candidate is not implemented"
                && localizedEventHostIndicator(indicator, language: .english).qualificationText
                    == "Accessibility Beta candidate is not implemented",
            "AX unavailable 文案必须在共享 localization seam 中保持一致")
    }

    suite("真实回执 presentation：只显示宿主、事件、时间与脱敏结果") {
        let observed = hostPresentationSnapshot(.claudeCode)
        let text = hostLatestReceiptText(snapshot: observed)
        expect(
            hostLatestReceiptEvidence(snapshot: observed)?.event == .taskStart
                && text?.contains("Claude Code · 用户发起") == true,
            "observed receipt 必须保留结构化宿主与声音语义")
        expect(
            text?.contains("UserPromptSubmit") == false
                && text?.contains(hostPresentationInstallationID.uuidString) == false
                && text?.contains("/") == false,
            "回执摘要不得泄漏原生 key、installation ID 或绝对路径")
        let awaiting = hostPresentationSnapshot(
            .codex,
            activation: .awaitingReceipt(installationID: hostPresentationInstallationID))
        expect(
            hostLatestReceiptText(snapshot: awaiting) == nil
                && hostLatestReceiptEvidence(snapshot: awaiting) == nil,
            "awaiting 状态不能伪造当前安装实例回执")
    }

    suite("回执变化与播放结果：结构化 evidence 区分同毫秒摘要，六种结果均可脱敏显示") {
        let binding = HostCapabilityCatalog.bindings(for: .claudeCode)
            .first(where: \.isAudibleCapability)!
        func snapshot(at interval: TimeInterval, result: HostHookPlaybackResult = .played)
            -> HostIntegrationSnapshot
        {
            let evidence = HostReceiptEvidence(
                installationID: hostPresentationInstallationID,
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                timestamp: Date(timeIntervalSince1970: interval),
                playbackResult: result)
            return HostIntegrationSnapshot(
                host: .claudeCode,
                runtime: .ready,
                availability: .available,
                configuration: .configured,
                writability: .writable,
                activation: .observed(evidence),
                latestReceipt: evidence,
                installationID: hostPresentationInstallationID)
        }
        expect(
            hostLatestReceiptText(snapshot: snapshot(at: 100.1234))
                == hostLatestReceiptText(snapshot: snapshot(at: 100.1235)),
            "测试前提：同毫秒精度下摘要可能相同")
        expect(
            hostLatestReceiptEvidence(snapshot: snapshot(at: 100.1234))
                != hostLatestReceiptEvidence(snapshot: snapshot(at: 100.1235)),
            "变化判断必须消费完整 evidence")
        let expected: [(HostHookPlaybackResult, String)] = [
            (.played, "已播放"), (.muted, "已静音"), (.debounced, "防抖跳过"),
            (.notReady, "声音未就绪"), (.unsupportedEvent, "事件不支持"), (.playbackFailed, "播放失败"),
        ]
        for (result, title) in expected {
            expect(hostHookPlaybackResultDisplayName(result) == title, "\(result) 必须显示 \(title)")
            expect(
                hostLatestReceiptText(snapshot: snapshot(at: 100, result: result))?.hasSuffix(
                    "· \(title)")
                    == true,
                "\(result) 回执摘要必须包含脱敏结果")
        }
    }

    suite("共享反馈模型：右下 toast 的五秒边界、代次保护与 Reduce Motion 不变") {
        let now = Date(timeIntervalSince1970: 2_000)
        var model = IntegrationsFeedbackModel()
        let old = model.present(
            host: .claudeCode,
            kind: .success,
            message: "Claude Code 已连接",
            now: now)
        let new = model.present(
            host: .codex,
            kind: .failure,
            message: "Codex 重新检测失败",
            now: now)
        model.dismiss(revision: old, now: now)
        expect(model.current?.revision == new, "旧 toast 的关闭事件不得误关新 toast")
        expect(
            model.current?.expiresAt == now.addingTimeInterval(integrationsFeedbackLifetime),
            "toast 生命周期必须为五秒")
        expect(
            integrationsFeedbackTransition(reduceMotionEnabled: false) == .opacity
                && integrationsFeedbackTransition(reduceMotionEnabled: true) == .immediate,
            "Reduce Motion 开启时必须立即更新")
        var announcer = IntegrationsFeedbackAnnouncementModel()
        expect(announcer.consume(model.current) != nil, "新代次必须可播报")
        expect(
            announcer.consume(model.current) == nil && announcer.consume(nil) == nil, "去重不可被 nil 重置"
        )
    }
}
