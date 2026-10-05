import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@MainActor
func runEventNoticeReaderSuites() {
    _ = NSApplication.shared
    suite("Event reader：来源已在前台时区分显式退出、外部点击和真实导航交接") {
        for exit in [
            "escape", "collapse", "unmount", "selection", "close", "outside", "third-app",
            "handoff",
        ] {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                expect(false, "夹具需要当前前台应用身份")
                return
            }
            let clock = ManualEventNoticeScheduler()
            let process = HostProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 0)
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
                resolveSourceApplication: { _, action in
                    SourceApplicationTarget(
                        action: action, process: process, bundleIdentifier: "com.apple.Terminal",
                        applicationURL: URL(fileURLWithPath: "/fixture/Terminal.app"),
                        name: "Terminal")
                })
            _ = model.accept(
                attentionNotice(epoch: model.receiverEpoch, processAncestors: [process])
                    .replacingNavigationEvidence(
                        HostNavigationEvidence(
                            process: process, terminalProcess: process, tty: "/dev/ttys001"),
                        ancestors: [process]))
            let action = model.bannerSnapshot.current!.action!
            model.openReading(.panel)
            let focus = PanelFocusCoordinator()
            focus.requestNotice(action)
            var finish: (@MainActor (SessionNavigationActionResult) -> Void)?
            var cancellations = 0
            let navigation = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler(), uptime: { clock.time },
                navigateHost: { _, _, _, _, complete in
                    finish = complete
                    complete(.focusHandoffStarted)
                    return EventNoticeCancellation { cancellations += 1 }
                })
            let hosting = NSHostingView(
                rootView: AnyView(
                    EventNoticeReaderTestRoot(model: model, navigation: navigation, focus: focus)))
            let window = eventReaderWindow(hosting)
            defer { window.orderOut(nil); window.close() }
            eventReaderSettle(hosting)
            // SwiftUI's in-process AX tree is absent in this harness. The detail mounts exactly
            // Back, Copy, Open Source, Remove as native NSButtons; exercise the real third action.
            let buttons = eventReaderDescendants(hosting).compactMap { $0 as? NSButton }
            expect(buttons.count == 4, "真实阅读器挂载四个详情动作")
            guard buttons.count == 4 else { continue }
            buttons[2].performClick(nil)
            eventReaderSettle(hosting)
            expect(
                navigation.result == .started && navigation.permitsFocusHandoff(to: pid),
                "夹具进入来源原已前台且交接已开始的边界")
            switch exit {
            case "escape": _ = focus.consumeNoticeEscape()
            case "collapse": focus.noticeIsExpanded = false
            case "selection": focus.noticeSelection = nil
            case "close", "outside", "third-app", "handoff":
                let reason: MenuBarPanel.Dismissal =
                    exit == "close"
                    ? .explicit : exit == "outside" ? .outsideInteraction : .keyResignation
                let preserves = reason.preservesNoticeNavigation(
                    navigation, frontmostPID: exit == "third-app" ? pid + 1 : pid)
                focus.notePanelHidden(preservingNoticeNavigation: preserves)
            default: hosting.rootView = AnyView(EmptyView())
            }
            eventReaderSettle(hosting)
            let handoff = exit == "handoff"
            expect(
                navigation.result == (handoff ? .started : .cancelled)
                    && cancellations == (handoff ? 0 : 1),
                "只保留预期导航造成的 key 交接：\(exit)")
            finish?(.exactReturnConfirmed)
            expect(
                model.isCurrent(action) == !handoff
                    && navigation.result == (handoff ? .exactReturnConfirmed : .cancelled),
                "只有正常交接后的精确确认能移除提醒：\(exit)")
            if handoff {
                focus.requestFocus()
                expect(!focus.preservesNoticeNavigationOnHide, "重新打开面板清除上次交接原因")
            }
        }
    }
    suite("Event reader：普通未知来源定位当前瞬时详情，不进入待接手历史") {
        for hasReminder in [false, true] {
            let clock = ManualEventNoticeScheduler()
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, native: "Stop",
                    source: HostEventSource(
                        projectLabel: "transient", sessionID: "transient-session")))
            let action = model.bannerSnapshot.current!.action!
            if hasReminder { _ = model.accept(attentionNotice(epoch: model.receiverEpoch)) }
            model.openReading(.panel)
            if !model.readingSnapshot.records.contains(where: { $0.action == action }) {
                model.refreshReading()
            }
            let frozen = model.readingSnapshot.records
            let focus = PanelFocusCoordinator()
            focus.requestNotice(action)
            let navigation = SessionNavigationCoordinator(model: model)
            let hosting = NSHostingView(
                rootView: AnyView(
                    EventNoticeReaderTestRoot(model: model, navigation: navigation, focus: focus)))
            let window = eventReaderWindow(hosting)
            defer { window.orderOut(nil); window.close() }
            eventReaderSettle(hosting)
            expect(
                eventReaderDescendants(hosting).compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue == "transient-session" },
                "无提醒或已有其他提醒时都必须挂载传入普通记录的详情：\(hasReminder)")
            expect(model.readingSnapshot.records == frozen, "详情不改写冻结提醒集合")
            expect(
                model.readingRecord(for: action)?.sessionID == "transient-session"
                    && model.readingRecord(for: action)?.sourceApplication == nil,
                "模型按捕获身份投影当前普通事件的安全来源")
            let buttons = eventReaderDescendants(hosting).compactMap { $0 as? NSButton }
            expect(buttons.count == 2, "普通详情仅提供返回和复制，不提供提醒移除")
            expect(
                model.snapshot.totalCount == (hasReminder ? 1 : 0)
                    && model.resourceUsage.transientVersions == 1,
                "普通记录仍只占当前瞬时槽，不成为历史")
        }
    }
    suite("Event reader：瞬时详情随展示槽释放，提醒旧版本继续按冻结合同失效") {
        for change in ["dismiss", "replacement", "expiry", "privacy"] {
            let clock = ManualEventNoticeScheduler()
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
            let action = model.bannerSnapshot.current!.action!
            model.openReading(.panel)
            expect(model.readingRecord(for: action)?.action == action, "当前瞬时版本可读")
            switch change {
            case "privacy": model.clearForPrivacy()
            case "expiry":
                model.setKeyboardFocused(true)
                clock.advance(EventNoticeModel.retentionDuration)
            default:
                model.dismiss(animated: false)
                if change == "replacement" {
                    _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
                }
            }
            expect(model.readingRecord(for: action) == nil, "已释放的瞬时动作不可绑定新内容：\(change)")
            expect(model.readingSnapshot.records.isEmpty, "瞬时详情不会留在提醒冻结历史中")
        }
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let installation = UUID()
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: installation))
        model.openReading(.panel)
        let action = model.readingSnapshot.records[0].action!
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: installation))
        expect(
            model.readingRecord(for: action)?.isSuperseded == true
                && model.readingRecord(for: action)?.isActionable == false,
            "提醒查询保留捕获的冻结旧版本，不跳到新版本")
        clock.advance(EventNoticeModel.retentionDuration)
        expect(model.readingRecord(for: action)?.source == nil, "冻结提醒的 TTL 仍擦除内容")
    }
}

@MainActor
private struct EventNoticeReaderTestRoot: View {
    let model: EventNoticeModel
    let navigation: SessionNavigationCoordinator
    @ObservedObject var focus: PanelFocusCoordinator
    private let preferences = ClaudioPreferences(previewLanguage: .english)

    var body: some View {
        if focus.noticeIsExpanded {
            EventNoticeReadingView(
                model: model, preferences: preferences, navigation: navigation,
                selected: $focus.noticeSelection,
                preservesNavigationOnDismissal: { focus.preservesNoticeNavigationOnHide })
        }
    }
}

@MainActor
private func eventReaderWindow(_ hosting: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 312, height: 360),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    return window
}

@MainActor
private func eventReaderSettle(_ hosting: NSView) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    hosting.layoutSubtreeIfNeeded()
}

@MainActor
private func eventReaderDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(eventReaderDescendants)
}
