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
    suite("Banner Stack native：英中、浅深、窄宽完整卡片测量与逐条动作身份") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            for scheme in [ColorScheme.light, .dark] {
                for width in [440.0, 268.0] {
                    let fixture = EventNoticeStackNativeFixture(
                        count: 4, language: language, scheme: scheme, width: width)
                    defer { fixture.close() }
                    let stack = fixture.model.stackSnapshot
                    expect(stack.visible.count == 3 && stack.queued.count == 1, "实际卡高容纳 FIFO 前三条")
                    for item in stack.visible {
                        let height = fixture.heights["card.\(item.id.uuidString)"] ?? 0
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
                    let aHeight = fixture.heights["card.\(a.id.uuidString)"] ?? 0
                    fixture.navigation.navigateSource(
                        a.record.action!, generation: fixture.navigation.capabilityGeneration,
                        owner: a.id)
                    fixture.settle()
                    expect(
                        (fixture.heights["card.\(a.id.uuidString)"] ?? 0) > aHeight,
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
                    let failedHeight = fixture.heights["card.\(a.id.uuidString)"] ?? 0
                    _ = fixture.model.remove(a.record.action!, reason: .exactReturnConfirmed)
                    fixture.settle()
                    expect(
                        abs((fixture.heights["card.\(a.id.uuidString)"] ?? 0) - failedHeight) < 0.5,
                        "移除版本释放反馈后，退场仍保留已绘制失败文案的卡高")
                }
            }
        }
    }
    suite("Banner Stack native：纱层保留正文与实际彩色阅读轨") {
        for scheme in [ColorScheme.light, .dark] {
            let fixture = EventNoticeStackNativeFixture(count: 3, scheme: scheme)
            defer { fixture.close() }
            guard let bitmap = fixture.bitmap() else { expect(false, "原生栈位图可用"); continue }
            let scale = Double(bitmap.pixelsWide) / fixture.geometry.width
            let items = fixture.model.stackSnapshot.visible
            var titles: [NSColor] = [], tracks: [NSColor] = []
            for item in items {
                let top = item.positionY
                let height = fixture.heights["card.\(item.id.uuidString)"] ?? 0
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
        expect(fixture.geometry.queueHeight == 220, "队列实际视口最多 220pt")
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
            (fixture.heights["card.\(fixture.model.stackSnapshot.visible[0].id.uuidString)"] ?? 0)
            + (fixture.heights["queue-entry"] ?? 0) + 8
        fixture.settle()
        expect(fixture.model.stackSnapshot.visible.count == 1, "实测高度仅容纳一张完整卡片")
        fixture.clock.advance(5)
        expect(
            fixture.model.stackSnapshot.queued.first?.readingTime.remaining == saved, "回队列保存独立预算")
        fixture.availableHeight = 45
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
private final class EventNoticeStackNativeFixture {
    private static var preparedAccessibility = false
    private final class Measurements { var values: [String: Double] = [:] }
    let clock = ManualEventNoticeScheduler()
    let model: EventNoticeModel
    let navigation: SessionNavigationCoordinator
    let geometry = EventNoticeStackGeometry()
    let hosting: EventNoticeHostingView
    let window: EventNoticePanel
    private let measurements = Measurements()
    var heights: [String: Double] { measurements.values }
    var availableHeight: Double = 900

    init(
        count: Int, language: ClaudioAppLanguage = .english, scheme: ColorScheme = .light,
        width: Double = 440
    ) {
        _ = NSApplication.shared
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
        geometry.width = width
        model.setVisibleCapacity(0, measuredIDs: [])
        for _ in 0..<count {
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch,
                    processAncestors: [
                        HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)
                    ]))
        }
        let measurements = measurements
        hosting = EventNoticeHostingView(
            rootView: EventNoticeView(
                model: model, languageStore: ClaudioPreferences(previewLanguage: language),
                navigation: navigation, geometry: geometry,
                onMeasurements: { values in measurements.values.merge(values) { _, new in new } }))
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
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
            let stack = model.stackSnapshot
            let layout = EventNoticeStackLayout.resolve(
                cardHeights: stack.candidates.map { heights["card.\($0.id.uuidString)"] ?? 0 },
                totalCount: stack.totalCount, availableHeight: availableHeight,
                queueEntryHeight: heights["queue-entry"] ?? 44,
                queueExpanded: stack.isQueueExpanded,
                queueContentHeight: heights["queue-content"] ?? 220)
            model.setVisibleCapacity(
                layout.visibleCapacity,
                measuredIDs: Set(
                    stack.candidates.filter {
                        (heights["card.\($0.id.uuidString)"] ?? 0) > 0
                    }.map(\.id)))
            var top: Double = 0, positions: [UUID: Double] = [:]
            for item in model.stackSnapshot.visible {
                positions[item.id] = top
                top += (heights["card.\(item.id.uuidString)"] ?? 0) + 8
            }
            model.updateDisplayPositions(positions)
            if geometry.queueHeight != layout.queueHeight {
                geometry.queueHeight = layout.queueHeight
            }
            let exits =
                model.stackSnapshot.exiting.map {
                    $0.positionY + (heights["card.\($0.id.uuidString)"] ?? 0) + 6
                }.max() ?? 0
            window.setFrame(
                NSRect(x: 100, y: 80, width: geometry.width, height: max(1, layout.height, exits)),
                display: true)
        }
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
