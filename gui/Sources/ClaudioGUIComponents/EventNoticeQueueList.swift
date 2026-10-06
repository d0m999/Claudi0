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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.queued.enumerated()), id: \.element.id) { index, item in
                    let motion = EventNoticeMotionPlan(
                        kind: .queueRow, startedAt: snapshot.queueOpenedAt, index: index)
                    TimelineView(
                        .animation(
                            minimumInterval: 1 / 60,
                            paused: reduceMotion || (motion.completesAt ?? 0) <= uptime())
                    ) { _ in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ClaudioTheme.event(item.record.event, colorScheme))
                                .frame(width: 4, height: 18).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    EventNoticeProjection.primaryLine(
                                        for: item.record, language: language))
                                Text(
                                    EventNoticeProjection.secondaryLine(
                                        for: item.record, language: language, now: now)
                                )
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ClaudioL10n(language: language).text(.eventNoticeQueueStatus))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption).padding(.vertical, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(motion.opacity(at: uptime(), reducedMotion: reduceMotion))
                        .offset(y: motion.offsetY(at: uptime(), reducedMotion: reduceMotion))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("event-notice.queued.\(item.id.uuidString)")
                    if index < snapshot.queued.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 2)
            .noticeHeight("queue-content")
        }
        .frame(height: height)
        .background(ClaudioTheme.panel(colorScheme), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.secondary.opacity(0.3)) }
        .accessibilityIdentifier("event-notice.queue")
    }
}
