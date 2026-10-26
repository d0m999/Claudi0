import AppKit
import ClaudioGUIComponents
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
private final class AnimatedTaskProbe: ObservableObject {
    @Published var phase = "ready"
    @Published var expanded = false
}

private struct AnimatedTaskFixture: View {
    @ObservedObject var probe: AnimatedTaskProbe
    let english: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(english ? "Sound Description" : "声音描述")
            AICueTaskSurface(expanded: probe.expanded, stateKey: probe.phase) { focus in
                VStack(alignment: .leading, spacing: probe.expanded ? 12 : 0) {
                    switch probe.phase {
                    case "generating":
                        Text(english ? "Generating…" : "正在生成…")
                        Button(english ? "Cancel Generation" : "取消生成") {}
                            .focused(focus, equals: .cancel)
                            .accessibilityIdentifier("animation.cancel")
                    case "saving":
                        ProgressView()
                        Text(english ? "Saving audio…" : "正在保存音频…")
                    case "results":
                        Text(english ? "New Audio Saved" : "新音频已保存")
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<3) { index in
                                Button("\(english ? "Candidate" : "候选") \(index + 1)") {}
                            }
                        }.focusable().focused(focus, equals: .results)
                            .accessibilityIdentifier("animation.results")
                        Text(english ? "Choose one to use for the current event." : "选择一条用于当前事件。")
                    case "pending":
                        Text(english ? "Audio Not Saved" : "音频尚未保存")
                        Text(
                            english
                                ? "Check disk space and folder permissions, then retry."
                                : "请检查磁盘空间及目录权限，然后重试。"
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        Button(english ? "Retry Saving" : "重试保存") {}
                            .focused(focus, equals: .retrySave)
                            .accessibilityIdentifier("animation.retry")
                    default:
                        if probe.phase == "failed" {
                            FailureRow(
                                message: english
                                    ? "The generation service is temporarily unavailable. Try generating again later."
                                    : "生成服务暂时不可用。请稍后重新生成。")
                        }
                        Button {
                            probe.phase = "generating"
                            probe.expanded = true
                        } label: {
                            Text(english ? "Generate" : "生成")
                                .frame(width: 124, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(probe.expanded ? .accentColor : .white)
                        .focused(focus, equals: .generate)
                        .accessibilityIdentifier("animation.generate")
                    }
                }
            }
            Spacer()
            Button(english ? "Close" : "关闭") {}
                .accessibilityIdentifier("animation.close")
        }
        .padding(24).frame(width: 620, height: 480, alignment: .topLeading)
        .environment(\.usesSettingsAppearance, true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Foreground fixture: the production surface retains its real animation transactions.
@MainActor
func runAICueTaskAnimationSuites() async {
    for english in [false, true] {
        for dark in [false, true] {
            for reduced in [false, true] {
                await suite("AI live task animation: en=\(english)/dark=\(dark)/reduced=\(reduced)")
                {
                    let probe = AnimatedTaskProbe()
                    let host = NSHostingView(
                        rootView: AnimatedTaskFixture(probe: probe, english: english)
                            // Use the existing SDK setter for the read-only public environment value.
                            .environment(\._accessibilityReduceMotion, reduced))
                    let window = RetainedSettingsWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    window.presentForUserRequest()
                    let ready = await settingsKeyboardWait {
                        window.isKeyWindow && host.bounds.width == 620
                            && settingsKeyboardWindowOrder().contains(window.windowNumber)
                            && settingsKeyboardAXElements(host).contains {
                                $0.accessibilityIdentifier?() == "animation.generate"
                            }
                    }
                    expect(
                        ready,
                        "The animated fixture is mounted in WindowServer: \(settingsKeyboardWindowState(window))"
                    )
                    guard ready else { return }
                    let reachable = await settingsKeyboardTabTo("animation.generate", in: window)
                    expect(
                        reachable, "The initial Generate control is ready for keyboard activation")
                    guard reachable else { return }
                    var frameIndex = 0
                    @MainActor func capture(_ phase: String) {
                        defer { frameIndex += 1 }
                        guard
                            let directory = ProcessInfo.processInfo.environment[
                                "CLAUDIO_AI_ANIMATION_CAPTURE_DIR"],
                            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                        else { return }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(
                            to:
                                URL(fileURLWithPath: directory).appendingPathComponent(
                                    "ai-\(english)-\(dark)-\(reduced)-\(frameIndex)-\(phase).png"))
                    }
                    for phase in [
                        "generating", "saving", "pending", "results", "ready", "failed", "ready",
                    ] {
                        if phase == "generating" {
                            settingsKeyboardPress(49, " ", in: window, queued: true)
                            let started = await settingsKeyboardWait { probe.phase == phase }
                            expect(started, "Space starts the actual Generate action")
                            guard started else { return }
                        } else {
                            probe.phase = phase
                            probe.expanded = phase != "ready"
                        }
                        for sample in 0..<16 {
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            host.layoutSubtreeIfNeeded()
                            expect(
                                window.isKeyWindow
                                    && host.bounds == NSRect(x: 0, y: 0, width: 620, height: 480),
                                "Animation retains window ownership and its outer layout")
                            capture("\(phase)-\(sample)")
                        }
                        if phase != "saving" {
                            expect(
                                (window.firstResponder as? NSView)?.isDescendant(of: host) == true,
                                "The new \(phase) task content retains a mounted focus target: \(settingsKeyboardWindowState(window))"
                            )
                        }
                    }
                    // Reverse the real spring before it has settled, then verify the final content.
                    for phase in ["generating", "ready", "results", "ready"] {
                        probe.phase = phase; probe.expanded = phase != "ready"
                        for sample in 0..<2 {
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            host.layoutSubtreeIfNeeded()
                            capture("rapid-\(phase)-\(sample)")
                        }
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    host.layoutSubtreeIfNeeded()
                    let elements = settingsKeyboardAXElements(host)
                    expect(
                        elements.contains { $0.accessibilityIdentifier?() == "animation.generate" },
                        "Rapid reversal ends with the current Generate action")
                    expect(
                        !elements.contains { $0.accessibilityIdentifier?() == "animation.cancel" },
                        "No outgoing task action remains after reversal")
                    expect(
                        (window.firstResponder as? NSView)?.isDescendant(of: host) == true,
                        "Rapid reversal leaves focus in the final mounted content")
                    capture("rapid-settled")
                }
            }
        }
    }
}
