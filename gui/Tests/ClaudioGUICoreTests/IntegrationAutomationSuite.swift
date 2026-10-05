import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runIntegrationAutomationSuites() {
    suite("自动集成状态：准备和真实 binding 回执分开，关闭意愿与接入配置分开") {
        var snapshot = HostIntegrationSnapshot.connectedForTesting(host: .codex)
        expect(IntegrationAutomaticState(snapshot: snapshot) == .received, "匹配 binding 收到事件")
        snapshot.intent = HostIntegrationIntent(enabled: false)
        expect(IntegrationAutomaticState(snapshot: snapshot) == .disabled, "清理失败留下 hooks 也仍关闭")
        var prepared = HostIntegrationSnapshot(
            host: .codex, runtime: .ready, availability: .available,
            configuration: .configured, writability: .writable,
            activation: .awaitingReceipt(installationID: UUID()))
        prepared.intent = HostIntegrationIntent(enabled: true)
        expect(IntegrationAutomaticState(snapshot: prepared) == .prepared, "无回执只能准备好，不制造确认要求")
        var absent = HostIntegrationSnapshot(
            host: .codex, runtime: .ready, availability: .notInstalled,
            configuration: .configured, writability: .writable, activation: .none)
        absent.intent = HostIntegrationIntent(enabled: true)
        expect(IntegrationAutomaticState(snapshot: absent) == .notInstalled, "未安装优先列出")
        absent.intentUnavailable = true
        expect(IntegrationAutomaticState(snapshot: absent) == .notInstalled, "未安装不得显示可开启")
        let detail = SettingsRoute.integrations(.init(surface: .codex))
        let diagnostics = SettingsRoute.integrations(
            .init(surface: .codex, detailsHost: .codex, level: .diagnostics))
        expect(
            detail != diagnostics && detail.destination == diagnostics.destination, "同一窗口内的不同浏览身份")
        expect(
            IntegrationAutomaticState.prepared.text(language: .english) == "Integration prepared",
            "English 状态有明确文案")
    }
    suite("通知 revision：旧消息可解码，缺失/非法 revision 拒收，复制和降级保留 revision") {
        let epoch = UUID(), revision = UUID()
        let legacy = attentionNotice(epoch: epoch)
        let legacyBytes = try! JSONEncoder().encode(legacy)
        expect(
            (try? JSONDecoder().decode(HostEventNotice.self, from: legacyBytes)) != nil,
            "schema 1 旧消息仍可解码")
        let model = EventNoticeModel(
            receiverEpoch: epoch, noticeAuthorized: { $0.intentRevision == revision })
        expect(model.accept(legacy) == .ignoredDisabled, "最终 reducer 拒绝旧消息")
        var json = try! JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
        json["intent_revision"] = "invalid"
        let malformed = try! JSONDecoder().decode(
            HostEventNotice.self, from: JSONSerialization.data(withJSONObject: json))
        expect(
            malformed.intentRevision == nil && model.accept(malformed) == .ignoredDisabled,
            "非法 revision 失败关闭")
        json["intent_revision"] = revision.uuidString
        let current = try! JSONDecoder().decode(
            HostEventNotice.self, from: JSONSerialization.data(withJSONObject: json))
        expect(current.removingProcessAncestors().intentRevision == revision, "8 KiB 降级保留 revision")
        let process = HostProcessIdentity(pid: 10, startSeconds: 1, startMicroseconds: 0)
        expect(
            current.replacingNavigationEvidence(
                HostNavigationEvidence(process: process, tty: "/dev/ttys001"), ancestors: [process]
            ).intentRevision == revision, "异步导航复制保留 revision")
        expect(
            try! JSONEncoder().encode(current).count < EventNoticeTransport.maximumMessageBytes,
            "新字段保持消息有界")
    }
    suite("关闭来源：收起横幅且拒绝迟到输入，保留冻结阅读、待接手和主动导航身份") {
        let clock = ManualEventNoticeScheduler(), epoch = UUID(), revision = UUID()
        var enabled = true
        let model = EventNoticeModel(
            receiverEpoch: epoch, now: { clock.time }, scheduler: clock.scheduler(),
            noticeAuthorized: { enabled && $0.intentRevision == revision })
        let input = attentionNotice(epoch: epoch)
        var json =
            try! JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
        json["intent_revision"] = revision.uuidString
        let notice = try! JSONDecoder().decode(
            HostEventNotice.self, from: JSONSerialization.data(withJSONObject: json))
        expect(model.accept(notice) == .accepted, "先合法接收")
        clock.advance(0.2)
        model.openReading(.panel)
        let reading = model.readingSnapshot.records
        let epochBefore = model.receiverEpoch
        enabled = false
        model.hideBanner(for: .claudeCode)
        expect(model.bannerSnapshot.current != nil, "关闭其他来源不影响当前横幅")
        model.hideBanner(for: .codex)
        expect(model.bannerSnapshot.current == nil, "立即收起该来源横幅")
        expect(
            model.receiverEpoch == epochBefore
                && model.readingSnapshot.records.map(\.action) == reading.map(\.action)
                && model.snapshot.totalCount == 1, "不做全局隐私清空")
        expect(model.accept(notice) == .ignoredDisabled, "迟到输入拒收")
        if let action = reading.first?.action {
            expect(model.readingRecord(for: action) != nil, "已接受记录仍可主动导航")
        }
        clock.advance(30 * 60 + 1)
        expect(
            model.snapshot.totalCount == 0 && model.readingSnapshot.records.allSatisfy(\.isExpired),
            "保留原 TTL，不永久延长")
    }
}
