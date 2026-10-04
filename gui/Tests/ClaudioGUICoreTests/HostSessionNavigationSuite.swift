import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runHostSessionNavigationSuites() {
    let process = HostProcessIdentity(pid: 12, startSeconds: 100, startMicroseconds: 0)
    let application = HostProcessIdentity(pid: 13, startSeconds: 100, startMicroseconds: 0)
    func fixture(_ clock: ManualEventNoticeScheduler, native: String = "PermissionRequest")
        -> (EventNoticeModel, EventNoticeAction)
    {
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
            epoch: model.receiverEpoch, native: native,
            processAncestors: [process, application])
        let notice = base.replacingNavigationEvidence(
            HostNavigationEvidence(
                process: process,
                terminalProcess: process, tty: "/dev/ttys001"), ancestors: [process, application])
        _ = model.accept(notice)
        return (model, model.snapshot.current!.action!)
    }
    suite("Host navigation：证据独立解析、实例和版本绑定、无cwd/title猜测") {
        let clock = ManualEventNoticeScheduler()
        let (model, action) = fixture(clock)
        expect(
            model.navigationTarget(for: action)?.route == .terminal(tty: "/dev/ttys001"),
            "精确TTY目标保存在唯一模型")
        expect(model.sourceNotice(for: action)?.navigationEvidence == nil, "原始证据不留第二份")
        model.clearForPrivacy()
        expect(model.navigationTarget(for: action) == nil, "epoch清除解析目标")
        let notice = attentionNotice(epoch: UUID(), processAncestors: [process])
        expect(HostSessionTargetResolver.resolve(notice, application: nil) == nil, "同项目标签不能生成来源App")
    }
    for outcome in [
        SessionNavigationActionResult.applicationFallback, .requestSent, .failed,
        .exactReturnConfirmed,
    ] {
        suite("Host navigation：\(outcome)的提醒与阅读语义") {
            let clock = ManualEventNoticeScheduler()
            let (model, action) = fixture(clock)
            clock.advance(0.18); clock.advance(1)
            let remaining = model.bannerSnapshot.remainingTime
            var calls = 0
            let coordinator = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler(),
                navigateHost: { _, _, current, _, complete in
                    expect(current(), "动作前复验当前版本")
                    calls += 1; complete(outcome == .applicationFallback ? .unavailable : outcome)
                    return EventNoticeCancellation {}
                },
                openApplication: { _, current, complete in
                    expect(current(), "回退也复验当前版本"); complete(.opened);
                    return EventNoticeCancellation {}
                })
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            expect(calls == 1, "统一入口派发一个宿主请求")
            let expected: SessionNavigationActionResult =
                outcome == .failed ? .applicationFallback : outcome
            expect(coordinator.result == expected, "宿主失败退回同一已确认App")
            expect(
                model.snapshot.totalCount == (outcome == .exactReturnConfirmed ? 0 : 1),
                "只有精确确认消除当前提醒版本")
            if outcome != .exactReturnConfirmed {
                expect(model.bannerSnapshot.remainingTime == remaining, "反馈不重置阅读时间或收起横幅")
            }
        }
    }
    suite("Host navigation：取消/超时/新版本禁止迟到确认及应用回退") {
        for change in ["cancel", "timeout", "privacy", "version"] {
            let clock = ManualEventNoticeScheduler()
            let (model, action) = fixture(clock)
            var callback: (@MainActor (SessionNavigationActionResult) -> Void)?
            var current: (@MainActor () -> Bool)?
            var fallbacks = 0, starts = 0
            let coordinator = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler(),
                navigateHost: { _, _, valid, _, complete in
                    starts += 1; current = valid; callback = complete;
                    return EventNoticeCancellation {}
                },
                openApplication: { _, _, _ in
                    fallbacks += 1; return EventNoticeCancellation {}
                })
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            expect(starts == 1, "正文和主按钮双击只派发一次")
            switch change {
            case "cancel": coordinator.cancel()
            case "timeout": clock.advance(3)
            case "privacy": model.clearForPrivacy()
            default:
                let installation = model.sourceNotice(for: action)!.installationID
                _ = model.accept(
                    attentionNotice(epoch: model.receiverEpoch, installation: installation))
            }
            expect(current?() == false, "适配器每步能看到请求已失效：\(change)")
            callback?(.unavailable); callback?(.exactReturnConfirmed)
            expect(
                fallbacks == 0 && coordinator.result != .exactReturnConfirmed,
                "迟到失败不能发起回退或产生精确成功：\(change)")
        }
    }
    suite("Host navigation：deadline先于延迟timer、预期焦点交接有明确阶段") {
        let clock = ManualEventNoticeScheduler()
        let (model, action) = fixture(clock)
        var callback: (@MainActor (SessionNavigationActionResult) -> Void)?
        var fallbacks = 0
        let coordinator = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(),
            uptime: { clock.time },
            navigateHost: { _, _, _, _, complete in
                callback = complete; return EventNoticeCancellation {}
            },
            openApplication: { _, _, _ in
                fallbacks += 1; return EventNoticeCancellation {}
            })
        coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
        expect(!coordinator.permitsFocusHandoff(to: application.pid), "只读准备阶段切走不能冒充预期交接")
        callback?(.focusHandoffStarted)
        expect(coordinator.permitsFocusHandoff(to: application.pid), "固定聚焦动作派发前允许目标App交接")
        clock.time += 3.1  // Simulate a delayed timer without executing its callback.
        callback?(.unavailable)
        expect(coordinator.result == .timedOut && fallbacks == 0, "预算耗尽后的失败不能启动新的应用激活")
        expect(model.snapshot.totalCount == 1, "超时保留提醒")
    }

}
