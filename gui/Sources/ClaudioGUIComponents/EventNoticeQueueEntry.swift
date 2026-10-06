import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
package struct EventNoticeQueueEntry: View {
    let snapshot: EventNoticeStackSnapshot
    let language: ClaudioAppLanguage
    let action: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    package var body: some View {
        let l10n = ClaudioL10n(language: language)
        Button(action: action) {
            HStack(spacing: 9) {
                HStack(spacing: 4) {
                    ForEach(snapshot.queued.prefix(3)) { item in
                        Circle().fill(ClaudioTheme.event(item.record.event, colorScheme))
                            .frame(width: 7, height: 7)
                    }
                }.accessibilityHidden(true)
                Text(
                    snapshot.isQueueExpanded
                        ? l10n.text(.eventNoticeQueueCollapse)
                        : l10n.format(.eventNoticeQueueWaiting, snapshot.queued.count)
                )
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(snapshot.queued.count.formatted()).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ClaudioTheme.clay(colorScheme).opacity(0.12), in: Capsule())
                    .accessibilityHidden(true)
            }
            .font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudioTheme.panel(colorScheme), in: RoundedRectangle(cornerRadius: 13))
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(ClaudioTheme.panel(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3))
                        }
                        .padding(.horizontal, 9).offset(y: -6).opacity(0.6)
                    RoundedRectangle(cornerRadius: 12).fill(ClaudioTheme.panel(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3))
                        }
                        .padding(.horizontal, 6).offset(y: -3).opacity(0.32)
                }.accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13).stroke(.secondary.opacity(0.3))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain).padding(.top, 4)
        .accessibilityValue(snapshot.isQueueExpanded ? l10n.text(.eventNoticeQueueCollapse) : "")
        .accessibilityIdentifier("event-notice.queue-toggle")
        .noticeHeight("queue-entry")
    }
}
