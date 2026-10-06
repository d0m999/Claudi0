import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The same complete card is measured and presented. Veils cover the surface and decoration
/// only; content, controls and the reading track always keep their normal contrast.
@MainActor
package struct EventNoticeCard: View {
    let item: EventNoticeBannerItem
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var navigation: SessionNavigationCoordinator
    let resources: EventAnimationResources
    let isVisible: Bool
    let measuring: Bool
    let now: Date
    let uptime: @MainActor () -> TimeInterval
    let activate: @MainActor () -> Void
    let dismiss: @MainActor () -> Void
    let focusChanged: @MainActor (Bool) -> Void
    let retiredFeedback: ClaudioL10nKey?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: String?
    @State private var bodyHasFocus = false

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var result: SessionNavigationActionResult { navigation.result(for: item.record.action) }
    private var canActivate: Bool { item.record.isActionable && !navigation.isNavigating }
    private var feedbackKey: ClaudioL10nKey? {
        if item.phase == .exiting { return retiredFeedback }
        return EventNoticeProjection.navigationFeedbackKey(
            for: item.record, action: item.record.action, result: result)
    }
    private var actionTitle: String {
        let retry =
            item.phase == .exiting
            ? retiredFeedback.map {
                [
                    ClaudioL10nKey.eventNoticeOpenFailed, .eventNoticeOpenUnavailable,
                    .eventNoticeOpenTimeout,
                ].contains($0)
            } ?? false
            : [.failed, .unavailable, .timedOut].contains(result)
        if retry, item.record.isActionable {
            return l10n.text(.commonRetry)
        }
        return EventNoticeProjection.actionTitle(for: item.record, language: preferences.language)
    }

    package var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 60,
                paused: measuring || reduceMotion || !hasMotion(at: uptime()))
        ) { _ in
            let time = uptime()
            let spineTime = item.exit?.startedAt ?? time
            let entrance = item.entrance
            VStack(alignment: .leading, spacing: 10) {
                EventNoticeBannerContent(
                    event: item.record.event,
                    title: EventNoticeProjection.primaryLine(
                        for: item.record, language: preferences.language),
                    subtitle: EventNoticeProjection.secondaryLine(
                        for: item.record, language: preferences.language, now: now),
                    action: EventAnimationTimeline.action(
                        for: item.record.event, kind: item.record.kind),
                    preferences: preferences.eventAnimation, resources: resources,
                    reading: item.readingTime,
                    isVisible: isVisible && item.isInteractive && !measuring,
                    uptime: uptime, onActivate: activate, isNavigationEnabled: canActivate,
                    navigationHint: actionTitle,
                    bodyIdentifier: "event-notice.body.\(item.id.uuidString)",
                    decorationVeil: item.backgroundVeil,
                    onBodyFocusChange: { focused in
                        guard !measuring else { return }
                        bodyHasFocus = focused
                        focusChanged(focused || focusedControl != nil)
                    }
                ) {
                    if item.record.kind.isAttention {
                        Button(actionTitle, action: activate)
                            .buttonStyle(EventNoticeActionStyle(event: item.record.event))
                            .disabled(!canActivate)
                            .focused($focusedControl, equals: "open")
                            .accessibilityIdentifier(
                                "event-notice.open-source.\(item.id.uuidString)")
                    }
                    Button(l10n.text(.commonClose), systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .frame(minWidth: 28, minHeight: 28)
                        .focused($focusedControl, equals: "close")
                        .accessibilityIdentifier("event-notice.close.\(item.id.uuidString)")
                }
                if let key = feedbackKey {
                    Text(l10n.text(key)).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("event-notice.open-feedback.\(item.id.uuidString)")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ClaudioTheme.panelGradient(colorScheme)
                    .overlay { ClaudioTheme.panel(colorScheme).opacity(item.backgroundVeil) }
            }
            .overlay(alignment: .leading) {
                ClaudioTheme.event(item.record.event, colorScheme)
                    .frame(width: 4)
                    .scaleEffect(
                        x: 1,
                        y: measuring
                            ? 1
                            : entrance?.spineScale(at: spineTime, reducedMotion: reduceMotion) ?? 1,
                        anchor: .center
                    )
                    .opacity(
                        (1 - item.backgroundVeil)
                            * (measuring
                                ? 1
                                : entrance?.progress(
                                    at: spineTime, reducedMotion: reduceMotion, spine: true) ?? 1)
                    )
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                EventNoticeReadingTrack(
                    reading: item.readingTime, event: item.record.event, reduceMotion: reduceMotion,
                    uptime: uptime)
            }
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                    .strokeBorder(ClaudioTheme.text(colorScheme).opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .noticeHeight("card.\(item.id.uuidString)")
            .opacity(measuring ? 1 : opacity(at: time))
            .offset(y: measuring ? 0 : offset(at: time))
        }
        .allowsHitTesting(item.isInteractive && !measuring)
        .accessibilityHidden(!item.isInteractive || measuring)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            EventNoticeProjection.accessibilitySummary(
                for: item.record, language: preferences.language, now: now)
        )
        .accessibilityIdentifier("event-notice.capsule.\(item.id.uuidString)")
        .onChange(of: focusedControl) { _ in
            if !measuring { focusChanged(focusedControl != nil || bodyHasFocus) }
        }
        .onDisappear { if !measuring { focusChanged(false) } }
    }

    private func opacity(at time: TimeInterval) -> Double {
        if let exit = item.exit { return exit.opacity(at: time, reducedMotion: reduceMotion) }
        return item.entrance?.opacity(at: time, reducedMotion: reduceMotion) ?? 1
    }

    private func hasMotion(at time: TimeInterval) -> Bool {
        if let entrance = item.entrance,
            entrance.progress(at: time, reducedMotion: false, spine: true) < 1
        {
            return true
        }
        return (item.relocation?.completesAt ?? 0) > time || (item.exit?.completesAt ?? 0) > time
    }

    private func offset(at time: TimeInterval) -> Double {
        if let exit = item.exit { return exit.offsetY(at: time, reducedMotion: reduceMotion) }
        return (item.entrance?.offsetY(at: time, reducedMotion: reduceMotion) ?? 0)
            + (item.relocation?.offsetY(at: time, reducedMotion: reduceMotion) ?? 0)
    }
}
