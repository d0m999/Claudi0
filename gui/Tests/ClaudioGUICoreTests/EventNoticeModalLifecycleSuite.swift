import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Foundation

@MainActor
func runEventNoticeModalLifecycleSuites() async {
    suite("Event Notice Modal：关闭 sheet 父窗口后恢复剩余预算并自动收起") {
        let fixture = EventNoticeModalLifecycleFixture()
        defer { fixture.close() }
        fixture.clock.advance(1)
        let (parent, sheet) = fixture.beginSheet()
        expect(fixture.observer.isPaused, "真实 beginSheet 通知暂停阅读")
        let saved = fixture.model.stackSnapshot.visible[0].readingTime.remaining
        expect(abs(saved - 3) < 0.001, "暂停保存已消耗一秒后的剩余预算")
        fixture.clock.advance(60)
        expect(fixture.model.stackSnapshot.visible.count == 1, "弹窗打开期间不收起横幅")
        parent.close()
        expect(!parent.isVisible && !sheet.isVisible, "父窗口关闭后两个原生窗口均不可见")
        expect(!fixture.observer.isPaused, "即使没有 didEndSheet，父窗口关闭也释放 modal")
        expect(!fixture.model.stackSnapshot.pauseReasons.contains(.modal), "模型恢复阅读")
        fixture.clock.advance(saved - 0.01)
        expect(fixture.model.stackSnapshot.visible.count == 1, "用完剩余预算之前仍可读")
        fixture.clock.advance(0.02 + EventNoticeModel.fadeDuration)
        expect(!fixture.model.stackSnapshot.hasPresentation, "用完剩余预算后自动收回")
    }

    await suite("Event Notice Modal：正常结束 sheet 恢复阅读且不重置预算") {
        let fixture = EventNoticeModalLifecycleFixture()
        defer { fixture.close() }
        fixture.clock.advance(2)
        let (parent, sheet) = fixture.beginSheet()
        fixture.clock.advance(30)
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        await waitForEventNoticeModalEnd(fixture.observer)
        expect(!fixture.observer.isPaused, "真实 didEndSheet 释放 modal")
        fixture.clock.advance(2.01 + EventNoticeModel.fadeDuration)
        expect(!fixture.model.stackSnapshot.hasPresentation, "正常结束也只消费剩余两秒")
    }

    await suite("Event Notice Modal：关闭一个父窗口保留其他 sheet 的暂停") {
        let fixture = EventNoticeModalLifecycleFixture()
        defer { fixture.close() }
        let (first, firstSheet) = fixture.beginSheet()
        let (second, secondSheet) = fixture.beginSheet()
        first.close()
        expect(fixture.observer.isPaused, "第二个 sheet 仍打开时不能恢复阅读")
        first.endSheet(firstSheet)
        firstSheet.orderOut(nil)
        expect(fixture.observer.isPaused, "已关闭窗口的迟到结束不释放其他窗口")
        fixture.clock.advance(10)
        expect(fixture.model.stackSnapshot.visible.count == 1, "其他 modal 保留预算")
        second.endSheet(secondSheet)
        secondSheet.orderOut(nil)
        await waitForEventNoticeModalEnd(fixture.observer)
        expect(!fixture.observer.isPaused, "最后一个 sheet 结束后恢复")
        fixture.clock.advance(4.01 + EventNoticeModel.fadeDuration)
        expect(!fixture.model.stackSnapshot.hasPresentation, "恢复后可以正常自动收回")
    }

    suite("Event Notice Modal：嵌套 sheet 随父窗口关闭，悬停与文件选择器仍独立暂停") {
        let fixture = EventNoticeModalLifecycleFixture()
        defer { fixture.close() }
        let (parent, sheet) = fixture.beginSheet()
        _ = fixture.beginSheet(on: sheet)
        fixture.model.setHovering(true)
        parent.close()
        expect(!fixture.observer.isPaused, "关闭根窗口释放整条附属 sheet 链")
        expect(
            fixture.model.stackSnapshot.pauseReasons == .hover,
            "只释放 modal，不清除横幅悬停")
        fixture.clock.advance(10)
        expect(fixture.model.stackSnapshot.visible.count == 1, "悬停仍保留横幅")
        let center = NotificationCenter.default
        center.post(name: .claudioSettingsModalWillBegin, object: nil)
        center.post(name: .claudioSettingsModalWillBegin, object: nil)
        fixture.model.setHovering(false)
        center.post(name: .claudioSettingsModalDidEnd, object: nil)
        expect(fixture.observer.isPaused, "文件选择器的嵌套计数仍独立有效")
        center.post(name: .claudioSettingsModalDidEnd, object: nil)
        expect(!fixture.observer.isPaused, "最后一个文件选择器结束后恢复")
        fixture.clock.advance(4.01 + EventNoticeModel.fadeDuration)
        expect(!fixture.model.stackSnapshot.hasPresentation, "解除所有真实暂停后自动收回")
    }
}

@MainActor
private func waitForEventNoticeModalEnd(_ observer: EventNoticeModalPauseObserver) async {
    let deadline = Date(timeIntervalSinceNow: 3)
    while observer.isPaused && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private final class EventNoticeModalLifecycleFixture {
    let clock = ManualEventNoticeScheduler()
    let model: EventNoticeModel
    let observer: EventNoticeModalPauseObserver
    private var sheets: [(NSWindow, NSPanel)] = []

    init() {
        _ = NSApplication.shared
        let clock = clock
        model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        observer = EventNoticeModalPauseObserver(model: model)
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
        clock.advance(EventNoticeModel.fadeDuration)
    }

    func beginSheet(on existing: NSWindow? = nil) -> (NSWindow, NSPanel) {
        let parent =
            existing
            ?? NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 240, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        parent.orderFront(nil)
        parent.beginSheet(sheet, completionHandler: { _ in })
        sheets.append((parent, sheet))
        return (parent, sheet)
    }

    func close() {
        for (parent, sheet) in sheets.reversed() {
            parent.endSheet(sheet)
            sheet.orderOut(nil)
            parent.orderOut(nil)
            sheet.close()
        }
        model.clearForPrivacy()
    }
}
