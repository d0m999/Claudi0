import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The banner is a static summary with explicit actions. Reading lives in the menu panel.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var navigation: SessionNavigationCoordinator
    private let eventAnimations: EventAnimationResources
    @ObservedObject private var animationVisibility: EventAnimationVisibility
    private let onViewSource: @MainActor (EventNoticeAction) -> Void
    private let onOpenSourceApplication: @MainActor (EventNoticeAction) -> Void
    private let onClose: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: String?

    public init(
        model: EventNoticeModel, languageStore: ClaudioPreferences,
        navigation: SessionNavigationCoordinator? = nil,
        eventAnimations: EventAnimationResources? = nil,
        animationVisibility: EventAnimationVisibility? = nil,
        onViewSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onOpenSourceApplication: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onCopySessionID: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.languageStore = languageStore
        self.navigation = navigation ?? SessionNavigationCoordinator(model: model)
        self.eventAnimations = eventAnimations ?? EventAnimationResources()
        self.animationVisibility = animationVisibility ?? EventAnimationVisibility()
        self.onViewSource = onViewSource
        self.onOpenSourceApplication = onOpenSourceApplication
        self.onClose = onClose
    }

    public static func preferredHeight(
        for snapshot: EventNoticeModelSnapshot, navigation: SessionNavigationCoordinator? = nil
    ) -> CGFloat {
        let base: CGFloat = snapshot.current?.kind.isAttention == true ? 75 : 67
        guard let record = snapshot.current else { return base }
        let hasFeedback =
            !record.isActionable
            || (navigation?.action == record.action
                && [.started, .failed, .unavailable, .timedOut].contains(
                    navigation?.applicationResult ?? .idle))
        return base + (record.kind.isAttention && hasFeedback ? 55 : 0)
    }

    public var body: some View {
        let snapshot = model.bannerSnapshot
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let record = snapshot.current {
                VStack(alignment: .leading, spacing: 10) {
                    EventNoticeBannerContent(
                        event: record.event,
                        title: EventNoticeProjection.primaryLine(
                            for: record, language: languageStore.language),
                        subtitle: EventNoticeProjection.secondaryLine(
                            for: record, language: languageStore.language, now: context.date),
                        action: EventAnimationTimeline.action(for: record.event, kind: record.kind),
                        preferences: languageStore.eventAnimation, resources: eventAnimations,
                        reading: snapshot.readingTime
                            ?? EventNoticeReadingTime(
                                sampledUptime: model.presentationUptime, remaining: 0,
                                isPaused: true, budget: 4),
                        isVisible: animationVisibility.isVisible
                            && (snapshot.phase == .entering || snapshot.phase == .visible),
                        uptime: { model.presentationUptime }
                    ) {
                        if record.kind.isAttention {
                            Button(actionTitle(record)) {
                                guard let action = record.action else { return }
                                if record.sourceApplication != nil {
                                    onOpenSourceApplication(action)
                                } else {
                                    onViewSource(action)
                                }
                            }
                            .buttonStyle(EventNoticeActionStyle(event: record.event))
                            .disabled(
                                !record.isActionable || navigation.applicationResult == .started
                            )
                            .focused($focusedControl, equals: "open")
                            .accessibilityIdentifier(
                                "event-notice.open-source.\(record.id.uuidString)")
                        }
                        Button(l10n.text(.commonClose), systemImage: "xmark", action: onClose)
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .frame(minWidth: 28, minHeight: 28)
                            .focused($focusedControl, equals: "close")
                            .accessibilityIdentifier("event-notice.close")
                    }
                    if record.kind.isAttention, let feedback = feedback(record) {
                        Text(feedback).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("event-notice.open-feedback")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(ClaudioTheme.panelGradient(colorScheme))
                .overlay(alignment: .bottom) {
                    if let reading = snapshot.readingTime {
                        EventNoticeReadingTrack(
                            reading: reading, event: record.event, reduceMotion: reduceMotion,
                            uptime: { model.presentationUptime })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    EventNoticeProjection.accessibilityLabel(
                        for: snapshot, language: languageStore.language, now: context.date)
                )
                .accessibilityIdentifier("event-notice.capsule")
            }
        }
        .onAppear { model.setReducedMotion(reduceMotion) }
        .onChange(of: reduceMotion) { model.setReducedMotion($0) }
        .onHover { model.setHovering($0) }
        .onChange(of: focusedControl) { model.setKeyboardFocused($0 != nil) }
        .onDisappear {
            model.setHovering(false); model.setKeyboardFocused(false)
        }
        .onExitCommand(perform: onClose)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private func feedback(_ record: EventNoticeRecord) -> String? {
        guard record.isActionable else {
            return l10n.text(record.isExpired ? .eventNoticeExpired : .eventNoticeStale)
                + " " + l10n.text(.eventNoticeRetryAtNeedsYou)
        }
        guard navigation.action == record.action else { return nil }
        switch navigation.applicationResult {
        case .started: return l10n.text(.eventNoticeOpenStarted)
        case .failed: return l10n.text(.eventNoticeOpenFailed)
        case .unavailable: return l10n.text(.eventNoticeOpenUnavailable)
        case .timedOut: return l10n.text(.eventNoticeOpenTimeout)
        case .idle, .opened, .cancelled: return nil
        }
    }

    private func actionTitle(_ record: EventNoticeRecord) -> String {
        if record.isActionable, navigation.action == record.action,
            [.failed, .unavailable, .timedOut].contains(navigation.applicationResult)
        {
            return l10n.text(.commonRetry)
        }
        return EventNoticeProjection.actionTitle(for: record, language: languageStore.language)
    }

}
