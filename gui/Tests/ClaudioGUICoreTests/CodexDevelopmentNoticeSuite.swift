import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runCodexDevelopmentNoticeSuites() {
    let session = "00000000-0000-4000-8000-000000000011"
    func observation(
        run: UUID, request: String = "call_1", sessionID: String = session,
        tool: CodexQuestionObservation.Tool = .synchronous, uptime: TimeInterval = 100
    ) -> CodexQuestionObservation {
        CodexQuestionObservation(
            runID: run, sessionID: sessionID, requestID: request, tool: tool,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), observedUptime: uptime)
    }

    suite("开发观察提示：独立来源，无假 hook、回执身份或需要你") {
        for tool in CodexQuestionObservation.Tool.allCases {
            let clock = ManualEventNoticeScheduler()
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
            let run = UUID()
            model.setDevelopmentObservationRun(run)
            expect(
                model.acceptDevelopmentObservation(observation(run: run, tool: tool)) == .accepted,
                "同步与异步工具仅产生提问意图")
            let record = model.snapshot.current!
            expect(
                record.host == .codex && record.event == .notification
                    && record.kind == .transient && record.reason == .questionIntent,
                "观察必须复用 notification 与唯一瞬时展示槽")
            expect(
                record.notice == nil && record.action == nil && !record.isActionable
                    && record.provenance == .developmentCodexRollout,
                "观察不能伪装宿主 binding、installation 或可执行来源动作")
            expect(
                record.source?.sessionID == session && record.source?.projectKey == nil
                    && record.source?.projectLabel == nil && model.snapshot.totalCount == 0,
                "来源只携带安全会话身份，不推断项目或产生需要你")
            for language in [ClaudioAppLanguage.english, .zhHans] {
                let l10n = ClaudioL10n(language: language)
                expect(
                    EventNoticeProjection.primaryLine(for: record, language: language)
                        == "Codex · \(l10n.text(.eventNoticeQuestionIntent))",
                    "开发观察标题必须表达即将提问")
                expect(
                    EventNoticeProjection.secondaryLine(for: record, language: language)
                        .contains(l10n.text(.eventNoticeDevelopmentObservation)),
                    "开发来源必须在可见与无障碍副行中标明")
            }
            clock.advance(
                EventNoticeModel.displayDuration + EventNoticeModel.fadeDuration * 2 + 0.01)
            expect(
                model.snapshot.phase == .hidden && model.snapshot.totalCount == 0,
                "开发观察使用相同四秒瞬时生命周期")
        }
    }

    suite("开发观察提示：按运行会话请求去重，独立请求与新代次分别接受") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let run = UUID()
        model.setDevelopmentObservationRun(run)
        expect(model.acceptDevelopmentObservation(observation(run: run)) == .accepted, "首个请求接受")
        expect(
            model.acceptDevelopmentObservation(observation(run: run, tool: .asynchronous))
                == .duplicate,
            "同一个run/session/request不能因工具种类变化重复展示")
        model.dismiss(animated: false)
        expect(
            model.acceptDevelopmentObservation(observation(run: run, request: "call_2"))
                == .accepted,
            "另一个请求不能被上一请求吞掉")
        model.dismiss(animated: false)
        expect(
            model.acceptDevelopmentObservation(
                observation(
                    run: run, sessionID: "00000000-0000-4000-8000-000000000012")) == .accepted,
            "相同请求ID在不同会话保持独立")
        let nextRun = UUID()
        model.setDevelopmentObservationRun(nextRun)
        expect(model.snapshot.phase == .hidden, "新代次立即清除旧开发瞬时来源")
        expect(
            model.acceptDevelopmentObservation(observation(run: run)) == .staleEpoch,
            "旧观察代次失效")
        expect(
            model.acceptDevelopmentObservation(observation(run: nextRun)) == .accepted,
            "新代次可以重新使用请求身份")
    }

    suite("开发观察提示：隐私、关闭与无效观察阻断，静默不补播") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let run = UUID()
        expect(
            model.acceptDevelopmentObservation(observation(run: run)) == .staleEpoch,
            "未显式注册开发运行时拒绝观察")
        model.setDevelopmentObservationRun(run)
        for bad in [
            observation(run: run, request: ""),
            observation(run: run, request: String(repeating: "x", count: 257)),
            observation(run: run, request: "line\nbreak"),
            observation(run: run, sessionID: "missing-session"),
        ] {
            expect(model.acceptDevelopmentObservation(bad) == .invalid, "不合法身份不进入展示")
        }
        for time in [99, 101, Double.infinity, Double.nan] {
            expect(
                model.acceptDevelopmentObservation(observation(run: run, uptime: time))
                    == .staleObservation,
                "代次开始之前、未来或不可排序观察均拒绝")
        }
        expect(
            model.snapshot.current == nil && model.resourceUsage.deduplicationEntries == 0,
            "非法输入不产生提示或去重副作用")
        model.setAutomaticallySuppressed(true)
        expect(model.acceptDevelopmentObservation(observation(run: run)) == .accepted, "静默接受合法事实")
        model.setAutomaticallySuppressed(false)
        expect(model.snapshot.phase == .hidden, "静默结束不补播")
        model.setSystemPrivacy(.screenLocked, active: true)
        expect(
            model.acceptDevelopmentObservation(observation(run: run)) == .ignoredDisabled,
            "锁屏时拒绝观察")
        model.setSystemPrivacy(.screenLocked, active: false)
        expect(
            model.acceptDevelopmentObservation(observation(run: run)) == .staleEpoch,
            "解锁不会恢复旧代次")
        let nextRun = UUID()
        model.setDevelopmentObservationRun(nextRun)
        expect(model.acceptDevelopmentObservation(observation(run: nextRun)) == .accepted, "恢复需新代次")
        model.setDevelopmentObservationRun(nil)
        expect(
            model.snapshot.current == nil && model.resourceUsage.deduplicationEntries == 0
                && model.acceptDevelopmentObservation(observation(run: nextRun)) == .staleEpoch,
            "关闭开发观察清空其提示和去重信息")
    }

    suite("开发观察提示：不修改同会话宿主需要你与原期限") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let permission = attentionNotice(
            epoch: model.receiverEpoch,
            source: HostEventSource(
                projectLabel: "project", projectKey: "project-key", sessionID: session,
                mainSessionIsKnown: true), observed: clock.time)
        expect(model.accept(permission) == .accepted, "已有真实宿主授权提醒")
        model.dismiss(animated: false)
        let previous = model.snapshot.attentionReminders.first!
        clock.advance(60)
        let run = UUID()
        model.setDevelopmentObservationRun(run)
        expect(
            model.acceptDevelopmentObservation(observation(run: run, uptime: clock.time))
                == .accepted,
            "同会话开发观察仍可瞬时展示")
        let retained = model.snapshot.attentionReminders.first!
        expect(
            retained.id == previous.id && retained.version == previous.version
                && retained.notice == previous.notice && model.snapshot.totalCount == 1,
            "开发观察不能冒充明确输入请求或更新已有需要你")
        model.setDevelopmentObservationRun(nil)
        expect(model.snapshot.totalCount == 1, "关闭开发来源不移除宿主提醒")
        clock.advance(EventNoticeModel.retentionDuration - 60)
        expect(model.snapshot.totalCount == 0, "宿主提醒仍按原期限到期")
    }

    suite("开发观察提示：共享去重内存有界且按期限清除") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let run = UUID()
        model.setDevelopmentObservationRun(run)
        model.setAutomaticallySuppressed(true)
        for index in 0..<300 {
            _ = model.acceptDevelopmentObservation(observation(run: run, request: "call_\(index)"))
        }
        expect(
            model.resourceUsage.deduplicationEntries == EventNoticeModel.maximumMetadataCount,
            "开发观察不保存无限请求身份")
        clock.advance(EventNoticeModel.retentionDuration)
        expect(model.resourceUsage.deduplicationEntries == 0, "运行中的观察去重信息也按TTL释放")
    }
}
