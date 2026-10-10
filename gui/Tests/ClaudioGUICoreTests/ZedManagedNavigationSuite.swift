import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private final class ZedSearchFixture {
    let target = UUID()
    let others = (0..<12).map { _ in UUID() }
    let windowA = UUID()
    let windowB = UUID()
    let epoch = UUID()
    var time: TimeInterval = 10
    var inputRevision: UInt64 = 0
    var sequence: UInt64 = 1
    var current = true
    var foreground = false
    var selectedWindow: UUID?
    var pane = 0
    var tab = 0
    var states: [ZedPTYFocusState] = []
    var targetWindowB = false
    var unmanagedWindowA = false
    var targetPane = 0
    var targetTab = 0
    var stale = false
    var loseFocusOnReadback = false
    var interfere = false
    var actions = 0
    var actionDelay: TimeInterval = 0.025
    var edgeLeavesManagedPane = false
    var requiresDockActivation = false
    var dockActivated = false
    var threePaneLayout = false
    var preserveSelectedWindowFocus = false
    var supportsDirections = true
    var unsupportedDirectionAttempts = 0

    func report() {
        sequence += 1
        if (unmanagedWindowA && selectedWindow == windowA) || pane < 0
            || (requiresDockActivation && !dockActivated)
        {
            states = []
            return
        }
        let selectedTarget =
            selectedWindow == (targetWindowB ? windowB : windowA)
            && pane == targetPane && tab == targetTab
        states = [
            ZedPTYFocusState(
                instance: target, sequence: sequence,
                focused: selectedTarget, observedUptime: stale ? 9 : time),
            ZedPTYFocusState(
                instance: others[(selectedWindow == windowB ? 6 : 0) + pane * 2 + tab],
                sequence: sequence,
                focused: !selectedTarget, observedUptime: time),
        ]
    }

    var environment: ZedNavigationSearch.Environment {
        ZedNavigationSearch.Environment(
            now: { self.time }, isCurrent: { self.current },
            windows: { [self.windowA, self.windowB] },
            selectWindow: { window in
                self.actions += 1; self.time += self.actionDelay
                if self.preserveSelectedWindowFocus && self.foreground
                    && self.selectedWindow == window
                {
                    return true
                }
                self.selectedWindow = window; self.foreground = true
                self.report(); return true
            },
            isWindowCurrent: { self.foreground && self.selectedWindow == $0 },
            step: { action in
                if action != .nextTab && !self.supportsDirections {
                    self.unsupportedDirectionAttempts += 1; return false
                }
                self.actions += 1; self.time += self.actionDelay
                if self.unmanagedWindowA && self.selectedWindow == self.windowA {
                    if self.interfere { self.inputRevision += 1 }
                    self.report(); return true
                }
                if action == .nextTab { self.tab = (self.tab + 1) % 2 }
                if action == .down && self.selectedWindow == self.windowB {
                    self.dockActivated = true
                }
                if self.threePaneLayout {
                    switch action {
                    case .left: self.pane = self.pane == 1 ? 0 : -1
                    case .right: self.pane = self.pane < 0 ? 0 : 1
                    case .down: if self.pane == 0 { self.pane = 2 }
                    case .up: if self.pane == 2 { self.pane = 0 }
                    case .nextTab: break
                    }
                } else {
                    if action == .right { self.pane = 1 }
                    if action == .left { self.pane = self.edgeLeavesManagedPane ? -1 : 0 }
                }
                if self.interfere { self.inputRevision += 1 }
                self.report(); return true
            },
            snapshot: {
                self.time += 0.005
                if self.loseFocusOnReadback,
                    self.states.contains(where: { $0.instance == self.target && $0.focused })
                {
                    self.foreground = false
                }
                return ZedNavigationSnapshot(
                    epoch: self.epoch, inputRevision: self.inputRevision, states: self.states)
            }, supportsDirections: { self.supportsDirections })
    }
}

@MainActor
func runZedManagedNavigationSuites() async {
    runZedManagedIdentitySuites()
    await runZedManagedCoordinatorSuites()
    await runZedWindowSelectionSuites()
    await suite("Zed managed：窗口、pane 与 tab 搜索必须由目标新回执确认") {
        for position in 0..<4 {
            let fixture = ZedSearchFixture()
            fixture.targetTab = position & 1
            fixture.targetPane = (position >> 1) & 1
            fixture.targetWindowB = position == 3
            let result = await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
            expect(result == .exactReturnConfirmed, "搜索正确身份，位置 \(position)")
            expect(
                fixture.pane == fixture.targetPane && fixture.tab == fixture.targetTab,
                "不能将同目录另一 terminal 当成功")
            expect(
                !fixture.targetWindowB || fixture.selectedWindow == fixture.windowB, "窗口由具体原生身份选中")
        }
    }
    await suite("Zed managed：未注册的前窗口不能耗尽后窗口的焦点检查预算") {
        let fixture = ZedSearchFixture()
        fixture.unmanagedWindowA = true; fixture.targetWindowB = true
        let result = await ZedNavigationSearch.navigate(
            instance: fixture.target, deadline: 13, environment: fixture.environment)
        expect(
            result == .exactReturnConfirmed && fixture.selectedWindow == fixture.windowB,
            "三秒内先读回后窗口的目标焦点，不在无受管理回执的前窗口耗尽预算")
    }
    await suite("Zed managed：后窗口隐藏分屏须在原预算内找到新回执") {
        let fixture = ZedSearchFixture()
        fixture.unmanagedWindowA = true; fixture.targetWindowB = true
        fixture.targetPane = 1; fixture.actionDelay = 0.11
        let result = await ZedNavigationSearch.navigate(
            instance: fixture.target, deadline: 13, environment: fixture.environment)
        expect(
            result == .exactReturnConfirmed && fixture.selectedWindow == fixture.windowB
                && fixture.pane == 1,
            "已读回受管理焦点的窗口中存在隐藏目标时，不先深扫无回执窗口耗尽三秒")
        expect(fixture.time < 13, "搜索与最终确认共用原三秒预算")
    }
    await suite("Zed managed：空编辑分屏的 tab 探测不能饿死相邻 terminal") {
        let fixture = ZedSearchFixture()
        fixture.unmanagedWindowA = true; fixture.targetWindowB = true
        fixture.targetPane = 1; fixture.edgeLeavesManagedPane = true
        fixture.actionDelay = 0.11
        expect(
            await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
                == .exactReturnConfirmed,
            "先在分屏间探测新目标回执，不能在左移到的空编辑区循环 16 个 tab")
        expect(fixture.time < 13 && fixture.pane == 1, "仍在原三秒内由目标分屏确认")
    }
    await suite("Zed managed：窗口激活未恢复 terminal 焦点时须先探测 dock") {
        let fixture = ZedSearchFixture()
        fixture.unmanagedWindowA = true; fixture.targetWindowB = true
        fixture.targetPane = 1; fixture.requiresDockActivation = true
        fixture.actionDelay = 0.11
        expect(
            await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
                == .exactReturnConfirmed,
            "仅 AX 窗口激活没有受管理焦点时，先通过 dock 新回执找到搜索窗口")
        expect(fixture.time < 13 && fixture.selectedWindow == fixture.windowB, "原三秒内确认真实目标窗口")
    }
    await suite("Zed managed：三分屏中必须访问上方 terminal 的下方邻居") {
        let fixture = ZedSearchFixture()
        fixture.unmanagedWindowA = true; fixture.targetWindowB = true
        fixture.targetPane = 2; fixture.threePaneLayout = true
        fixture.actionDelay = 0.075
        expect(
            await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
                == .exactReturnConfirmed,
            "右侧分屏左移到上方 terminal 后，要探测下方邻居而非在侧栏耗尽 tab 预算")
        expect(fixture.time < 13 && fixture.pane == 2, "最终确认真实下方 terminal")
    }
    await suite("Zed managed：持续聚焦窗口仍须先搜索其隐藏 terminal") {
        let fixture = ZedSearchFixture()
        fixture.targetPane = 1; fixture.actionDelay = 0.11
        fixture.preserveSelectedWindowFocus = true
        fixture.selectedWindow = fixture.windowA; fixture.foreground = true; fixture.report()
        expect(
            await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
                == .exactReturnConfirmed,
            "当前焦点没有新的 focus-in 时，屏障读回仍可用于窗口排序；目标必须产生新回执")
        expect(fixture.time < 13 && fixture.selectedWindow == fixture.windowA, "不能先深扫另一个窗口耗尽预算")
    }
    await suite("Zed managed：未安装方向配置仍支持后窗口的 tab 返回") {
        let fixture = ZedSearchFixture()
        fixture.supportsDirections = false; fixture.unmanagedWindowA = true
        fixture.targetWindowB = true; fixture.targetTab = 1
        expect(
            await ZedNavigationSearch.navigate(
                instance: fixture.target, deadline: 13, environment: fixture.environment)
                == .exactReturnConfirmed,
            "分屏键位缺失不能让前窗口的 dock 探测阻断后窗口和 tab 搜索")
        expect(fixture.unsupportedDirectionAttempts == 0, "没有四键配置时不尝试方向动作")
    }
    await suite("Zed managed：旧回执、失焦、干预和预算耗尽都不能确认成功") {
        let stale = ZedSearchFixture(); stale.stale = true
        expect(
            await ZedNavigationSearch.navigate(
                instance: stale.target, deadline: 13, environment: stale.environment)
                != .exactReturnConfirmed, "不重放旧 focus-in")
        let lost = ZedSearchFixture(); lost.loseFocusOnReadback = true
        expect(
            await ZedNavigationSearch.navigate(
                instance: lost.target, deadline: 13, environment: lost.environment)
                != .exactReturnConfirmed, "最终失焦不能成功")
        let interference = ZedSearchFixture(); interference.targetTab = 1;
        interference.interfere = true
        expect(
            await ZedNavigationSearch.navigate(
                instance: interference.target, deadline: 13, environment: interference.environment)
                == .cancelled, "真实用户输入取消搜索")
        let cancelled = ZedSearchFixture(); cancelled.current = false
        expect(
            await ZedNavigationSearch.navigate(
                instance: cancelled.target, deadline: 13, environment: cancelled.environment)
                == .cancelled && cancelled.actions == 0, "取消后不再派发 UI 动作")
        let expired = ZedSearchFixture()
        expect(
            await ZedNavigationSearch.navigate(
                instance: expired.target, deadline: 9, environment: expired.environment)
                == .timedOut && expired.actions == 0, "原始三秒预算已经耗尽则不操作")
    }
}

@MainActor
private func runZedWindowSelectionSuites() async {
    suite("Zed native bindings：默认 terminal 清屏键不可用于分屏导航") {
        expect(!ZedNavigationBindings.hasManagedDirections(nil), "没有显式 keymap 时不派发方向动作")
        expect(
            ZedNavigationBindings.hasManagedDirections(ZedNavigationBindings.managedKeymap),
            "只接受精确的四键实验配置")
        expect(
            String(decoding: ZedNavigationBindings.managedKeymap, as: UTF8.self)
                .contains("\"context\": \"Workspace\""),
            "四键必须在离开 terminal 后仍能返回分屏")
        var edited = ZedNavigationBindings.managedKeymap
        edited.append(contentsOf: [32])
        expect(!ZedNavigationBindings.hasManagedDirections(edited), "配置发生变化时停止方向导航")
        expect(
            !ZedNavigationBindings.hasManagedDirections(Data("[]".utf8)), "不接受未知或空的自定义配置")
        expect(ZedNavigationBindings.directionKey(.left) == 0x6A, "左方向使用 SDK F16")
        expect(ZedNavigationBindings.directionKey(.right) == 0x40, "右方向使用 SDK F17")
        expect(ZedNavigationBindings.directionKey(.up) == 0x4F, "上方向使用 SDK F18")
        expect(ZedNavigationBindings.directionKey(.down) == 0x50, "下方向使用 SDK F19")
        expect(ZedNavigationBindings.directionKey(.nextTab) == nil, "tab-next 保留独立的官方按键")
    }
    await suite("Zed native window：IPC 不确定结果必须读回具体窗口，仍受原期限约束") {
        var time = 10.0, dispatches = 0, activations = 0, reads = 0
        var active = true, selectedAfter = 10.0, lateRead = false
        var dispatch: ZedWindowSelection.Dispatch = .indeterminate
        let environment = ZedWindowSelection.Environment(
            now: { time }, isCurrent: { active },
            activate: {
                activations += 1; return true
            },
            raise: {
                dispatches += 1; return dispatch
            },
            isSelected: {
                reads += 1
                if lateRead { time = 14 }
                return time >= selectedAfter
            },
            pause: { time += $0 })
        expect(
            await ZedWindowSelection.select(deadline: 13, environment: environment),
            "IPC 调用未完成但具体窗口已经读回时，允许后续 PTY 证明")
        expect(dispatches == 1, "不重发可能已经入队的 Raise 动作")

        time = 10; dispatch = .dispatched; selectedAfter = 10.12
        expect(
            await ZedWindowSelection.select(deadline: 13, environment: environment),
            "50 ms 之后才完成的窗口激活仍可在原期限内读回")

        time = 10; dispatch = .unavailable; selectedAfter = 10; reads = 0
        expect(
            !(await ZedWindowSelection.select(deadline: 13, environment: environment))
                && reads == 0,
            "原生动作明确不可用时，不把已选中的窗口当派发成功")

        time = 10; dispatch = .indeterminate; selectedAfter = 11
        expect(
            !(await ZedWindowSelection.select(deadline: 13, environment: environment)) && time < 11,
            "不确定派发且没有窗口读回时有界停止")

        time = 10; selectedAfter = 10.1
        expect(
            !(await ZedWindowSelection.select(deadline: 10.03, environment: environment))
                && time <= 10.03, "窗口等待沿用剩余期限")

        time = 10; active = false; activations = 0
        expect(
            !(await ZedWindowSelection.select(deadline: 13, environment: environment))
                && activations == 0, "取消后不再激活或派发")

        time = 10; active = true; lateRead = true; selectedAfter = 10
        expect(
            !(await ZedWindowSelection.select(deadline: 13, environment: environment)),
            "读回期间已越过原期限，不能接受迟到的窗口选择")
    }
}

@MainActor
private func zedManagedFixture() -> (
    ZedPTYSessionIdentity, SourceApplicationTarget, [Int32: HostProcessSnapshot]
) {
    func process(_ pid: Int32, _ parent: Int32) -> HostProcessSnapshot {
        HostProcessSnapshot(
            identity: HostProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 42),
            parentPID: parent, userID: 501)
    }
    let processes: [Int32: HostProcessSnapshot] = [
        500: process(500, 400), 501: process(501, 500), 400: process(400, 700),
        700: process(700, 1),
    ]
    let session = ZedPTYSessionIdentity(
        instance: UUID(), process: processes[500]!.identity,
        child: processes[501]!.identity, outerTTY: "/dev/ttys001", innerTTY: "/dev/ttys002")
    let app = SourceApplicationTarget(
        action: EventNoticeAction(id: UUID(), version: 1, epoch: UUID(), installationID: UUID()),
        process: processes[700]!.identity, bundleIdentifier: "dev.zed.Zed",
        applicationURL: URL(fileURLWithPath: "/Applications/Zed.app"), name: "Zed")
    return (session, app, processes)
}

@MainActor
private func runZedManagedIdentitySuites() {
    suite("Zed managed：内核 peer、父链、启动身份和两层 TTY 同时复验") {
        let (session, app, original) = zedManagedFixture()
        var processes = original
        var tty: [Int32: String] = [500: session.outerTTY, 501: session.innerTTY]
        func valid(peer: Int32 = 500) -> Bool {
            ZedManagedSession.validate(
                session, kernelPeerPID: peer, application: app, userID: 501,
                readProcess: { processes[$0] }, readTTY: { tty[$0] })
        }
        expect(valid(), "通过真实 UID、peer PID、child 父 PID 与两层 TTY")
        expect(!valid(peer: 400), "JSON 不能冒充另一个 kernel peer")
        processes[501] = HostProcessSnapshot(identity: session.child, parentPID: 500, userID: 502)
        expect(!valid(), "拒绝其他用户 child")
        processes = original
        processes[501] = HostProcessSnapshot(
            identity: HostProcessIdentity(pid: 501, startSeconds: 101, startMicroseconds: 0),
            parentPID: 500, userID: 501)
        expect(!valid(), "拒绝 child PID 复用")
        processes = original
        tty[501] = session.outerTTY
        expect(!valid(), "拒绝 TTY 身份变化")
        tty[501] = session.innerTTY
        var bridgeReads = 0
        expect(
            !ZedManagedSession.validate(
                session, kernelPeerPID: 500, application: app, userID: 501,
                readProcess: { pid in
                    if pid == 500 {
                        bridgeReads += 1
                        if bridgeReads > 1 {
                            return HostProcessSnapshot(
                                identity: session.process, parentPID: 401, userID: 501)
                        }
                    }
                    return original[pid]
                }, readTTY: { tty[$0] }), "查询期间父链改变即拒绝")
    }
}

@MainActor
private func runZedManagedCoordinatorSuites() async {
    await suite("Zed managed：同项目两个会话接入唯一模型与生产协调器") {
        let (first, app, processes) = zedManagedFixture()
        let second = ZedPTYSessionIdentity(
            instance: UUID(),
            process: HostProcessIdentity(pid: 600, startSeconds: 100, startMicroseconds: 42),
            child: HostProcessIdentity(pid: 601, startSeconds: 100, startMicroseconds: 42),
            outerTTY: "/dev/ttys003", innerTTY: "/dev/ttys004")
        let clock = ManualEventNoticeScheduler()
        let sessions = [first, second]
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveNavigationTarget: { notice, app in
                app.flatMap {
                    ZedManagedSession.resolve(notice, application: $0, sessions: sessions)
                }
            },
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action, process: app.process, bundleIdentifier: app.bundleIdentifier,
                    applicationURL: app.applicationURL, name: app.name)
            })
        for (index, session) in sessions.enumerated() {
            let ancestors = [session.child, session.process, processes[400]!.identity, app.process]
            let evidence = HostNavigationEvidence(
                process: session.child, terminalProcess: session.child, tty: session.innerTTY)
            let notice = attentionNotice(
                epoch: model.receiverEpoch, installation: UUID(),
                source: HostEventSource(
                    projectLabel: "same-project", projectKey: "same-key",
                    sessionID: "managed-\(index)", mainSessionIsKnown: true),
                processAncestors: ancestors
            )
            .replacingNavigationEvidence(evidence, ancestors: ancestors)
            expect(model.accept(notice) == .accepted, "接收独立会话提醒")
            expect(
                ZedManagedSession.resolve(notice, application: app, sessions: [session, session])
                    == nil, "重复桥接身份不能选择任意一个")
        }
        let actions = model.snapshot.attentionReminders.compactMap(\.action)
        expect(actions.count == 2, "同项目保留两个独立会话")
        var dispatched: [UUID] = []
        let coordinator = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(), uptime: { clock.time },
            navigateHost: { target, _, _, deadline, complete in
                guard case .zedManaged(let session) = target.route else {
                    complete(.unavailable); return EventNoticeCancellation {}
                }
                dispatched.append(session.instance)
                let fixture = ZedSearchFixture(); fixture.time = clock.time; fixture.targetTab = 1
                let task = Task { @MainActor in
                    let result = await ZedNavigationSearch.navigate(
                        instance: fixture.target, deadline: deadline,
                        environment: fixture.environment)
                    complete(session.instance == first.instance ? result : .unavailable)
                }
                return EventNoticeCancellation { task.cancel() }
            },
            openApplication: { _, _, complete in
                complete(.opened); return EventNoticeCancellation {}
            })
        for action in actions {
            let route = model.navigationTarget(for: action)?.route
            expect(route != nil, "raw ancestry 释放前形成受管理会话路由")
            expect(model.sourceNotice(for: action)?.processAncestors == nil, "模型不再持有祖先或 PTY 字节")
            let count = model.snapshot.totalCount
            let reading = model.stackSnapshot.visible.map(\.readingTime)
            coordinator.navigateSource(action, generation: coordinator.capabilityGeneration)
            for _ in 0..<50 where coordinator.isNavigating { await Task.yield() }
            if case .zedManaged(let session) = route, session.instance == first.instance {
                expect(
                    coordinator.result == .exactReturnConfirmed
                        && model.snapshot.totalCount == count - 1, "只有完整新回执确认才能移除对应提醒")
            } else {
                expect(
                    coordinator.result == .applicationFallback
                        && model.snapshot.totalCount == count, "不可定位时应用回退保留提醒")
                expect(model.stackSnapshot.visible.map(\.readingTime) == reading, "回退不重置剩余阅读预算")
            }
        }
        expect(Set(dispatched) == Set(sessions.map(\.instance)), "没有按项目合并或串到另一 terminal")
    }
}
