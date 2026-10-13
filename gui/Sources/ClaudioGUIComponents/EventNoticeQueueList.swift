import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
package struct EventNoticeQueueList: View {
    let snapshot: EventNoticeStackSnapshot
    let language: ClaudioAppLanguage
    let now: Date
    let height: Double
    let uptime: @MainActor () -> TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    package var body: some View {
        ScrollView {
            EventNoticeQueueContent(
                snapshot: snapshot, language: language, now: now, uptime: uptime)
        }
        .frame(height: height)
        .background(ClaudioTheme.panel(colorScheme), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.secondary.opacity(0.3)) }
        .accessibilityIdentifier("event-notice.queue")
    }
}
