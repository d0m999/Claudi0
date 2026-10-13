import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Shared natural content for the actual scrolling list and its token-bound measurement copy.
@MainActor
package struct EventNoticeQueueContent: View {
    let snapshot: EventNoticeStackSnapshot
    let language: ClaudioAppLanguage
    let now: Date
    let uptime: @MainActor () -> TimeInterval
    var measuring = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.queued.enumerated()), id: \.element.id) { index, item in
                let motion = EventNoticeMotionPlan(
                    kind: .queueRow, startedAt: snapshot.queueOpenedAt, index: index)
                TimelineView(
                    .animation(
                        minimumInterval: 1 / 60,
                        paused: measuring || reduceMotion || (motion.completesAt ?? 0) <= uptime())
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
                    .opacity(
                        measuring ? 1 : motion.opacity(at: uptime(), reducedMotion: reduceMotion)
                    )
                    .offset(
                        y: measuring ? 0 : motion.offsetY(at: uptime(), reducedMotion: reduceMotion)
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("event-notice.queued.\(item.id.uuidString)")
                if index < snapshot.queued.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
    }
}
