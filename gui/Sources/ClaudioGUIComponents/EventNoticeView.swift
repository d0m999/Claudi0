import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Snapshots and versioned actions are the only source of notice state in this view.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var navigation: SessionNavigationCoordinator
    private let onViewSource: @MainActor (EventNoticeAction) -> Void
    private let onOpenSourceApplication: @MainActor (EventNoticeAction) -> Void
    private let onCopySessionID: @MainActor (EventNoticeAction) -> Bool
    private let onClose: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyFeedback: EventNoticeAction?
    @State private var copySucceeded = false
    @State private var hovering = false
    @FocusState private var focusedControl: String?

    public init(
        model: EventNoticeModel,
        languageStore: ClaudioPreferences,
        navigation: SessionNavigationCoordinator? = nil,
        onViewSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onOpenSourceApplication: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onCopySessionID: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        _model = ObservedObject(wrappedValue: model)
        _languageStore = ObservedObject(wrappedValue: languageStore)
        _navigation = ObservedObject(
            wrappedValue: navigation ?? SessionNavigationCoordinator(model: model))
        self.onViewSource = onViewSource
        self.onOpenSourceApplication = onOpenSourceApplication
        self.onCopySessionID = onCopySessionID
        self.onClose = onClose
    }

    public static func preferredHeight(for snapshot: EventNoticeModelSnapshot) -> CGFloat {
        if snapshot.isDetail { return 360 }
        if snapshot.isExpanded {
            return CGFloat(min(5, max(1, snapshot.attentionReminders.count))) * 54 + 92
                + (snapshot.needsRefresh ? 32 : 0) + (snapshot.droppedCount > 0 ? 28 : 0)
        }
        return snapshot.current?.kind.isAttention == true ? 75 : 67
    }

    public var body: some View {
        let snapshot = model.snapshot
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.isExpanded {
                    header(snapshot)
                    if snapshot.isDetail, let record = snapshot.current {
                        detail(record, now: context.date)
                    } else {
                        list(snapshot, now: context.date)
                    }
                } else if let record = snapshot.current {
                    capsule(record, now: context.date)
                }
            }
            .padding(snapshot.isExpanded ? 12 : 0)
            .frame(
                idealWidth: 440, maxWidth: .infinity,
                idealHeight: Self.preferredHeight(for: snapshot), maxHeight: .infinity,
                alignment: snapshot.isExpanded ? .topLeading : .center
            )
            .background(ClaudioTheme.panelGradient(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                    .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                if !snapshot.isExpanded, let reading = snapshot.readingTime,
                    let event = snapshot.current?.event
                {
                    readingTrack(reading, event: event)
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
        .onAppear { model.setReducedMotion(reduceMotion) }
        .onChange(of: reduceMotion) { model.setReducedMotion($0) }
        .onHover {
            hovering = $0; model.setHovering($0)
        }
        .onChange(of: focusedControl) { model.setKeyboardFocused($0 != nil) }
        .onExitCommand {
            if model.snapshot.isDetail { model.closeDetail() } else { onClose() }
        }
        .onChange(of: snapshot.current?.action) { action in
            if copyFeedback != action { copyFeedback = nil }
        }
        .onChange(of: snapshot.current?.isActionable) { actionable in
            if actionable != true { copyFeedback = nil }
        }
    }

    private func capsule(_ record: EventNoticeRecord, now: Date) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(ClaudioTheme.event(record.event, colorScheme))
                .opacity(record.kind.isAttention ? 1 : 0.32)
                .frame(width: 4).accessibilityHidden(true)
            HStack(spacing: 8) {
                sourceButton(record, now: now)
                if record.kind.isAttention {
                    actionButton(record)
                } else {
                    closeButton(revealed: hovering || focusedControl == "close")
                }
            }
            .padding(.leading, 12).padding(.trailing, 14)
        }
    }

    private func readingTrack(_ reading: EventNoticeReadingTime, event: Event) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || reading.isPaused))
        { _ in
            GeometryReader { geometry in
                let fraction = reading.fraction(
                    at: reduceMotion ? reading.sampledUptime : ProcessInfo.processInfo.systemUptime)
                ZStack(alignment: .leading) {
                    ClaudioTheme.event(event, colorScheme).opacity(0.12)
                    ClaudioTheme.event(event, colorScheme)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func header(_ snapshot: EventNoticeModelSnapshot) -> some View {
        HStack(spacing: 8) {
            if snapshot.isDetail {
                Button {
                    model.closeDetail()
                } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: "back")
                .accessibilityLabel(l10n.text(.eventNoticeBack))
                .accessibilityIdentifier("event-notice.back")
            }
            Text(l10n.text(.eventNoticeRecent))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            Text(String(model.badgeCount)).monospacedDigit()
                .font(.system(size: 11, weight: .medium, design: .rounded))
            closeButton()
        }
    }

    private func closeButton(revealed: Bool = true) -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .opacity(revealed ? 1 : 0)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: "close")
        .accessibilityLabel(l10n.text(.commonClose))
        .accessibilityIdentifier("event-notice.close")
    }

    private func list(_ snapshot: EventNoticeModelSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.needsRefresh {
                Button(
                    snapshot.pendingCount > 0
                        ? l10n.format(.eventNoticeNewNotices, Int64(snapshot.pendingCount))
                        : l10n.text(.eventNoticeRefresh)
                ) { model.refreshAttentionReminders() }
                .buttonStyle(.bordered).controlSize(.small)
                .frame(minHeight: 28)
                .focused($focusedControl, equals: "refresh")
                .accessibilityIdentifier("event-notice.refresh-recent")
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if snapshot.attentionReminders.isEmpty {
                        Text(l10n.text(.eventNoticeEmpty))
                            .font(.system(size: 12, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .accessibilityIdentifier("event-notice.empty")
                    }
                    ForEach(snapshot.attentionReminders) { record in
                        HStack(spacing: 8) {
                            sourceButton(record, now: now)
                            actionButton(record)
                        }
                        .frame(minHeight: 54)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: CGFloat(min(5, max(1, snapshot.attentionReminders.count))) * 54
            )
            .accessibilityIdentifier("event-notice.recent-list")
            Text(l10n.text(.eventNoticeRecentDisclaimer))
                .font(.system(size: 10, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(ClaudioTheme.secondaryText(colorScheme))
            if snapshot.droppedCount > 0 {
                Text(l10n.text(.eventNoticeRecentOverflow))
                    .font(.system(size: 10, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("event-notice.recent-overflow")
            }
        }
    }

    private func sourceButton(_ record: EventNoticeRecord, now: Date) -> some View {
        Button {
            if let action = record.action { onViewSource(action) }
        } label: {
            summary(record, now: now).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!record.isActionable)
        .focused($focusedControl, equals: "source-\(record.id)")
        .accessibilityIdentifier("event-notice.recent.\(record.id.uuidString)")
    }

    private func actionButton(_ record: EventNoticeRecord, detail: Bool = false) -> some View {
        Button {
            guard let action = record.action else { return }
            if record.sourceApplication != nil {
                onOpenSourceApplication(action)
            } else {
                onViewSource(action)
            }
        } label: {
            Text(
                detail
                    ? l10n.text(.eventNoticeOpenSource)
                    : EventNoticeProjection.actionTitle(
                        for: record, language: languageStore.language)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(EventNoticeActionStyle(event: record.event))
        .disabled(!record.isActionable || navigation.applicationResult == .started)
        .focused($focusedControl, equals: "open-\(record.id)")
        .accessibilityHint(
            record.sourceApplication.map { l10n.format(.eventNoticeOpenHint, $0.name) }
                ?? l10n.text(.eventNoticeViewSource)
        )
        .accessibilityIdentifier("event-notice.open-source.\(record.id.uuidString)")
    }

    private func summary(_ record: EventNoticeRecord, now: Date) -> some View {
        HStack(spacing: 8) {
            ClaudioEventGlyph(event: record.event, size: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    EventNoticeProjection.primaryLine(for: record, language: languageStore.language)
                )
                .font(
                    .system(
                        size: 12, weight: record.kind.isAttention ? .semibold : .regular,
                        design: .rounded)
                )
                .foregroundStyle(ClaudioTheme.text(colorScheme))
                .lineLimit(1)
                let secondary = EventNoticeProjection.secondaryLine(
                    for: record, language: languageStore.language, now: now)
                if !secondary.isEmpty {
                    Text(secondary).font(.system(size: 11, design: .rounded))
                        .foregroundStyle(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            EventNoticeProjection.accessibilitySummary(
                for: record, language: languageStore.language, now: now))
    }

    private func detail(_ record: EventNoticeRecord, now: Date) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    EventNoticeProjection.primaryLine(for: record, language: languageStore.language)
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                if record.isExpired {
                    Text(l10n.text(.eventNoticeExpired))
                } else {
                    if let project = record.source?.projectLabel { Text(project) }
                    if record.source?.isParentSession == true {
                        Text(l10n.text(.eventNoticeParentSession))
                    }
                    if record.source?.completeness != .complete {
                        Text(l10n.text(.eventNoticeMissingSource))
                    }
                    if record.kind == .review { Text(l10n.text(.eventNoticeUnknownReason)) }
                    if let time = EventNoticeProjection.occurredAtText(
                        for: record, language: languageStore.language)
                    {
                        let age =
                            EventNoticeProjection.age(
                                for: record, language: languageStore.language, now: now, long: true)
                            ?? ""
                        Text(l10n.text(.eventNoticeOccurredAt) + " · " + time + " · " + age)
                            .accessibilityIdentifier("event-notice.occurred-at")
                    }
                    if let app = record.sourceApplication {
                        Text(l10n.text(.eventNoticeSourceApp) + " · " + app.name)
                        actionButton(record, detail: true)
                    } else {
                        Text(l10n.text(.eventNoticeOpenUnavailable))
                    }
                    if navigation.action == record.action, record.isActionable,
                        let feedback = applicationFeedback
                    {
                        Text(feedback).accessibilityIdentifier("event-notice.open-result")
                    }
                    if let sessionID = record.sessionID {
                        Text(l10n.text(.eventNoticeSessionID))
                        Text(sessionID).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("event-notice.session-id")
                    }
                    if !record.isActionable { Text(l10n.text(.eventNoticeStale)) }
                    if let action = record.action, record.sessionID != nil {
                        Button(l10n.text(.eventNoticeCopySession)) {
                            copySucceeded = onCopySessionID(action)
                            copyFeedback = action
                        }
                        .buttonStyle(.bordered).frame(minHeight: 28)
                        .disabled(!record.isActionable)
                        .focused($focusedControl, equals: "copy")
                        .accessibilityIdentifier("event-notice.copy-session")
                    }
                    if record.isActionable, copyFeedback == record.action, copyFeedback != nil {
                        Text(l10n.text(copySucceeded ? .eventNoticeCopied : .eventNoticeCopyFailed))
                            .accessibilityIdentifier("event-notice.copy-result")
                    }
                    if record.kind.isAttention { removeButton(record) }
                }
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(ClaudioTheme.text(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("event-notice.detail")
    }

    private var applicationFeedback: String? {
        switch navigation.applicationResult {
        case .started: return l10n.text(.eventNoticeOpenStarted)
        case .failed: return l10n.text(.eventNoticeOpenFailed)
        case .unavailable: return l10n.text(.eventNoticeOpenUnavailable)
        case .timedOut: return l10n.text(.eventNoticeOpenTimeout)
        case .idle, .opened, .cancelled: return nil
        }
    }

    private func removeButton(_ record: EventNoticeRecord) -> some View {
        Button {
            if let action = record.action { _ = model.remove(action) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "minus.circle")
                Text(l10n.text(.eventNoticeRemove))
            }
            .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!record.isActionable)
        .focused($focusedControl, equals: "remove")
        .accessibilityLabel(l10n.text(.eventNoticeRemove))
        .accessibilityHint(
            EventNoticeProjection.accessibilitySummary(
                for: record, language: languageStore.language)
        )
        .accessibilityIdentifier("event-notice.remove.\(record.id.uuidString)")
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
}
