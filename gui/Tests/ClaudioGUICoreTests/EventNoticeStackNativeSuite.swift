import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@MainActor
func runEventNoticeStackNativeSuites() {
    print(
        "Native stack system Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"
    )
    runEventNoticeStackMotionNativeSuites()
    suite("Banner Stack native：显式覆盖两种 Reduce Motion 呈现") {
        for reducedMotion in [false, true] {
            let fixture = EventNoticeStackNativeFixture(count: 3, reducedMotion: reducedMotion)
            defer { fixture.close() }
            let before = fixture.model.stackSnapshot.visible
            let closed = before[1]
            expect(
                fixture.press("event-notice.close.\(closed.id.uuidString)"),
                "两种动效偏好都使用真实关闭按钮")
            fixture.settle()
            let stack = fixture.model.stackSnapshot
            expect(stack.visible.map(\.id) == [before[0].id, before[2].id], "动效偏好不改变关闭身份")
            expect(fixture.presentation.output.isEligible, "动效偏好不撤销剩余卡片几何资格")
            if reducedMotion {
                expect(stack.exiting.isEmpty, "Reduce Motion 不保留退场帧")
                expect(stack.visible.allSatisfy { $0.relocation == nil }, "Reduce Motion 不建立让位动效")
            } else {
                expect(stack.exiting.map(\.id) == [closed.id], "普通动效保留捕获的退场帧")
                expect(stack.visible.last?.relocation != nil, "普通动效按共享实测结果建立让位计划")
            }
        }
    }
    suite("Banner Stack native：英中、浅深、窄宽完整卡片测量与逐条动作身份") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            for scheme in [ColorScheme.light, .dark] {
                for width in [440.0, 268.0] {
                    let fixture = EventNoticeStackNativeFixture(
                        count: 4, language: language, scheme: scheme, width: width)
                    defer { fixture.close() }
                    expect(fixture.presentation.output.width == width, "使用请求的真实窗口宽度")
                    let stack = fixture.model.stackSnapshot
                    expect(stack.visible.count == 3 && stack.queued.count == 1, "实际卡高容纳 FIFO 前三条")
                    for item in stack.visible {
                        let height = fixture.presentation.output.cardHeights[item.id] ?? 0
                        expect(height >= 60, "完整卡片有自然高度，不使用旧单卡估算")
                        for control in ["close", "open-source", "body"] {
                            expect(
                                fixture.element(
                                    "event-notice.\(control).\(item.id.uuidString)", role: .button)
                                    != nil,
                                "稳定展示 ID 可唯一定位 \(control)")
                        }
                    }
                    let a = stack.visible[0], b = stack.visible[1], c = stack.visible[2]
                    let aHeight = fixture.presentation.output.cardHeights[a.id] ?? 0
                    fixture.navigation.navigateSource(
                        a.record.action!, generation: fixture.navigation.capabilityGeneration,
                        owner: a.id)
                    fixture.settle()
                    expect(
                        (fixture.presentation.output.cardHeights[a.id] ?? 0) > aHeight,
                        "导航失败文案计入完整卡高")
                    expect(
                        fixture.press("event-notice.close.\(b.id.uuidString)"), "通过实际挂载的 B 关闭按钮派发")
                    fixture.settle()
                    expect(
                        fixture.model.stackSnapshot.visible.prefix(2).map(\.id) == [a.id, c.id],
                        "关闭 B 保留 A、C，等待条目 FIFO 补位")
                    expect(
                        fixture.element("event-notice.close.\(b.id.uuidString)", role: .button)
                            == nil,
                        "退场 B 立即退出无障碍树")
                    expect(
                        fixture.model.stackSnapshot.exiting.first?.backgroundVeil == 0.20,
                        "退场帧保留 B 原层的纱")
                    let failedHeight = fixture.presentation.output.cardHeights[a.id] ?? 0
                    _ = fixture.model.remove(a.record.action!, reason: .exactReturnConfirmed)
                    fixture.settle()
                    expect(
                        abs((fixture.presentation.output.cardHeights[a.id] ?? 0) - failedHeight)
                            < 0.5,
                        "移除版本释放反馈后，退场仍保留已绘制失败文案的卡高")
                }
            }
        }
    }
    suite("Banner Stack native：短队列按自然内容收紧") {
        let fixture = EventNoticeStackNativeFixture(count: 4, width: 268)
        defer { fixture.close() }
        let ids = fixture.model.stackSnapshot.visible.map(\.id)
        expect(fixture.press("event-notice.queue-toggle"), "展开单条等待队列")
        fixture.settle()
        expect(
            fixture.presentation.output.queueHeight > 0
                && fixture.presentation.output.queueHeight < 220,
            "单条等待摘要保留自然高度，不预留完整 220pt")
        expect(fixture.model.stackSnapshot.visible.map(\.id) == ids, "测量列表不改变卡片准入")
        if let item = fixture.model.stackSnapshot.queued.first {
            expect(
                fixture.element("event-notice.queued.\(item.id.uuidString)") != nil,
                "列表测量副本不重复进入辅助功能树")
        }
    }
    suite("Banner Stack native：容量提示、隐藏测量和变窄后恢复") {
        let fixture = EventNoticeStackNativeFixture(count: 51, language: .zhHans, width: 268)
        defer { fixture.close() }
        expect(fixture.model.stackSnapshot.totalCount == 50, "原生展示仍限 50 条")
        expect(fixture.presentation.output.showsCapacityHint, "生产模块实测容量提示")
        expect(fixture.element("event-notice.capacity-hint") != nil, "测量副本不重复进入无障碍树")
        let ids = fixture.model.stackSnapshot.visible.map(\.id)
        fixture.viewportWidth = 440
        fixture.presentation.updateViewport(width: 440, availableHeight: 900)
        fixture.window.orderOut(nil)
        fixture.settle()
        expect(fixture.presentation.output.requests.isEmpty, "隐藏宿主继续完成真实 SwiftUI 测量")
        expect(
            fixture.window.isVisible && fixture.model.stackSnapshot.visible.map(\.id) == ids,
            "恢复展示保持身份")
        expect(!fixture.window.isKeyWindow, "自动恢复不取得 key window")
        fixture.availableHeight = 5
        fixture.settle()
        expect(
            !fixture.window.isVisible && fixture.presentation.output.height <= 5, "完整入口也容不下时隐藏窗口")
        expect(fixture.model.stackSnapshot.totalCount == 50, "隐藏期间保留访问面板的记录")
    }
    suite("Banner Stack native：纱层保留正文与实际彩色阅读轨") {
        for scheme in [ColorScheme.light, .dark] {
            let fixture = EventNoticeStackNativeFixture(count: 3, scheme: scheme)
            defer { fixture.close() }
            guard let bitmap = fixture.bitmap() else { expect(false, "原生栈位图可用"); continue }
            let scale = Double(bitmap.pixelsWide) / fixture.presentation.output.width
            let items = fixture.model.stackSnapshot.visible
            var titles: [NSColor] = [], tracks: [NSColor] = []
            for item in items {
                let top = item.positionY
                let height = fixture.presentation.output.cardHeights[item.id] ?? 0
                var foreground: NSColor?
                var extreme = scheme == .light ? Double.infinity : -Double.infinity
                for y in Int((top + 14) * scale)..<Int((top + 34) * scale) {
                    for x in Int(75 * scale)..<Int(230 * scale) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                            continue
                        }
                        let luminance =
                            (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if scheme == .light ? luminance < extreme : luminance > extreme {
                            foreground = color; extreme = luminance
                        }
                    }
                }
                if let foreground { titles.append(foreground) }
                if let color = bitmap.colorAt(
                    x: Int(40 * scale), y: Int((top + height - 3) * scale))?
                    .usingColorSpace(.sRGB)
                {
                    tracks.append(color)
                }
            }
            expect(titles.count == 3 && tracks.count == 3, "三层均有正文和阅读轨采样")
            if let first = titles.first {
                expect(
                    titles.allSatisfy { stackNativeColorDistance(first, $0) < 0.03 },
                    "三层实际正文颜色保持相同，不被 20%/32% 纱弱化")
            }
            if let first = tracks.first {
                expect(
                    tracks.allSatisfy { stackNativeColorDistance(first, $0) < 0.03 },
                    "三层实际事件色阅读轨保持相同")
            }
            fixture.save(bitmap, name: "stack-\(scheme)-normal")
        }
    }
    suite("Banner Stack native：受限高度、队列滚动与 Escape 整栈清空") {
        let fixture = EventNoticeStackNativeFixture(count: 12)
        defer { fixture.close() }
        expect(fixture.press("event-notice.queue-toggle"), "队列有独立的实际按钮动作入口")
        fixture.clock.advance(1)
        fixture.settle()
        expect(fixture.model.stackSnapshot.pauseReasons.contains(.queueExpansion), "展开暂停整个栈")
        expect(fixture.presentation.output.queueHeight == 220, "队列实际视口最多 220pt")
        guard let scroll = fixture.scrollView(), let document = scroll.documentView else {
            expect(false, "实际挂载的队列可滚动"); return
        }
        expect(document.bounds.height > scroll.contentView.bounds.height, "完整等待列表高于视口")
        let bottom =
            document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.settle()
        expect(abs(scroll.contentView.bounds.minY - bottom) < 1, "队列可以实际滚动到末尾")
        if let last = fixture.model.stackSnapshot.queued.last,
            let row = fixture.element("event-notice.queued.\(last.id.uuidString)"),
            let frame = row.accessibilityFrame?()
        {
            let viewport = fixture.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            expect(viewport.intersects(frame), "末条等待摘要进入实际滚动视口")
        } else {
            expect(false, "末条只读摘要有唯一无障碍身份")
        }
        let saved = fixture.model.stackSnapshot.visible[1].readingTime.remaining
        fixture.availableHeight =
            (fixture.presentation.output.cardHeights[fixture.model.stackSnapshot.visible[0].id] ?? 0)
            + (fixture.presentation.output.queueEntryHeight) + 8
        fixture.settle()
        expect(fixture.model.stackSnapshot.visible.count == 1, "实测高度仅容纳一张完整卡片")
        fixture.clock.advance(5)
        expect(
            fixture.model.stackSnapshot.queued.first?.readingTime.remaining == saved, "回队列保存独立预算")
        fixture.availableHeight = fixture.presentation.output.queueEntryHeight + 1
        fixture.settle()
        expect(fixture.model.stackSnapshot.visible.isEmpty, "极端小屏不截断卡片")
        expect(fixture.element("event-notice.queue-toggle", role: .button) != nil, "零卡时仍有待展示入口")
        let reminders = fixture.model.readingSnapshot.records.count
        fixture.window.allowsKeyboardInteraction = true
        fixture.window.cancelOperation(nil)
        fixture.settle()
        expect(
            fixture.model.stackSnapshot.visible.isEmpty
                && fixture.model.stackSnapshot.queued.isEmpty,
            "原生取消命令清空展示和待展示队列")
        expect(fixture.model.readingSnapshot.records.count == reminders, "Escape 保留待接手提醒")
    }
}

@MainActor
func runEventNoticeStackMotionNativeSuites() {
    suite("Banner Stack native：关闭 B 后等待实测跨帧，C 不上跳或回跳") {
        for (count, width) in [(3, 440.0), (4, 440.0), (3, 268.0), (4, 268.0)] {
            let fixture = EventNoticeStackNativeFixture(count: count, width: width)
            defer { fixture.close() }
            let before = fixture.model.stackSnapshot
            let b = before.visible[1], c = before.visible[2]
            @MainActor func top() -> CGFloat? {
                guard
                    let frame = fixture.element(
                        "event-notice.body.\(c.id.uuidString)", role: .button)?
                        .accessibilityFrame?()
                else { return nil }
                return fixture.window.frame.maxY - frame.maxY
            }
            guard let original = top() else { expect(false, "C 的实际绘制框可读"); return }
            expect(fixture.press("event-notice.close.\(b.id.uuidString)"), "通过 B 的原生关闭动作触发")
            fixture.clock.advance(0)
            expect(!fixture.presentation.output.requests.isEmpty, "关闭后等待当前入口实测")
            for _ in 0..<3 {
                fixture.paintWithoutMeasurementCommit()
                guard let waiting = top() else { expect(false, "等待期间 C 仍可交互"); return }
                expect(
                    abs(waiting - original) < 1,
                    "等待实测的绘制帧保留 C 的已提交位置（偏移 \(waiting - original) pt）")
            }
            expect(fixture.presentation.output.isEligible, "等待期间窗口保持资格")
            expect(fixture.model.stackSnapshot.visible[1].positionY == c.positionY, "尚未提交新位置")
            fixture.settle()
            guard let committed = top() else { expect(false, "提交后 C 的绘制框可读"); return }
            expect(abs(committed - original) < 1, "让位计划的起始绘制帧与等待帧连续")
            let relocated = fixture.model.stackSnapshot.visible.first { $0.id == c.id }!
            expect(
                relocated.relocation != nil && relocated.positionY < c.positionY, "提交建立模型拥有的上移计划")
            fixture.clock.advance(0.04)
            fixture.settle()
            if let delayed = top() {
                expect(abs(delayed - original) < 1, "让位延迟期保持起始帧")
            } else {
                expect(false, "延迟期间 C 仍可访问")
            }
            fixture.clock.advance(0.12)
            fixture.settle()
            if let moving = top() {
                expect(
                    moving < original && moving > original - (c.positionY - relocated.positionY),
                    "中间帧只朝目标位置上移")
            } else {
                expect(false, "让位期间 C 仍可访问")
            }
            fixture.clock.advance(0.3)
            fixture.settle()
            guard let completed = top() else { expect(false, "让位完成后 C 的绘制框可读"); return }
            let travel = c.positionY - relocated.positionY
            expect(abs(completed - original + travel) < 1, "仅按已提交计划完成一次上移")
        }
    }
}

@MainActor
private final class EventNoticeStackNativeFixture {
    private static var preparedAccessibility = false
    let clock = ManualEventNoticeScheduler()
    let model: EventNoticeModel
    let navigation: SessionNavigationCoordinator
    let presentation: EventNoticeStackPresentation
    let hosting: EventNoticeHostingView
    let window: EventNoticePanel
    var availableHeight: Double = 900
    var viewportWidth: Double

    init(
        count: Int, language: ClaudioAppLanguage = .english, scheme: ColorScheme = .light,
        width: Double = 440, reducedMotion: Bool = false
    ) {
        _ = NSApplication.shared
        viewportWidth = width
        let clock = clock
        model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action,
                    process: HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1),
                    bundleIdentifier: "example.terminal",
                    applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
                    name: "Example Terminal")
            })
        let model = model
        navigation = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(), uptime: { clock.time },
            openApplication: { _, _, complete in
                complete(.failed); return EventNoticeCancellation {}
            })
        let preferences = ClaudioPreferences(previewLanguage: language)
        presentation = EventNoticeStackPresentation(
            model: model, preferences: preferences,
            navigation: navigation, scheduler: clock.scheduler())
        presentation.updateViewport(width: width, availableHeight: availableHeight)
        for _ in 0..<count {
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch,
                    processAncestors: [
                        HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)
                    ]))
        }
        hosting = EventNoticeHostingView(
            rootView: EventNoticeView(
                model: model, languageStore: preferences,
                navigation: navigation, presentation: presentation,
                reduceMotionOverride: reducedMotion))
        window = EventNoticePanel(
            contentRect: NSRect(x: 100, y: 80, width: width, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.onEscape = { model.dismissStack() }
        window.orderFront(nil)
        settle()
        if !Self.preparedAccessibility {
            Self.preparedAccessibility = true
            NSApp.finishLaunching()
            let completed = DispatchSemaphore(value: 0)
            let process = ProcessInfo.processInfo.processIdentifier
            DispatchQueue.global().async {
                let app = AXUIElementCreateApplication(process)
                AXUIElementSetMessagingTimeout(app, 1)
                var children: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
                completed.signal()
            }
            let deadline = Date(timeIntervalSinceNow: 2)
            while completed.wait(timeout: .now()) != .success && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
            }
            settle()
        }
        model.setHovering(true)
        clock.advance(0.5)
        settle()
    }

    func settle() {
        presentation.updateViewport(width: viewportWidth, availableHeight: availableHeight)
        // Pump real SwiftUI measurement passes and the injected production scheduler. The
        // fixture does not decide capacity, positions, control reservation or window height.
        let deadline = Date(timeIntervalSinceNow: 2)
        var stable = 0
        while Date() < deadline && stable < 3 {
            let before = presentation.output
            clock.advance(0)
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
            clock.advance(0)
            let output = presentation.output
            window.setFrame(
                NSRect(x: 100, y: 80, width: output.width, height: output.height), display: true)
            if output.isEligible { window.orderFront(nil) } else { window.orderOut(nil) }
            stable = before == output && output.requests.isEmpty ? stable + 1 : 0
        }
    }

    func paintWithoutMeasurementCommit() {
        // Leave the manual scheduler frozen while real SwiftUI layout and paint cross a frame.
        // Preference callbacks may arrive, but the shared presenter cannot commit them yet.
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        hosting.displayIfNeeded()
    }

    func element(_ id: String, role: NSAccessibility.Role? = nil) -> AnyObject? {
        var elements: [AnyObject] = [], seen: Set<ObjectIdentifier> = []
        func visit(_ element: AnyObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.accessibilityIdentifier?() == id
                && (role == nil || element.accessibilityRole?() == role)
            {
                elements.append(element)
            }
            for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject) }
        }
        visit(hosting)
        return elements.count == 1 ? elements.first : nil
    }
    func press(_ id: String) -> Bool {
        guard let button = element(id, role: .button), button.isAccessibilityEnabled?() != false
        else { return false }
        return button.accessibilityPerformPress?() == true
    }
    func scrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap(find).first
        }
        return find(hosting)
    }
    func bitmap() -> NSBitmapImageRep? {
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }
    func save(_ bitmap: NSBitmapImageRep, name: String) {
        guard
            let directory = ProcessInfo.processInfo.environment["CLAUDIO_ATTENTION_SCREENSHOT_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(
            to: output.appendingPathComponent(name + ".png"))
    }
    func close() {
        model.clearForPrivacy(); window.orderOut(nil); window.contentView = nil; window.close()
    }
}

private func stackNativeColorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    max(
        abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
        abs(lhs.blueComponent - rhs.blueComponent))
}
