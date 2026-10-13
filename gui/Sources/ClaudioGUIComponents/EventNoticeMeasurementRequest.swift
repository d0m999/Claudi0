import ClaudioGUICore
import ClaudioLocalization
import Foundation

package struct EventNoticeMeasurementRequest: Identifiable, Equatable {
    package var id: EventNoticeMeasurementToken { token }
    package let token: EventNoticeMeasurementToken
    package let language: ClaudioAppLanguage
    package let card: EventNoticeBannerItem?
    package let content: EventNoticeCardContent?
    package let queue: EventNoticeStackSnapshot?
    package let hintCount: Int
    package let capturedNow: Date
    package let queueContentIdentity: [String]

    /// Snapshot motion and reading samples must not cause another measurement.
    func hasSameContent(as other: Self) -> Bool {
        token.role == other.token.role && language == other.language && content == other.content
            && hintCount == other.hintCount && queue?.queued.count == other.queue?.queued.count
            && queueContentIdentity == other.queueContentIdentity
            && queue?.queued.prefix(3).map(\.record.event)
                == other.queue?.queued.prefix(3).map(\.record.event)
    }
}
