import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runZedSourceNavigationSuites() {
    let app = SourceApplicationDescriptor(
        pid: 30, bundleIdentifier: "dev.zed.Zed",
        url: URL(fileURLWithPath: "/Applications/Zed.app"), name: "Zed")
    func fixture(
        _ clock: ManualEventNoticeScheduler, application: SourceApplicationDescriptor? = nil
    )
        -> (EventNoticeModel, [EventNoticeAction], SourceApplicationEnvironment)
    {
        let sourceApp = application ?? app
        func process(_ pid: Int32, parent: Int32, effective: UInt32 = 501) -> HostProcessSnapshot {
            HostProcessSnapshot(
                identity: HostProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 42),
                parentPID: parent, userID: effective, realUserID: 501)
        }
        let ordinary = [
            10: process(10, parent: 11), 11: process(11, parent: 12),
            20: process(20, parent: 21), 21: process(21, parent: 22),
            30: process(30, parent: 1),
        ]
        let logins = [
            12: process(12, parent: 30, effective: 0), 22: process(22, parent: 30, effective: 0),
        ]
        let processEnvironment = HostProcessReadEnvironment(
            ordinaryProcess: { ordinary[Int($0)] }, kernelProcess: { logins[Int($0)] },
            executablePath: { _ in "/usr/bin/login" }, verifySystemLoginSignature: { _ in true })
        let read: (Int32) -> HostProcessSnapshot? = {
            HostProcessAncestry.read($0, userID: 501, environment: processEnvironment)
        }
        let environment = SourceApplicationEnvironment(
            userID: 501, ownPID: 900, process: read,
            application: { $0 == sourceApp.pid ? sourceApp : nil }, locationMatches: { _ in true },
            activate: { _ in true }, frontmost: { nil },
            reopenInactive: { _, complete in complete(nil) })
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { ancestors, action in
                SourceApplicationAdapter.resolve(
                    ancestors, action: action, environment: environment)
            })
        let installation = UUID()
        for (hostPID, tty, session) in [
            (Int32(10), "/dev/ttys001", "session-a"), (20, "/dev/ttys002", "session-b"),
        ] {
            let ancestors = HostProcessAncestry.capture(
                startingAt: hostPID, userID: 501, readProcess: read)
            expect(
                ancestors.map(\.pid) == [hostPID, hostPID + 1, hostPID + 2, 30],
                "helper保存完整应用/login/shell/宿主链：\(session)")
            let evidence = HostNavigationEvidence.capture(
                ancestors: ancestors,
                environment: sourceApp.bundleIdentifier == "com.googlecode.iterm2"
                    ? ["ITERM_SESSION_ID": "w0t0p0:ABC-123"] : [:],
                userID: 501, readProcess: read,
                readTTY: { $0 == 30 ? nil : tty })
            guard let evidence else { expect(false, "本机TTY证据应有效"); continue }
            expect(evidence.terminalProcess?.pid == hostPID + 1, "TTY仍绑定存活shell：\(session)")
            let notice = attentionNotice(
                epoch: model.receiverEpoch, installation: installation,
                source: HostEventSource(
                    projectLabel: "same-project", projectKey: "same-project-key",
                    sessionID: session,
                    mainSessionIsKnown: true), processAncestors: ancestors
            ).replacingNavigationEvidence(evidence, ancestors: ancestors)
            expect(model.accept(notice) == .accepted, "同项目两个terminal各自接收提醒")
        }
        return (model, model.snapshot.attentionReminders.compactMap(\.action), environment)
    }

    suite("Zed navigation：两个同项目terminal只打开来源应用，保留提醒和阅读预算") {
        let clock = ManualEventNoticeScheduler()
        let (model, actions, baseEnvironment) = fixture(clock)
        expect(actions.count == 2 && model.snapshot.totalCount == 2, "同项目不合并不同terminal的提醒")
        guard actions.count == 2 else { return }
        clock.advance(0.27); clock.advance(1)
        let reading = model.stackSnapshot.visible.map(\.readingTime)
        var activations: [Int32] = [], hostRequests = 0
        var environment = baseEnvironment
        environment.activate = {
            activations.append($0); return true
        }
        let coordinator = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(), uptime: { clock.time },
            navigateHost: { _, _, _, _, complete in
                hostRequests += 1; complete(.exactReturnConfirmed)
                return EventNoticeCancellation {}
            },
            openApplication: { target, current, complete in
                SourceApplicationAdapter.openApplication(
                    target, isCurrent: current, complete: complete, environment: environment)
            })
        for action in actions {
            expect(
                model.sourceApplication(for: action)?.bundleIdentifier == "dev.zed.Zed",
                "GUI识别官方Zed")
            expect(model.navigationTarget(for: action) == nil, "Zed没有伪造terminal/tab/window精确路由")
            expect(
                model.sourceNotice(for: action)?.processAncestors == nil
                    && model.sourceNotice(for: action)?.navigationEvidence == nil,
                "唯一模型解析后释放原始祖先与导航证据")
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            expect(coordinator.result == .applicationFallback, "打开应用诚实反馈applicationFallback")
            expect(model.isCurrent(action) && model.snapshot.totalCount == 2, "应用激活不移除提醒")
            let record = model.snapshot.attentionReminders.first { $0.action == action }!
            expect(
                EventNoticeProjection.navigationFeedbackKey(
                    for: record, action: action, result: coordinator.result)
                    == .eventNoticeNavigationFallback,
                "反馈复用已打开来源应用、未定位会话的文案")
            expect(model.stackSnapshot.visible.map(\.readingTime) == reading, "应用回退不重置各条剩余阅读预算")
        }
        expect(activations == [30, 30] && hostRequests == 0, "两个terminal只激活同一Zed实例，不派发精确导航")
        expect(model.lastRemovalReason != .exactReturnConfirmed, "来源识别不伪造精确返回确认")
        clock.advance(0.5)
        expect(
            model.stackSnapshot.visible.first?.readingTime.fraction(at: clock.time)
                == reading.first!.fraction(at: clock.time), "回退后继续原始阅读时间")
    }

    suite("Zed navigation：应用重开沿用三秒截止时间，超时禁止迟到激活") {
        for elapsed in [2.99, 3.0] {
            let clock = ManualEventNoticeScheduler()
            let (model, actions, baseEnvironment) = fixture(clock)
            guard let action = actions.first else { expect(false, "来源提醒应存在"); continue }
            clock.advance(0.27); clock.advance(1)
            model.setHovering(true)
            let reading = model.stackSnapshot.visible.map(\.readingTime)
            var launches = 0, activations = 0
            var callback: (@MainActor (SourceApplicationDescriptor?) -> Void)?
            var environment = baseEnvironment
            // Simulate the captured Zed exiting, followed by NSWorkspace's asynchronous reopen.
            environment.process = { pid in
                guard pid == 31 else { return nil }
                return HostProcessSnapshot(
                    identity: HostProcessIdentity(
                        pid: pid, startSeconds: 200, startMicroseconds: 42),
                    parentPID: 1, userID: 501)
            }
            environment.application = { _ in nil }
            environment.frontmost = { 80 }
            environment.reopenInactive = { _, complete in
                launches += 1; callback = complete
            }
            environment.activate = { _ in
                activations += 1; return true
            }
            let coordinator = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler(), uptime: { clock.time },
                openApplication: { target, current, complete in
                    SourceApplicationAdapter.openApplication(
                        target, isCurrent: current, complete: complete, environment: environment)
                })
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            expect(launches == 1 && coordinator.result == .started, "原始预算内只允许一个应用重开")
            clock.advance(elapsed)
            callback?(
                SourceApplicationDescriptor(
                    pid: 31, bundleIdentifier: app.bundleIdentifier, url: app.url, name: app.name))
            expect(
                coordinator.result == (elapsed < 3 ? .applicationFallback : .timedOut),
                "Zed重开不延长三秒预算：\(elapsed)")
            expect(activations == (elapsed < 3 ? 1 : 0), "截止时间后不能激活迟到的Zed")
            expect(model.isCurrent(action) && model.snapshot.totalCount == 2, "回退和超时均保留提醒")
            expect(model.stackSnapshot.visible.map(\.readingTime) == reading, "回退和超时不重置暂停阅读预算")
        }
    }

    suite("System login navigation：Terminal和iTerm2仍绑定shell，保留原有路由") {
        for (bundle, name, path) in [
            ("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("com.googlecode.iterm2", "iTerm2", "/Applications/iTerm.app"),
        ] {
            let (model, actions, _) = fixture(
                ManualEventNoticeScheduler(),
                application: SourceApplicationDescriptor(
                    pid: 30, bundleIdentifier: bundle, url: URL(fileURLWithPath: path), name: name))
            expect(actions.count == 2, "终端兼容仍接收两条独立提醒：\(name)")
            for action in actions {
                let target = model.navigationTarget(for: action)
                expect(
                    [11, 21].contains(target?.terminalProcess?.pid ?? 0), "精确路由仍绑定shell：\(name)")
                switch target?.route {
                case .terminal(let tty):
                    expect(
                        bundle == "com.apple.Terminal" && HostNavigationEvidence.validTTY(tty),
                        "Terminal仍按TTY定位")
                case .iterm(let session, let tty):
                    expect(
                        bundle == "com.googlecode.iterm2" && session == "w0t0p0:ABC-123"
                            && HostNavigationEvidence.validTTY(tty), "iTerm2仍按session和TTY定位")
                default: expect(false, "系统login兼容不能改变原有终端路由")
                }
            }
        }
    }
}
