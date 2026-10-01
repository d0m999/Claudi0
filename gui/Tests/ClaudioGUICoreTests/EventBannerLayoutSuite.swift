import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SwiftUI

@MainActor
func runEventBannerLayoutSuites() {
    suite("Event Banner：非激活 panel 仅在显式交互期间允许键盘焦点") {
        _ = NSApplication.shared
        let panel = EventNoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 75),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        expect(!panel.canBecomeKey && !panel.canBecomeMain, "自动展示没有键盘或主窗口资格")
        panel.allowsKeyboardInteraction = true
        expect(panel.canBecomeKey && !panel.canBecomeMain, "显式交互允许key，不成为main")
        panel.allowsKeyboardInteraction = false
        expect(!panel.canBecomeKey, "收起和隐私清空撤回资格")
        panel.close()
    }
    suite("Event Banner：快照不变时，实际彩色阅读轨遵守当前动态偏好") {
        _ = NSApplication.shared
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
        clock.advance(0.18)
        let preferences = ClaudioPreferences(previewLanguage: .english)
        let hosting = EventNoticeHostingView(
            rootView: EventNoticeView(model: model, languageStore: preferences))
        let height = EventNoticeView.preferredHeight(for: model.bannerSnapshot)
        let window = EventNoticePanel(
            contentRect: NSRect(x: 100, y: 80, width: 440, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrame(NSRect(x: 100, y: 80, width: 440, height: height), display: true)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let baseline = model.bannerSnapshot
        var publications = 0
        let subscription = model.$bannerSnapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        let full = eventBannerGreenTrackSpan(hosting, name: "track-normal-0s")
        expect(full > 300, "初始彩色轨真实可见，非灰色底轨：\(full)pt")
        expect(!baseline.pauseReasons.contains(.hover), "测试窗口未被指针悬停")
        expect(!window.isKeyWindow, "自动展示不取得键盘焦点")
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let threeQuarters = eventBannerGreenTrackSpan(hosting, name: "track-normal-1s")
        expect(
            abs(threeQuarters / full - (reduced ? 1 : 0.75)) < 0.06,
            "推进1秒遵守当前 Reduce Motion=\(reduced)：\(full)→\(threeQuarters)pt")
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let half = eventBannerGreenTrackSpan(hosting, name: "track-normal-2s")
        expect(
            abs(half / full - (reduced ? 1 : 0.5)) < 0.06,
            "推进2秒遵守当前 Reduce Motion=\(reduced)：\(full)→\(half)pt")
        expect(
            publications == 0 && model.bannerSnapshot == baseline,
            "持续绘制无需发布或改写提醒快照")
        model.setHovering(true)
        model.setKeyboardFocused(true)
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let paused = eventBannerGreenTrackSpan(hosting, name: "track-hover-and-focus-paused")
        expect(abs(paused - half) < 2, "悬停与聚焦期间实际填充保持剩余长度")
        model.setHovering(false)
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let focused = eventBannerGreenTrackSpan(hosting, name: "track-focus-still-paused")
        expect(abs(focused - half) < 2, "解除悬停后仍聚焦，实际填充继续暂停")
        model.setKeyboardFocused(false)
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let resumed = eventBannerGreenTrackSpan(hosting, name: "track-resumed-remaining")
        expect(
            abs(resumed / full - (reduced ? 1 : 0.25)) < 0.06,
            "全部暂停解除后沿用剩余预算，Reduce Motion=\(reduced)：\(resumed)pt")
    }
    suite("Event Banner：绘制组件在普通动态模式按4秒预算连续更新") {
        let clock = ManualEventNoticeScheduler()
        let fixture = EventBannerTrackFixture(
            reading: EventNoticeReadingTime(
                sampledUptime: 100, remaining: 4, isPaused: false, budget: 4),
            event: .stop, reduceMotion: false, clock: clock)
        defer { fixture.close() }
        let full = eventBannerGreenTrackSpan(fixture.hosting, name: "track-controlled-0s")
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let quarterElapsed = eventBannerGreenTrackSpan(
            fixture.hosting, name: "track-controlled-1s")
        clock.time += 1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let halfElapsed = eventBannerGreenTrackSpan(fixture.hosting, name: "track-controlled-2s")
        expect(full > 300, "受控普通动态模式的事件色填充真实可见")
        expect(abs(quarterElapsed / full - 0.75) < 0.03, "受控普通模式1秒约75%")
        expect(abs(halfElapsed / full - 0.5) < 0.03, "受控普通模式2秒约50%")
    }
    suite("Event Banner：阅读轨留白和 Reduce Motion 全长淡色遵循原型") {
        let clock = ManualEventNoticeScheduler()
        let full = EventBannerTrackFixture(
            reading: EventNoticeReadingTime(
                sampledUptime: 100, remaining: 4, isPaused: false, budget: 4),
            event: .stop, reduceMotion: false, clock: clock)
        defer { full.close() }
        let bitmap = full.bitmap()
        let scale = CGFloat(bitmap.pixelsWide) / 440
        let colored = eventBannerGreenTrackPixels(bitmap)
        if let left = colored.map(\.x).min(), let right = colored.map(\.x).max(),
            let top = colored.map(\.y).min(), let bottom = colored.map(\.y).max()
        {
            expect(abs(CGFloat(left) / scale - 17) <= 1, "彩色轨左留白17pt")
            expect(abs(440 - CGFloat(right + 1) / scale - 13) <= 1, "彩色轨右留白13pt")
            expect(
                abs((CGFloat(bitmap.pixelsHigh) - bottom - 1) / scale - 2) <= 0.5,
                "彩色轨底留白2pt")
            expect(abs((bottom - top + 1) / scale - 2) <= 0.5, "彩色轨高度2pt")
        } else {
            expect(false, "普通模式无法定位真实彩色轨")
        }

        for scheme in [ColorScheme.light, .dark] {
            for event in Event.allCases {
                let neutral = EventBannerTrackFixture(
                    reading: EventNoticeReadingTime(
                        sampledUptime: 100, remaining: 0, isPaused: false, budget: 4),
                    event: event, reduceMotion: false, clock: clock, scheme: scheme)
                let opaque = EventBannerTrackFixture(
                    reading: EventNoticeReadingTime(
                        sampledUptime: 100, remaining: 4, isPaused: false, budget: 4),
                    event: event, reduceMotion: false, clock: clock, scheme: scheme)
                let reduced = EventBannerTrackFixture(
                    reading: EventNoticeReadingTime(
                        sampledUptime: 100, remaining: 1, isPaused: false, budget: 4),
                    event: event, reduceMotion: true, clock: clock, scheme: scheme)
                let reference = EventBannerTrackFixture(reference: event, scheme: scheme)
                defer { neutral.close(); opaque.close(); reduced.close(); reference.close() }
                let neutralColor = neutral.trackColor(at: 0.75)
                let opaqueColor = opaque.trackColor(at: 0.75)
                let reducedColor = reduced.trackColor(at: 0.75)
                let eventColor = reference.trackColor(at: 0.5)
                expect(
                    eventBannerColorDistance(opaqueColor, eventColor) < 0.025,
                    "\(event) \(scheme)普通模式使用对应事件色填充")
                let expectedTrack = reference.trackColor(at: 1 / 6)
                expect(
                    eventBannerColorDistance(neutralColor, expectedTrack) < 0.025,
                    "\(event) \(scheme)底轨为正文色9%浅染")
                expect(
                    eventBannerColorDistance(reducedColor, neutralColor) > 0.03,
                    "Reduced Motion 的\(event) \(scheme)右端仍有事件色填充")
                expect(
                    eventBannerColorDistance(reducedColor, reduced.trackColor(at: 0.25)) < 0.01,
                    "Reduced Motion 的\(event) \(scheme)填充完整长度")
                expect(
                    eventBannerColorDistance(reducedColor, reference.trackColor(at: 5 / 6)) < 0.025,
                    "Reduced Motion 事件色不透明度30%")
                clock.time += 1
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
                expect(
                    eventBannerColorDistance(reducedColor, reduced.trackColor(at: 0.75)) < 0.01,
                    "Reduce Motion 推进时钟后填充保持静态")
                clock.time = 100
            }
        }
    }
    suite("Event Banner：英中浅深折叠胶囊、长文本和独立点击实际挂载") {
        _ = NSApplication.shared
        @MainActor func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for language in [ClaudioAppLanguage.zhHans, .english] {
                for kind in ["known", "unknown", "transient", "long"] {
                    let clock = ManualEventNoticeScheduler()
                    let model = EventNoticeModel(
                        receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
                        resolveSourceApplication: { _, action in
                            guard kind != "unknown" else { return nil }
                            return SourceApplicationTarget(
                                action: action,
                                process: HostProcessIdentity(
                                    pid: 42, startSeconds: 100, startMicroseconds: 1),
                                bundleIdentifier: "example.terminal",
                                applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
                                name: "Example Terminal")
                        })
                    let identity = HostProcessIdentity(
                        pid: 42, startSeconds: 100, startMicroseconds: 1)
                    _ = model.accept(
                        attentionNotice(
                            epoch: model.receiverEpoch,
                            native: kind == "transient" ? "Stop" : "PermissionRequest",
                            source: HostEventSource(
                                projectLabel: kind == "long"
                                    ? String(repeating: "项目Project", count: 14) : "claudi0",
                                sessionID: String(repeating: "S", count: 256)),
                            processAncestors: [identity],
                            occurredAt: Date(timeIntervalSinceNow: -120)))
                    var opens = 0
                    var details = 0
                    var closes = 0
                    let preferences = ClaudioPreferences(previewLanguage: language)
                    let hosting = EventNoticeHostingView(
                        rootView: EventNoticeView(
                            model: model, languageStore: preferences,
                            onViewSource: { _ in details += 1 },
                            onOpenSourceApplication: { _ in opens += 1 },
                            onClose: { closes += 1 }))
                    let height = EventNoticeView.preferredHeight(for: model.snapshot)
                    let width: CGFloat = kind == "long" ? 268 : 440
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = hosting
                    window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil); window.close() }
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    expect(
                        abs(hosting.frame.height - height) < 1
                            && abs(hosting.frame.width - width) < 1,
                        "受控胶囊尺寸 \(kind) \(language)")
                    let texts = descendants(hosting).compactMap { $0 as? NSTextField }
                    expect(
                        !texts.contains {
                            $0.stringValue.contains("SSSSSSSS") || $0.stringValue == "需要你"
                        }, "折叠不展示会话短ID或数量入口")
                    for text in texts {
                        let rect = text.convert(text.bounds, to: hosting)
                        expect(rect.minX >= -1 && rect.maxX <= width + 1, "长文本不撑出边界")
                    }
                    if let directory = ProcessInfo.processInfo.environment[
                        "CLAUDIO_ATTENTION_SCREENSHOT_DIR"],
                        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
                    {
                        let output = URL(fileURLWithPath: directory, isDirectory: true)
                        try? FileManager.default.createDirectory(
                            at: output, withIntermediateDirectories: true)
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(
                            to: output.appendingPathComponent(
                                "capsule-\(appearance.rawValue)-\(language.rawValue)-\(kind).png"))
                    }
                    @MainActor func click(_ point: NSPoint) {
                        let time = ProcessInfo.processInfo.systemUptime
                        let down = NSEvent.mouseEvent(
                            with: .leftMouseDown, location: point, modifierFlags: [],
                            timestamp: time, windowNumber: window.windowNumber, context: nil,
                            eventNumber: 1, clickCount: 1, pressure: 1)!
                        let up = NSEvent.mouseEvent(
                            with: .leftMouseUp, location: point, modifierFlags: [],
                            timestamp: time + 0.001, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
                        NSApplication.shared.postEvent(up, atStart: true)
                        window.sendEvent(down)
                        if let pending = NSApplication.shared.nextEvent(
                            matching: .leftMouseUp, until: .distantPast, inMode: .default,
                            dequeue: true)
                        {
                            window.sendEvent(pending)
                        }
                    }
                    let previousDetails = details
                    click(NSPoint(x: 100, y: height * 0.7))
                    expect(details == previousDetails, "静态正文不进入详情")
                    if kind == "transient" {
                        click(NSPoint(x: width - 28, y: height / 2))
                    } else {
                        click(NSPoint(x: width - (kind == "unknown" ? 90 : 76), y: height / 2))
                    }
                    expect(
                        kind == "transient"
                            ? closes == 1 : kind == "unknown" ? details == 1 : opens == 1,
                        "语义动作实际点击按能力分流：\(kind)")

                }
            }
        }
    }
}

/// Observe the mounted fill, not the clock calculation or private SwiftUI structure. The Stop
/// event's green is distinct from the panel and faint track; inspect only the bottom eight points.
@MainActor
private func eventBannerGreenTrackSpan(_ hosting: NSView, name: String) -> CGFloat {
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        expect(false, "原生阅读轨位图不可用")
        return 0
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    if let directory = ProcessInfo.processInfo.environment["CLAUDIO_ATTENTION_SCREENSHOT_DIR"] {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(
            to: output.appendingPathComponent("\(name).png"))
    }
    let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
    let pixels = eventBannerGreenTrackPixels(bitmap, scale: scale)
    let longest = Dictionary(grouping: pixels, by: \.y).values.map(\.count).max() ?? 0
    return CGFloat(longest) / scale
}

@MainActor
private func eventBannerGreenTrackPixels(
    _ bitmap: NSBitmapImageRep, scale: CGFloat? = nil
) -> [NSPoint] {
    let scale = scale ?? CGFloat(bitmap.pixelsWide) / 440
    var pixels: [NSPoint] = []
    for y in max(0, bitmap.pixelsHigh - Int(8 * scale))..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                continue
            }
            if color.alphaComponent > 0.5,
                color.greenComponent > color.redComponent + 0.025,
                color.greenComponent > color.blueComponent + 0.012
            {
                pixels.append(NSPoint(x: x, y: y))
            }
        }
    }
    return pixels
}

@MainActor
private final class EventBannerTrackFixture {
    let hosting: NSHostingView<AnyView>
    private let window: EventNoticePanel

    convenience init(
        reading: EventNoticeReadingTime, event: Event, reduceMotion: Bool,
        clock: ManualEventNoticeScheduler, scheme: ColorScheme = .light
    ) {
        self.init(
            content: AnyView(
                EventNoticeReadingTrack(
                    reading: reading, event: event, reduceMotion: reduceMotion,
                    uptime: { clock.time })), scheme: scheme)
    }

    /// Independent specification swatches share the native bitmap color pipeline. Cached images
    /// carry the display's ICC profile; raw NSColor channels are not equivalent to rendered sRGB.
    convenience init(reference event: Event, scheme: ColorScheme) {
        self.init(
            content: AnyView(
                HStack(spacing: 0) {
                    ClaudioTheme.text(scheme).opacity(0.09)
                    ClaudioTheme.event(event, scheme)
                    ZStack {
                        ClaudioTheme.text(scheme).opacity(0.09)
                        ClaudioTheme.event(event, scheme).opacity(0.3)
                    }
                }
                .frame(height: 2)
                .padding(.bottom, 2)), scheme: scheme)
    }

    private init(content: AnyView, scheme: ColorScheme) {
        hosting = NSHostingView(
            rootView: AnyView(
                content.frame(width: 440, height: 24, alignment: .bottom)
                    .background(scheme == .light ? Color.white : Color.black)
                    .preferredColorScheme(scheme)))
        if #available(macOS 13, *) { hosting.sizingOptions = [] }
        window = EventNoticePanel(
            contentRect: NSRect(x: 100, y: 80, width: 440, height: 24),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.setFrame(NSRect(x: 100, y: 80, width: 440, height: 24), display: true)
        window.orderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
    }

    func bitmap() -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            preconditionFailure("原生绘制组件位图不可用")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    func trackColor(at fraction: CGFloat) -> NSColor {
        let image = bitmap()
        let scale = CGFloat(image.pixelsWide) / 440
        // The rail is 2pt high and 2pt above the bottom; sample its vertical center.
        return image.colorAt(
            x: Int(CGFloat(image.pixelsWide) * fraction),
            y: image.pixelsHigh - Int(3 * scale))!.usingColorSpace(.sRGB)!
    }

    func close() { window.orderOut(nil); window.close() }
}

private func eventBannerColorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent)
        + abs(lhs.blueComponent - rhs.blueComponent)
}
