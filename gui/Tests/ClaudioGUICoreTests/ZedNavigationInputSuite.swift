import AppKit
import ClaudioCore
import ClaudioGUICore
import Darwin
import Foundation

@testable import ClaudioGUIComponents

@MainActor
func runZedNavigationInputSuites() async {
    let application = NSApplication.shared
    let marker: Int64 = 1024
    func input(_ type: NSEvent.EventType) -> NSEvent {
        if type == .scrollWheel {
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: 1, wheel2: 0, wheel3: 0)!
            return NSEvent(cgEvent: cg)!
        }
        if type == .keyDown {
            return NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0)!
        }
        return NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    suite("Zed input：本应用按键和点击同步撤销资格，原事件仍交给应用") {
        for type in [
            NSEvent.EventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ] {
            guard let monitor = ZedNavigationInputMonitor(marker: marker) else {
                expect(false, "输入监听应安装成功"); continue
            }
            defer { monitor.stop() }
            let event = input(type)
            var delivered: NSEvent?
            let observer = NSEvent.addLocalMonitorForEvents(
                matching: type == .keyDown ? .keyDown : .any
            ) {
                delivered = $0; return $0
            }
            defer { if let observer { NSEvent.removeMonitor(observer) } }
            expect(!monitor.interfered, "没有输入时保留资格")
            application.sendEvent(event)
            expect(monitor.interfered, "本应用输入在 sendEvent 返回前取消：\(type)")
            expect(delivered === event, "取消监听不能吞掉或替换用户事件")
        }
    }

    suite("Zed input：仅忽略本请求自己派发的键盘事件；stop 移除监听") {
        guard let monitor = ZedNavigationInputMonitor(marker: marker) else {
            expect(false, "输入监听应安装成功"); return
        }
        let own = CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: true)!
        own.setIntegerValueField(.eventSourceUserData, value: marker)
        own.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        monitor.observe(NSEvent(cgEvent: own)!)
        expect(!monitor.interfered, "同 marker 同进程的派发不取消自己")
        own.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
        monitor.observe(NSEvent(cgEvent: own)!)
        expect(monitor.interfered, "同 marker 的其他进程仍取消")
        monitor.stop()
        guard let stopped = ZedNavigationInputMonitor(marker: marker) else {
            expect(false, "输入监听应安装成功"); return
        }
        stopped.stop(); stopped.stop()
        application.sendEvent(input(.keyDown))
        stopped.observe(input(.keyDown))
        expect(!stopped.interfered, "stop 可重复调用，移除监听并拒绝迟到事件")
    }

    await suite("Zed input：本应用干预后不再激活窗口，不启动失败应用回退") {
        for phase in ["baseline", "selection", "unavailableBaseline", "unavailableReadback"] {
            guard let monitor = ZedNavigationInputMonitor(marker: marker) else {
                expect(false, "输入监听应安装成功"); continue
            }
            defer { monitor.stop() }
            let clock = ManualEventNoticeScheduler()
            let instance = UUID(), epoch = UUID(), window = UUID()
            let process = HostProcessIdentity(pid: 12, startSeconds: 100, startMicroseconds: 0)
            let session = ZedPTYSessionIdentity(
                instance: instance, process: process,
                child: HostProcessIdentity(pid: 13, startSeconds: 100, startMicroseconds: 0),
                outerTTY: "/dev/ttys001", innerTTY: "/dev/ttys002")
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
                resolveNavigationTarget: { notice, _ in
                    SessionNavigationTarget(
                        surface: notice.surface, projectKey: notice.source?.projectKey,
                        sessionID: notice.source!.sessionID!, route: .zedManaged(session))
                },
                resolveSourceApplication: { _, action in
                    SourceApplicationTarget(
                        action: action, process: process, bundleIdentifier: "dev.zed.Zed",
                        applicationURL: URL(fileURLWithPath: "/Applications/Zed.app"), name: "Zed")
                })
            _ = model.accept(
                attentionNotice(epoch: model.receiverEpoch, processAncestors: [process]))
            guard let action = model.snapshot.current?.action else {
                expect(false, "来源动作应可用"); continue
            }
            var activations = 0, raises = 0, fallbacks = 0, snapshots = 0
            var task: Task<Void, Never>?
            let coordinator = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler(), uptime: { clock.time },
                navigateHost: { _, _, current, deadline, complete in
                    task = Task { @MainActor in
                        let valid = { current() && !monitor.interfered }
                        let result = await ZedNavigationSearch.navigate(
                            instance: instance, deadline: deadline,
                            environment: ZedNavigationSearch.Environment(
                                now: { clock.time }, isCurrent: valid, windows: { [window] },
                                selectWindow: { _ in
                                    await ZedWindowSelection.select(
                                        deadline: deadline,
                                        environment: ZedWindowSelection.Environment(
                                            now: { clock.time }, isCurrent: valid,
                                            activate: {
                                                activations += 1; return true
                                            },
                                            raise: {
                                                raises += 1; return .dispatched
                                            },
                                            isSelected: { phase == "unavailableReadback" },
                                            pause: { _ in
                                                application.sendEvent(input(.leftMouseDown))
                                                clock.advance(0.01)
                                            }))
                                },
                                isWindowCurrent: { _ in true }, step: { _ in false },
                                snapshot: {
                                    snapshots += 1
                                    if phase == "baseline" || phase == "unavailableBaseline"
                                        || (phase == "unavailableReadback" && snapshots == 2)
                                    {
                                        application.sendEvent(input(.keyDown))
                                        if phase != "baseline" { return nil }
                                    }
                                    return ZedNavigationSnapshot(
                                        epoch: epoch, inputRevision: 0, states: [])
                                }))
                        complete(result)
                    }
                    return EventNoticeCancellation { task?.cancel() }
                },
                openApplication: { _, _, complete in
                    fallbacks += 1; complete(.opened); return EventNoticeCancellation {}
                })
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            await task?.value
            let selections = phase == "selection" || phase == "unavailableReadback" ? 1 : 0
            expect(coordinator.result == .cancelled, "本应用输入完成为 cancelled：\(phase)")
            expect(activations == selections, "输入后不能再派发窗口激活")
            expect(
                raises == selections && snapshots == (phase == "unavailableReadback" ? 2 : 1),
                "输入后不再派发或读取下一步")
            expect(fallbacks == 0, "取消不能触发应用回退抢焦点")
            expect(model.isCurrent(action) && model.snapshot.totalCount == 1, "取消保留提醒版本")
        }
    }
}
