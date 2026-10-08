import AppKit
import ClaudioGUIComponents
import ClaudioLocalization
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
private final class TaskSurfaceProbe: ObservableObject {
    @Published var phase = "ready"
    var height: CGFloat = 0
    var width: CGFloat = 0
}

private struct PreviewButtonFixture: View {
    @ObservedObject var probe: TaskSurfaceProbe
    let stopLabel: String
    var body: some View {
        MotionPreviewButton(
            isPlaying: probe.phase != "ready", playLabel: "Preview", stopLabel: stopLabel,
            action: {}
        )
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { probe.width = proxy.size.width }
                    .onChange(of: proxy.size.width) { probe.width = $0 }
            }
        )
        .transaction {
            $0.animation = nil; $0.disablesAnimations = true
        }
    }
}

private struct TaskSurfaceFixture: View {
    @ObservedObject var probe: TaskSurfaceProbe
    var body: some View {
        AICueTaskSurface(expanded: probe.phase != "ready", stateKey: probe.phase) { _ in
            VStack(alignment: .leading, spacing: 12) {
                if probe.phase == "ready" {
                    Text("Generate").frame(height: 34)
                } else if probe.phase == "generating" {
                    Text("Generating").frame(height: 44)
                } else {
                    Text("Saved").font(.headline)
                    Text("3 candidates")
                    List { ForEach(0..<3) { Text("Candidate \($0)") } }.frame(height: 142)
                    Text("Attribution is updated on adoption.")
                    Text("Generate again").frame(height: 34)
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { probe.height = proxy.size.height }
                    .onChange(of: proxy.size.height) { probe.height = $0 }
            }
        )
        .transaction {
            $0.animation = nil; $0.disablesAnimations = true
        }
        .frame(width: 572)
    }
}

@MainActor
func runAICueTaskSurfaceSuites() {
    suite("Preview capsule reserves readable localized stop titles") {
        _ = NSApplication.shared
        let probe = TaskSurfaceProbe()
        let hosting = NSHostingView(
            rootView: PreviewButtonFixture(probe: probe, stopLabel: "Stop Preview"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func settle() {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }
        settle()
        let reserved = probe.width
        expect(reserved > 76, "English stop title receives more than the minimum 76pt")
        probe.phase = "playing"
        settle()
        expect(abs(probe.width - reserved) < 1, "playback does not move neighboring controls")
        hosting.rootView = PreviewButtonFixture(probe: probe, stopLabel: "停止试听")
        settle()
        expect(abs(probe.width - 76) < 1, "Chinese stop capsule retains the 76pt minimum")
        probe.phase = "ready"
        settle()
        expect(abs(probe.width - 76) < 1, "the Chinese row slot is stable when playback ends")
    }
    suite("AI task failure retains the unavailable service reason") {
        expect(
            aiCueFailureText(
                .generation(.provider(.serviceUnavailable)), providerProfileID: .elevenLabsGlobal,
                l10n: ClaudioL10n(language: .zhHans))
                == "生成服务暂时不可用。请稍后重新生成。",
            "Chinese failure card explains the service outage and recovery")
        expect(
            aiCueFailureText(
                .generation(.provider(.serviceUnavailable)), providerProfileID: .elevenLabsGlobal,
                l10n: ClaudioL10n(language: .english))
                == "The generation service is temporarily unavailable. Try generating again later.",
            "English failure card explains the service outage and recovery")
    }
    suite("AI task surface: mounted content measurement survives identity changes") {
        _ = NSApplication.shared
        let probe = TaskSurfaceProbe()
        let hosting = NSHostingView(rootView: TaskSurfaceFixture(probe: probe))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 572, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func settle() {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }
        settle()
        expect(abs(probe.height - 34) < 1, "idle surface retains its 34pt height")
        probe.phase = "generating"
        settle()
        expect(probe.height >= 96 && probe.height < 130, "task card follows measured task content")
        probe.phase = "results"
        settle()
        expect(
            probe.height >= 280,
            "saved tray exposes the entire candidate list and actions: \(probe.height)")
        probe.phase = "generating"
        probe.phase = "results"
        settle()
        expect(
            probe.height >= 280,
            "fast completion keeps the measured result geometry: \(probe.height)")
        probe.phase = "ready"
        settle()
        expect(abs(probe.height - 34) < 1, "reset restores the compact button")
    }
}
