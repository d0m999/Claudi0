import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// Shared renderer for Settings and the real banner. Its clock is always supplied by the
/// existing reading budget; a view task sleeps only until the next declared frame boundary.
@MainActor
public struct EventAnimationView: View {
    @ObservedObject private var resources: EventAnimationResources
    private let preferences: EventAnimationPreferences
    private let event: Event
    private let action: String
    private let reading: EventNoticeReadingTime
    private let isVisible: Bool
    private let size: CGFloat
    private let uptime: @MainActor () -> TimeInterval
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sampledUptime: TimeInterval = 0

    public init(
        resources: EventAnimationResources, preferences: EventAnimationPreferences,
        event: Event, action: String, reading: EventNoticeReadingTime,
        isVisible: Bool = true, size: CGFloat = 32,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.resources = resources
        self.preferences = preferences
        self.event = event
        self.action = action
        self.reading = reading
        self.isVisible = isVisible
        self.size = size
        self.uptime = uptime
    }

    private var style: EventAnimationStyle { preferences.effectiveStyle }
    private var dark: Bool { colorScheme == .dark }
    private var staticExpression: Bool {
        reduceMotion || preferences.usesStaticExpression || action == "idle"
    }

    private struct PlaybackRequest: Equatable {
        let style: EventAnimationStyle
        let action: String
        let dark: Bool
        let reading: EventNoticeReadingTime
        let isVisible: Bool
        let staticExpression: Bool
        let resourceRevision: UInt64
    }

    public var body: some View {
        Group {
            if let frames = resources.loaded(style, dark: dark),
                let timeline = frames.manifest.animations[action],
                let image = frames.image(
                    action: action,
                    frame: timeline.frame(
                        at: reading.animationElapsedMs(
                            at: max(reading.sampledUptime, sampledUptime)),
                        staticExpression: staticExpression
                    ).index)
            {
                Image(decorative: image, scale: 2, orientation: .up)
                    .resizable().interpolation(.none).frame(width: size, height: size)
            } else {
                ClaudioEventGlyph(event: event, size: size == 32 ? 25 : size)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true).allowsHitTesting(false)
        .task(id: "\(style.rawValue)-\(dark)") { await resources.load(style, dark: dark) }
        .task(
            id: PlaybackRequest(
                style: style, action: action, dark: dark, reading: reading, isVisible: isVisible,
                staticExpression: staticExpression, resourceRevision: resources.revision)
        ) {
            guard isVisible else { return }
            while !Task.isCancelled {
                let now = uptime()
                sampledUptime = now
                guard !staticExpression, !reading.isPaused,
                    let frames = resources.loaded(style, dark: dark),
                    let timeline = frames.manifest.animations[action]
                else { return }
                let elapsed = reading.animationElapsedMs(at: now)
                guard elapsed < reading.budget * 1_000,
                    let next = timeline.frame(at: elapsed).nextBoundaryMs
                else { return }
                let delay = min(next - elapsed, reading.budget * 1_000 - elapsed)
                do { try await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000)) } catch {
                    return
                }
            }
        }
    }
}
