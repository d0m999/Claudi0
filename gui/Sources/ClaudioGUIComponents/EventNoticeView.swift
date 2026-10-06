import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// One stack aggregates hover, keyboard and queue focus. Cards return stable display IDs while
/// all source actions remain version captured. The retained native controller owns geometry.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var navigation: SessionNavigationCoordinator
    @ObservedObject private var geometry: EventNoticeStackGeometry
    private let eventAnimations: EventAnimationResources
    @ObservedObject private var animationVisibility: EventAnimationVisibility
    private let onViewSource: @MainActor (EventNoticeAction) -> Void
    private let onNavigate: @MainActor (EventNoticeAction, UUID) -> Void
    private let onDismiss: @MainActor (UUID) -> Void
    private let onClose: @MainActor () -> Void
    private let onQueueInteraction: @MainActor () -> Void
    private let onMeasurements: @MainActor ([String: Double]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var queueFocused: Bool
    @State private var focusedCards: Set<UUID> = []
    // Only the last painted caption key, for the short inert retirement frame. Navigation
    // results remain solely owned by the coordinator. This inert render snapshot contains no
    // source contents and cannot drive navigation.
    @State private var paintedFeedback: [UUID: ClaudioL10nKey] = [:]

    public init(
        model: EventNoticeModel, languageStore: ClaudioPreferences,
        navigation: SessionNavigationCoordinator? = nil,
        eventAnimations: EventAnimationResources? = nil,
        animationVisibility: EventAnimationVisibility? = nil,
        geometry: EventNoticeStackGeometry? = nil,
        onViewSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onOpenSourceApplication: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onCopySessionID: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        onNavigate: (@MainActor (EventNoticeAction, UUID) -> Void)? = nil,
        onDismiss: (@MainActor (UUID) -> Void)? = nil,
        onQueueInteraction: (@MainActor () -> Void)? = nil,
        onMeasurements: @escaping @MainActor ([String: Double]) -> Void = { _ in },
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.languageStore = languageStore
        self.navigation = navigation ?? SessionNavigationCoordinator(model: model)
        self.eventAnimations = eventAnimations ?? EventAnimationResources()
        self.animationVisibility = animationVisibility ?? EventAnimationVisibility()
        self.geometry = geometry ?? EventNoticeStackGeometry()
        self.onViewSource = onViewSource
        self.onNavigate = onNavigate ?? { action, _ in onOpenSourceApplication(action) }
        self.onDismiss = onDismiss ?? { model.dismissBanner(id: $0) }
        self.onClose = onClose ?? { model.dismissStack() }
        self.onQueueInteraction =
            onQueueInteraction ?? {
                if model.stackSnapshot.visible.isEmpty {
                    if let action = model.stackSnapshot.queued.first?.record.action {
                        onViewSource(action)
                    }
                } else {
                    model.setQueueExpanded(!model.stackSnapshot.isQueueExpanded)
                }
            }
        self.onMeasurements = onMeasurements
    }

    /// Kept for older single-card harness callers. Production uses complete measured heights.
    public static func preferredHeight(
        for snapshot: EventNoticeModelSnapshot, navigation: SessionNavigationCoordinator? = nil
    ) -> CGFloat {
        let base: CGFloat = snapshot.current?.kind.isAttention == true ? 75 : 67
        guard let record = snapshot.current else { return base }
        return base
            + (EventNoticeProjection.navigationFeedbackKey(
                for: record, action: record.action,
                result: navigation?.result(for: record.action) ?? .idle)
                == nil ? 0 : 55)
    }

    public var body: some View {
        let snapshot = model.stackSnapshot
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: EventNoticeStackLayout.spacing) {
                if !snapshot.visible.isEmpty || !snapshot.exiting.isEmpty {
                    VStack(spacing: EventNoticeStackLayout.spacing) {
                        ForEach(snapshot.visible) { item in
                            card(item, now: context.date, measuring: false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        ForEach(snapshot.exiting) { item in
                            card(item, now: context.date, measuring: false)
                                .offset(y: item.positionY)
                        }
                    }
                }
                if !snapshot.queued.isEmpty {
                    EventNoticeQueueEntry(
                        snapshot: snapshot, language: languageStore.language,
                        action: onQueueInteraction
                    )
                    .focused($queueFocused)
                }
                if snapshot.capacityHintCount > 0 {
                    Text(
                        ClaudioL10n(language: languageStore.language).format(
                            .eventNoticeCapacityHint, snapshot.capacityHintCount)
                    )
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        ClaudioTheme.panel(colorScheme), in: RoundedRectangle(cornerRadius: 13)
                    )
                    .noticeHeight("capacity-hint")
                    .accessibilityIdentifier("event-notice.capacity-hint")
                }
                if snapshot.isQueueExpanded, geometry.queueHeight > 0 {
                    EventNoticeQueueList(
                        snapshot: snapshot, language: languageStore.language, now: context.date,
                        height: geometry.queueHeight, uptime: { model.presentationUptime })
                }
            }
            .frame(width: geometry.width, alignment: .top)
            .background(alignment: .top) {
                // Measure the full FIFO prefix before admitting it to a small screen. Hidden
                // measurement copies have no focus, hit testing or accessibility eligibility.
                VStack(spacing: 0) {
                    ForEach(snapshot.candidates) { item in
                        card(item, now: context.date, measuring: true)
                    }
                    EventNoticeQueueEntry(
                        snapshot: snapshot, language: languageStore.language, action: {})
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onPreferenceChange(EventNoticeHeightPreference.self, perform: onMeasurements)
        .onAppear {
            model.setReducedMotion(reduceMotion)
            rememberPaintedFeedback(model.stackSnapshot)
        }
        .onChange(of: snapshot) { rememberPaintedFeedback($0) }
        .onChange(of: navigation.feedback) { _ in rememberPaintedFeedback(model.stackSnapshot) }
        .onChange(of: reduceMotion) { model.setReducedMotion($0) }
        .onHover { model.setHovering($0) }
        .onChange(of: queueFocused) { _ in synchronizeFocus() }
        .onChange(of: snapshot.visible.map(\.id)) { ids in
            focusedCards.formIntersection(Set(ids))
            synchronizeFocus()
        }
        .onDisappear {
            focusedCards.removeAll()
            model.setHovering(false)
            model.setKeyboardFocused(false)
        }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ClaudioL10n(language: languageStore.language).text(.eventNoticeStack))
        .accessibilityIdentifier("event-notice.stack")
        .accessibilityHidden(
            snapshot.visible.isEmpty && snapshot.queued.isEmpty && snapshot.capacityHintCount == 0
        )
    }

    private func card(_ item: EventNoticeBannerItem, now: Date, measuring: Bool) -> some View {
        EventNoticeCard(
            item: item, preferences: languageStore, navigation: navigation,
            resources: eventAnimations, isVisible: animationVisibility.isVisible,
            measuring: measuring, now: now, uptime: { model.presentationUptime },
            activate: { activate(item) }, dismiss: { onDismiss(item.id) },
            focusChanged: { focused in
                if focused { focusedCards.insert(item.id) } else { focusedCards.remove(item.id) }
                synchronizeFocus()
            }, retiredFeedback: paintedFeedback[item.id])
    }

    private func rememberPaintedFeedback(_ snapshot: EventNoticeStackSnapshot) {
        let retained = Set((snapshot.visible + snapshot.exiting).map(\.id))
        var updated = paintedFeedback.filter { retained.contains($0.key) }
        for item in snapshot.visible {
            updated[item.id] = EventNoticeProjection.navigationFeedbackKey(
                for: item.record, action: item.record.action,
                result: navigation.result(for: item.record.action))
        }
        if updated != paintedFeedback { paintedFeedback = updated }
    }

    private func synchronizeFocus() {
        model.setKeyboardFocused(!focusedCards.isEmpty || queueFocused)
    }

    private func activate(_ item: EventNoticeBannerItem) {
        guard item.isInteractive, !navigation.isNavigating,
            let action = item.record.action, model.isCurrent(action)
        else { return }
        if item.record.sourceApplication != nil {
            onNavigate(action, item.id)
        } else {
            onViewSource(action)
        }
    }
}
