import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runQuestionIntentPresentationSuites() {
    func model(_ clock: ManualEventNoticeScheduler) -> EventNoticeModel {
        EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
    }

    suite("提问意图：沿用 notification，仅瞬时展示即将提问和对应无障碍文字") {
        let clock = ManualEventNoticeScheduler()
        let notices = model(clock)
        let intent = attentionNotice(
            epoch: notices.receiverEpoch, native: "PreToolUse", host: .claudeCode,
            reason: .questionIntent, observed: clock.time)
        expect(notices.accept(intent) == .accepted, "精确提问绑定的投影可被接受")
        expect(
            notices.snapshot.current?.event == .notification
                && notices.snapshot.current?.kind == .transient
                && notices.snapshot.attentionReminders.isEmpty,
            "提问意图必须使用 notification 语义，且不创建需要你")
        for language in [ClaudioAppLanguage.english, .zhHans] {
            let title = language == .english ? "about to ask you" : "即将向你提问"
            let record = notices.snapshot.current!
            expect(
                EventNoticeProjection.primaryLine(for: record, language: language)
                    == (language == .english ? "Claude Code " : "Claude Code") + title,
                "两种语言必须明确表达调用意图")
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: notices.snapshot, language: language
                ).contains(title),
                "瞬时提问的无障碍文字不能只读需要你")
        }
        clock.advance(EventNoticeModel.displayDuration + EventNoticeModel.fadeDuration * 2 + 0.01)
        expect(
            notices.snapshot.phase == .hidden && notices.snapshot.totalCount == 0
                && notices.resourceUsage.transientVersions == 0,
            "四秒展示结束后不留提醒或瞬时内容")
    }

    suite("提问意图：不更新同会话需要你版本、观察水位或期限") {
        let clock = ManualEventNoticeScheduler()
        let notices = model(clock)
        let installation = UUID()
        let permission = attentionNotice(
            epoch: notices.receiverEpoch, installation: installation,
            native: "Notification", host: .claudeCode, reason: .permission,
            observed: clock.time)
        expect(notices.accept(permission) == .accepted, "先保留同会话授权提醒")
        notices.dismiss(animated: false)
        let original = notices.snapshot.attentionReminders.first!
        clock.advance(60)
        let intent = attentionNotice(
            epoch: notices.receiverEpoch, installation: installation,
            native: "PreToolUse", host: .claudeCode, reason: .questionIntent,
            observed: clock.time)
        expect(notices.accept(intent) == .accepted, "同会话提问意图正常展示")
        let retained = notices.snapshot.attentionReminders.first!
        expect(
            retained.id == original.id && retained.version == original.version
                && retained.notice == original.notice && notices.snapshot.totalCount == 1,
            "既有需要你必须保持原来的不可变内容与版本")
        expect(notices.accept(intent) == .duplicate, "重复 UUID 不重复展示")
        expect(
            notices.resourceUsage.observationEntries == 1,
            "提问意图不创建关注观察水位")
        clock.advance(EventNoticeModel.retentionDuration - 60)
        expect(notices.snapshot.totalCount == 0, "既有提醒按原期限到期，不能被提问意图续期")
    }

    suite("提问意图：静默不补播，明确输入和普通信息保持现有分类") {
        let clock = ManualEventNoticeScheduler()
        let notices = model(clock)
        notices.setAutomaticallySuppressed(true)
        expect(
            notices.accept(
                attentionNotice(
                    epoch: notices.receiverEpoch, native: "PreToolUse", host: .claudeCode,
                    reason: .questionIntent)) == .accepted,
            "静默仍接受合法投影")
        notices.setAutomaticallySuppressed(false)
        expect(
            notices.snapshot.phase == .hidden && notices.snapshot.totalCount == 0
                && notices.resourceUsage.transientVersions == 0,
            "静默期间提问意图不保留或补播")
        let input = attentionNotice(
            epoch: notices.receiverEpoch, native: "Notification", host: .claudeCode,
            reason: .needsInput)
        expect(notices.accept(input) == .accepted, "明确输入可保留")
        expect(
            notices.snapshot.attentionReminders.first?.kind == .needsInput,
            "明确输入仍进入需要你")
        notices.dismiss(animated: false)
        let informational = attentionNotice(
            epoch: notices.receiverEpoch, native: "Notification", host: .claudeCode,
            reason: .informational)
        expect(notices.accept(informational) == .accepted, "普通信息正常展示")
        expect(
            notices.snapshot.current?.kind == .transient && notices.snapshot.totalCount == 1,
            "普通信息不会新增或升级待答提醒")
    }

    suite("提问回执：旧通知、错误原生事件与安装代次不能激活新提问绑定") {
        let question = HostCapabilityCatalog.binding(host: .claudeCode, nativeEvent: "PreToolUse")!
        let notification = HostCapabilityCatalog.binding(
            host: .claudeCode, nativeEvent: "Notification")!
        let installation = UUID()
        let legacy = HostReceiptEvidence(
            bindingID: notification.id, installationID: installation,
            nativeEvent: "Notification", event: .notification,
            timestamp: Date(), playbackResult: .played)
        let mismatches = [
            legacy,
            HostReceiptEvidence(
                bindingID: question.id, installationID: installation,
                nativeEvent: "Notification", event: .notification,
                timestamp: Date(), playbackResult: .played),
            HostReceiptEvidence(
                bindingID: question.id, installationID: UUID(), nativeEvent: "PreToolUse",
                event: .notification, timestamp: Date(), playbackResult: .played),
            HostReceiptEvidence(
                bindingID: question.id, installationID: installation, nativeEvent: "PreToolUse",
                event: .stop, timestamp: Date(), playbackResult: .played),
        ]
        for evidence in mismatches {
            let snapshot = HostIntegrationSnapshot(
                host: .claudeCode, runtime: .ready, availability: .available,
                configuration: .configured, writability: .writable,
                activation: .observed(legacy),
                bindingActivations: [question.id: .observed(evidence)],
                installationID: installation)
            let projected = IntegrationBindingReceiptPresentation(
                binding: question, snapshot: snapshot)
            expect(
                projected.activation == .awaitingReceipt(installationID: installation),
                "跨 binding、原生事件、安装代次或公共事件的回执均不可提升")
            for language in [ClaudioAppLanguage.english, .zhHans] {
                let title = language == .english ? "About to ask" : "即将提问"
                let awaiting = language == .english ? "Unverified" : "待验证"
                expect(
                    projected.text(language: language).contains(title)
                        && projected.text(language: language).contains(awaiting),
                    "缺失当前提问回执必须按提醒类型显示待验证")
                expect(
                    projected.capabilityText(language: language).contains(
                        ClaudioL10n(language: language).text(.qualificationQuestionIntentOnly)),
                    "支持说明不得把调用意图写成明确待答")
            }
        }
    }

    suite("多绑定展示：五事件覆盖，通知与提问分别展示当前回执") {
        let host = HostID.claudeCode
        let bindings = HostCapabilityCatalog.bindings(for: host).filter(\.isAudibleCapability)
        let installation = UUID()
        let activations: [HostEventBindingID: HostActivationEvidence] = Dictionary(
            uniqueKeysWithValues: bindings.filter { $0.nativeEvent != "PreToolUse" }.map {
                binding in
                (
                    binding.id,
                    .observed(
                        HostReceiptEvidence(
                            bindingID: binding.id, installationID: installation,
                            nativeEvent: binding.nativeEvent!, event: binding.event,
                            timestamp: Date(), playbackResult: .played))
                )
            })
        let snapshot = HostIntegrationSnapshot(
            host: host, runtime: .ready, availability: .available, configuration: .configured,
            writability: .writable, activation: activations[bindings[0].id]!,
            bindingActivations: activations, installationID: installation)
        let matrix = AudibilityMatrix.make(
            snapshots: [snapshot], capabilities: [host: bindings],
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
        let content = integrationDestinationContent(
            state: HostIntegrationPresentationState(snapshots: [snapshot], matrix: matrix))
        let facts = content.facts(for: host)!
        expect(
            facts.coverageText == "5/5" && content.matrix.rows.count == 5,
            "多种提醒仍共享五类公共声音，不得显示6/5")
        expect(
            facts.bindingReceipts.count == bindings.count
                && Set(facts.bindingReceipts.map(\.id)).count == bindings.count,
            "逐绑定详情不能按 event 合并通知与提问")
        let notification = facts.bindingReceipts.first { $0.binding.nativeEvent == "Notification" }!
        let question = facts.bindingReceipts.first { $0.binding.nativeEvent == "PreToolUse" }!
        expect(
            notification.activation != .awaitingReceipt(installationID: installation)
                && question.activation == .awaitingReceipt(installationID: installation),
            "旧通知已观察，新提问仍待验证")
        let cell = content.matrix.cell(host: host, event: .notification)!
        expect(cell.state == .awaitingActivation, "合并格不得掩盖缺失的提问回执")
        expect(
            cell.nativeEventText?.contains("Notification") == true
                && cell.nativeEventText?.contains("PreToolUse") == true,
            "公共事件的机制说明必须包含全部绑定")
        for language in [ClaudioAppLanguage.english, .zhHans] {
            expect(
                localizedCapabilityCell(cell, language: language).qualificationText
                    == ClaudioL10n(language: language).text(.qualificationQuestionIntentOnly),
                "多绑定限定语必须从类型化事实完整本地化")
        }
    }
}
