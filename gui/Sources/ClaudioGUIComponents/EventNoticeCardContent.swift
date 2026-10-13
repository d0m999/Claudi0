import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// Only size-affecting rendered facts. Reading samples, motion, hover and positions are absent.
package struct EventNoticeCardContent: Equatable {
    package let recordID: UUID
    package let version: UInt64
    package let language: ClaudioAppLanguage
    package let title: String
    package let subtitle: String
    package let actionTitle: String
    package let feedback: ClaudioL10nKey?

    @MainActor
    init(
        item: EventNoticeBannerItem, language: ClaudioAppLanguage,
        navigation: SessionNavigationCoordinator, now: Date
    ) {
        recordID = item.record.id
        version = item.record.version
        self.language = language
        title = EventNoticeProjection.primaryLine(for: item.record, language: language)
        subtitle = EventNoticeProjection.secondaryLine(
            for: item.record, language: language, now: now)
        let result = navigation.result(for: item.record.action)
        feedback = EventNoticeProjection.navigationFeedbackKey(
            for: item.record, action: item.record.action, result: result)
        actionTitle =
            [.failed, .unavailable, .timedOut].contains(result) && item.record.isActionable
            ? ClaudioL10n(language: language).text(.commonRetry)
            : EventNoticeProjection.actionTitle(for: item.record, language: language)
    }
}
