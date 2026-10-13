import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// One stack aggregates hover, keyboard and queue focus. Cards return stable display IDs while
/// all source actions remain version captured. The shared presentation collaborator owns measured geometry.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var navigation: SessionNavigationCoordinator
    @ObservedObject private var presentation: EventNoticeStackPresentation
    private let eventAnimations: EventAnimationResources
    @ObservedObject private var animationVisibility: EventAnimationVisibility
    private let onViewSource: @MainActor (EventNoticeAction) -> Void
    private let onNavigate: @MainActor (EventNoticeAction, UUID) -> Void
    private let onDismiss: @MainActor (UUID) -> Void
    private let onClose: @MainActor () -> Void
    private let onQueueInteraction: @MainActor () -> Void
    private let onMeasurements: @MainActor ([EventNoticeMeasurementToken: Double]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var queueFocused: Bool
    @State private var focusedCards: Set<UUID> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    package init(
        model: EventNoticeModel, languageStore: ClaudioPreferences,
        navigation: SessionNavigationCoordinator? = nil,
        eventAnimations: EventAnimationResources? = nil,
        animationVisibility: EventAnimationVisibility? = nil,
        presentation: EventNoticeStackPresentation? = nil,
        onViewSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onOpenSourceApplication: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onCopySessionID: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        onNavigate: (@MainActor (EventNoticeAction, UUID) -> Void)? = nil,
        onDismiss: (@MainActor (UUID) -> Void)? = nil,
        onQueueInteraction: (@MainActor () -> Void)? = nil,
        onMeasurements: @escaping @MainActor ([EventNoticeMeasurementToken: Double]) -> Void = {
            _ in
        },
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.languageStore = languageStore
        let navigation = navigation ?? SessionNavigationCoordinator(model: model)
        self.navigation = navigation
        self.eventAnimations = eventAnimations ?? EventAnimationResources()
        self.animationVisibility = animationVisibility ?? EventAnimationVisibility()
        let shared =
            presentation
            ?? EventNoticeStackPresentation(
                model: model, preferences: languageStore, navigation: navigation)
        self.presentation = shared
        if presentation == nil { shared.updateViewport(width: 440, availableHeight: 900) }
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
        let geometry = presentation.output
        TimelineView(.periodic(from: .now, by: 1)) { context in
            stack(snapshot: snapshot, geometry: geometry, now: context.date)
                .onChange(of: context.date) { _ in presentation.refreshContent() }
        }
        .onPreferenceChange(EventNoticeHeightPreference.self) { values in
            presentation.receiveMeasurements(values)
            onMeasurements(values)
        }
        .onAppear {
            model.setReducedMotion(reduceMotion)
            presentation.updateFontEnvironment(String(describing: dynamicTypeSize))
        }
        .onChange(of: dynamicTypeSize) {
            presentation.updateFontEnvironment(String(describing: $0))
        }
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

    private func stack(
        snapshot: EventNoticeStackSnapshot,
        geometry: EventNoticeStackPresentationOutput, now: Date
    ) -> some View {
        let cardAreaHeight =
            snapshot.visible.map {
                $0.positionY + (geometry.cardHeights[$0.id] ?? 0)
            }.max() ?? 0
        return VStack(spacing: EventNoticeStackLayout.spacing) {
            if !snapshot.visible.isEmpty {
                // Removal may precede the next measurement transaction. Keep each committed
                // position and its occupied space until the model installs the relocation plan.
                ZStack(alignment: .topLeading) {
                    ForEach(snapshot.visible) { item in
                        card(item, now: now, measuring: false)
                            .frame(height: geometry.cardHeights[item.id].map { CGFloat($0) })
                            .offset(y: item.positionY)
                    }
                }
                .frame(height: cardAreaHeight, alignment: .topLeading)
            }
            if !snapshot.queued.isEmpty {
                EventNoticeQueueEntry(
                    snapshot: snapshot, language: languageStore.language,
                    action: onQueueInteraction
                )
                .frame(height: geometry.queueEntryHeight > 0 ? geometry.queueEntryHeight : nil)
                .focused($queueFocused)
            }
            if geometry.showsCapacityHint {
                capacityHint(snapshot.capacityHintCount, language: languageStore.language)
            }
            if snapshot.isQueueExpanded, geometry.queueHeight > 0 {
                EventNoticeQueueList(
                    snapshot: snapshot, language: languageStore.language, now: now,
                    height: geometry.queueHeight, uptime: { model.presentationUptime }
                )
                .padding(.top, geometry.queueClearance)
            }
        }
        .overlay(alignment: .topLeading) {
            ForEach(snapshot.exiting.filter { geometry.retiredContent[$0.id] != nil }) { item in
                card(item, now: now, measuring: false)
                    .frame(height: geometry.cardHeights[item.id].map { CGFloat($0) })
                    .offset(y: item.positionY)
            }
        }
        .frame(width: geometry.width, alignment: .top)
        .background(alignment: .top) {
            // Tokens and all size-affecting text are captured at request creation. Never
            // attach a new token to content from an older native layout pass.
            VStack(spacing: 0) {
                ForEach(geometry.requests) { request in
                    measurement(request, now: now)
                        .frame(width: request.token.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .noticeHeight(request.token)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .hidden().disabled(true).allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .top)

    }

    private func card(
        _ item: EventNoticeBannerItem, now: Date, measuring: Bool,
        content: EventNoticeCardContent? = nil
    ) -> some View {
        EventNoticeCard(
            item: item, preferences: languageStore, navigation: navigation,
            resources: eventAnimations, isVisible: animationVisibility.isVisible,
            measuring: measuring, now: now, uptime: { model.presentationUptime },
            activate: { activate(item) }, dismiss: { onDismiss(item.id) },
            focusChanged: { focused in
                if focused { focusedCards.insert(item.id) } else { focusedCards.remove(item.id) }
                synchronizeFocus()
            }, renderedContent: content ?? presentation.output.retiredContent[item.id])
    }

    @ViewBuilder
    private func measurement(_ request: EventNoticeMeasurementRequest, now: Date) -> some View {
        switch request.token.role {
        case .card:
            if let item = request.card {
                card(item, now: now, measuring: true, content: request.content)
            }
        case .queueEntry:
            if let queue = request.queue {
                EventNoticeQueueEntry(snapshot: queue, language: request.language, action: {})
            }
        case .capacityHint:
            capacityHint(request.hintCount, language: request.language)
        case .queueContent:
            if let queue = request.queue {
                EventNoticeQueueContent(
                    snapshot: queue, language: request.language, now: request.capturedNow,
                    uptime: { model.presentationUptime }, measuring: true)
            }
        }
    }

    private func capacityHint(_ count: Int, language: ClaudioAppLanguage) -> some View {
        Text(ClaudioL10n(language: language).format(.eventNoticeCapacityHint, count))
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudioTheme.panel(colorScheme), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityIdentifier("event-notice.capacity-hint")
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
