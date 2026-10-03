import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The same content geometry and character are mounted by the production banner and preview.
@MainActor
package struct EventNoticeBannerContent<Actions: View>: View {
    let event: Event
    let title: String
    let subtitle: String
    let action: String
    let preferences: EventAnimationPreferences
    let resources: EventAnimationResources
    let reading: EventNoticeReadingTime
    var isVisible = true
    var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ViewBuilder let actions: Actions

    package init(
        event: Event, title: String, subtitle: String, action: String,
        preferences: EventAnimationPreferences, resources: EventAnimationResources,
        reading: EventNoticeReadingTime, isVisible: Bool = true,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        @ViewBuilder actions: () -> Actions
    ) {
        self.event = event
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.preferences = preferences
        self.resources = resources
        self.reading = reading
        self.isVisible = isVisible
        self.uptime = uptime
        self.actions = actions()
    }

    package var body: some View {
        HStack(spacing: 10) {
            EventAnimationView(
                resources: resources, preferences: preferences, event: event, action: action,
                reading: reading, isVisible: isVisible, uptime: uptime)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.body, design: .rounded).weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            actions
        }
    }
}
