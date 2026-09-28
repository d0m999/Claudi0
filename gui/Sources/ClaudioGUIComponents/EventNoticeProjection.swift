import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// Single owner of the capsule/list text projection. Visible text and accessibility text are
/// generated here together so they can never drift into two hand-made copies, and so the
/// session label is localized at presentation time instead of arriving pre-rendered over IPC.
public enum EventNoticeProjection {
    public static func primaryLine(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        let host = record.host?.displayName ?? l10n.text(.eventNoticeUnknownSource)
        let event: String
        if record.isExpired { return l10n.text(.eventNoticeExpired) }
        switch record.kind {
        case .permission: event = l10n.text(.eventNoticePermission)
        case .needsInput: event = l10n.text(.eventNoticeNeedsInput)
        case .review: event = l10n.text(.eventNoticeReview)
        case .transient:
            if record.reason == .questionIntent {
                event = l10n.text(.eventNoticeDemandQuestionIntent)
            } else {
                let key: ClaudioL10nKey
                switch record.event {
                case .taskStart: key = .eventNoticeDemandTaskStart
                case .stop: key = .eventNoticeDemandStop
                case .subagentStop: key = .eventNoticeDemandSubagentStop
                case .stopFailure: key = .eventNoticeDemandInterrupted
                case .notification: key = .eventNoticeInformational
                }
                event = l10n.text(key)
            }
        case .interrupted: event = l10n.text(.eventNoticeDemandInterrupted)
        }
        return language == .english ? "\(host) \(event)" : "\(host)\(event)"
    }

    public static func secondaryLine(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage,
        now: Date = Date()
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        guard !record.isExpired else { return "" }
        var components: [String] = []
        if record.provenance == .developmentCodexRollout {
            components.append(l10n.text(.eventNoticeDevelopmentObservation))
        }
        if let project = record.source?.projectLabel { components.append(project) }
        if let age = age(for: record, language: language, now: now) { components.append(age) }
        if record.isSuperseded { components.append(l10n.text(.eventNoticeStale)) }
        return components.joined(separator: " · ")
    }

    public static func age(
        for record: EventNoticeRecord, language: ClaudioAppLanguage,
        now: Date = Date(), long: Bool = false
    ) -> String? {
        guard !record.isExpired, let date = record.occurredAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds.isFinite else { return nil }
        let l10n = ClaudioL10n(language: language)
        if seconds < 60 {
            return l10n.text(long ? .eventNoticeRelativeJustNow : .eventNoticeAgeLessMinute)
        }
        let divisor: Double
        let key: ClaudioL10nKey
        if seconds < 3600 {
            divisor = 60;
            key =
                long
                ? (seconds < 120 ? .eventNoticeRelativeMinute : .eventNoticeRelativeMinutes)
                : .eventNoticeAgeMinutes
        } else if seconds < 86400 {
            divisor = 3600;
            key =
                long
                ? (seconds < 7200 ? .eventNoticeRelativeHour : .eventNoticeRelativeHours)
                : .eventNoticeAgeHours
        } else {
            divisor = 86400;
            key =
                long
                ? (seconds < 172800 ? .eventNoticeRelativeDay : .eventNoticeRelativeDays)
                : .eventNoticeAgeDays
        }
        return l10n.format(key, Int64(min(Double(Int64.max / 2), floor(seconds / divisor))))
    }

    public static func actionTitle(for record: EventNoticeRecord, language: ClaudioAppLanguage)
        -> String
    {
        let l10n = ClaudioL10n(language: language)
        guard record.sourceApplication != nil else { return l10n.text(.eventNoticeViewSource) }
        switch record.kind {
        case .permission: return l10n.text(.eventNoticeActPermission)
        case .needsInput: return l10n.text(.eventNoticeActNeedsInput)
        case .interrupted, .review: return l10n.text(.eventNoticeActReview)
        case .transient: return l10n.text(.eventNoticeOpenSource)
        }
    }

    /// An adapter-supplied trusted label wins; otherwise the default short label is projected
    /// and localized here from the stable session ID prefix.
    public static func sessionLabel(
        for source: HostEventSource,
        language: ClaudioAppLanguage
    ) -> String? {
        if let explicit = source.sessionLabel { return explicit }
        guard let sessionID = source.sessionID else { return nil }
        return ClaudioL10n(language: language).format(
            .eventNoticeSessionShort, String(sessionID.prefix(8)))
    }

    public static func occurredAtText(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage
    ) -> String? {
        guard !record.isExpired, let occurredAt = record.occurredAt else { return nil }
        let locale = Locale(identifier: language.rawValue)
        return occurredAt.formatted(
            Date.FormatStyle(date: .numeric, time: .standard).locale(locale))
    }

    public static func accessibilitySummary(
        for record: EventNoticeRecord?,
        language: ClaudioAppLanguage,
        now: Date = Date()
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        guard let record else { return l10n.text(.eventNoticeUnknownSource) }
        return [
            primaryLine(for: record, language: language),
            secondaryLine(for: record, language: language, now: now),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: language == .english ? ", " : "，")
    }

    /// A collapsed ordinary-progress banner announces what just happened. Attention banners and
    /// every interactive container retain the established Needs You label.
    public static func accessibilityLabel(
        for snapshot: EventNoticeModelSnapshot,
        language: ClaudioAppLanguage,
        now: Date = Date()
    ) -> String {
        if !snapshot.isExpanded, snapshot.current?.kind == .transient {
            return accessibilitySummary(for: snapshot.current, language: language, now: now)
        }
        return ClaudioL10n(language: language).text(.eventNoticeRecent)
    }
}
