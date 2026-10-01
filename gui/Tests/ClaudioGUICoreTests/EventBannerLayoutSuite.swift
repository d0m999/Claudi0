import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
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
