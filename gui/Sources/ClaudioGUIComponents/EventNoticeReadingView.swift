import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Shared reader for Panel and Diagnostics. Only the selected action is view state.
@MainActor
public struct EventNoticeReadingView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var preferences: ClaudioPreferences
    @ObservedObject private var navigation: SessionNavigationCoordinator
    @Binding private var selected: EventNoticeAction?
    private let openSource: @MainActor (EventNoticeAction) -> Void
    private let showsRecordMetadata: Bool
    private let copySession: @MainActor (EventNoticeAction) -> Bool
    @State private var copyResult: Bool?

    public init(
        model: EventNoticeModel, preferences: ClaudioPreferences,
        navigation: SessionNavigationCoordinator, selected: Binding<EventNoticeAction?>,
        openSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        copySession: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        showsRecordMetadata: Bool = false
    ) {
        self.model = model
        self.preferences = preferences
        self.navigation = navigation
        self._selected = selected
        self.openSource = openSource
        self.copySession = copySession
        self.showsRecordMetadata = showsRecordMetadata
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var selectedRecord: EventNoticeRecord? {
        guard let selected else { return nil }
        return model.readingSnapshot.records.first {
            $0.id == selected.id && $0.version == selected.version
        }
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if model.readingSnapshot.needsRefresh {
                    Button(l10n.text(.eventNoticeRefresh)) {
                        selected = nil
                        model.refreshReading()
                    }
                    .accessibilityIdentifier("event-notice.refresh")
                }
                if let record = selectedRecord {
                    Button(l10n.text(.eventNoticeBack), systemImage: "chevron.left") {
                        selected = nil
                    }
                    .accessibilityIdentifier("event-notice.back")
                    detail(record, now: context.date)
                } else {
                    if model.readingSnapshot.records.isEmpty {
                        Text(l10n.text(.eventNoticeEmpty)).foregroundStyle(.secondary)
                    }
                    ForEach(model.readingSnapshot.records) { record in
                        Button {
                            guard let action = record.action else { return }
                            selected = action
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    EventNoticeProjection.primaryLine(
                                        for: record, language: preferences.language))
                                Text(
                                    EventNoticeProjection.secondaryLine(
                                        for: record, language: preferences.language,
                                        now: context.date)
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if showsRecordMetadata,
                                    let date = EventNoticeProjection.occurredAtText(
                                        for: record, language: preferences.language)
                                {
                                    Text(date).font(.caption)
                                }
                                if showsRecordMetadata, let session = record.sessionID {
                                    Text(session).font(.caption).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        }
                        .buttonStyle(.plain).disabled(record.action == nil)
                        .accessibilityHint(record.isExpired ? l10n.text(.eventNoticeExpired) : "")
                        .accessibilityIdentifier("event-notice.recent.\(record.id.uuidString)")
                    }
                }
                if model.readingSnapshot.droppedCount > 0 {
                    Text(
                        l10n.format(.eventNoticeRecentOverflow, model.readingSnapshot.droppedCount)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text(l10n.text(.eventNoticeRecentDisclaimer)).font(.caption).foregroundStyle(
                    .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selected) { _ in copyResult = nil }
        .onChange(of: model.readingSnapshot.receiverEpoch) { _ in
            selected = nil; copyResult = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-notice.reader")
    }

    private func detail(_ record: EventNoticeRecord, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(EventNoticeProjection.primaryLine(for: record, language: preferences.language))
                .font(.headline).accessibilityAddTraits(.isHeader)
            if record.isExpired {
                Text(l10n.text(.eventNoticeExpired))
            } else {
                if record.isSuperseded { Text(l10n.text(.eventNoticeStale)) }
                if let source = record.source?.projectLabel { Text(source).textSelection(.enabled) }
                if let date = EventNoticeProjection.occurredAtText(
                    for: record, language: preferences.language)
                {
                    Text(date).accessibilityIdentifier("event-notice.occurred-at")
                }
                if let age = EventNoticeProjection.age(
                    for: record, language: preferences.language, now: now, long: true)
                {
                    Text(age)
                }
                if let session = record.sessionID {
                    Text(session).font(.system(.caption, design: .monospaced)).textSelection(
                        .enabled)
                    Button(l10n.text(.eventNoticeCopySession)) {
                        guard let action = record.action else { return }
                        copyResult = copySession(action)
                    }
                    .disabled(!record.isActionable)
                    .accessibilityIdentifier("event-notice.copy-session")
                }
                if record.sourceApplication != nil {
                    Button(l10n.text(.eventNoticeOpenSource)) {
                        if let action = record.action { openSource(action) }
                    }
                    .disabled(!record.isActionable || navigation.applicationResult == .started)
                    .accessibilityIdentifier("event-notice.reader.open-source")
                }
                if navigation.action == record.action {
                    switch navigation.applicationResult {
                    case .failed: Text(l10n.text(.eventNoticeOpenFailed))
                    case .unavailable: Text(l10n.text(.eventNoticeOpenUnavailable))
                    case .timedOut: Text(l10n.text(.eventNoticeOpenTimeout))
                    case .started: Text(l10n.text(.eventNoticeOpenStarted))
                    case .idle, .opened, .cancelled: EmptyView()
                    }
                }
                if let copyResult, record.isActionable {
                    Text(l10n.text(copyResult ? .eventNoticeCopied : .eventNoticeCopyFailed))
                        .accessibilityIdentifier("event-notice.copy-result")
                }
                Button(l10n.text(.eventNoticeRemove), systemImage: "minus.circle") {
                    if let action = record.action { _ = model.remove(action) }
                    selected = nil
                }
                .frame(minHeight: 28).disabled(!record.isActionable)
                .accessibilityIdentifier("event-notice.remove")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-notice.detail")
    }
}
