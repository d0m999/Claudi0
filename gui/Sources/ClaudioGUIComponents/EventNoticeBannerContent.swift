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
    private let onActivate: (@MainActor () -> Void)?
    private let isNavigationEnabled: Bool
    private let navigationHint: String
    private let onBodyFocusChange: @MainActor (Bool) -> Void
    @FocusState private var bodyFocused: Bool
    @ViewBuilder let actions: Actions

    package init(
        event: Event, title: String, subtitle: String, action: String,
        preferences: EventAnimationPreferences, resources: EventAnimationResources,
        reading: EventNoticeReadingTime, isVisible: Bool = true,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onActivate: (@MainActor () -> Void)? = nil, isNavigationEnabled: Bool = true,
        navigationHint: String = "",
        onBodyFocusChange: @escaping @MainActor (Bool) -> Void = { _ in },
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
        self.onActivate = onActivate
        self.isNavigationEnabled = isNavigationEnabled
        self.navigationHint = navigationHint
        self.onBodyFocusChange = onBodyFocusChange
        self.actions = actions()
    }

    package var body: some View {
        HStack(spacing: 10) {
            EventAnimationView(
                resources: resources, preferences: preferences, event: event, action: action,
                reading: reading, isVisible: isVisible, uptime: uptime)
            if let onActivate {
                Button(action: onActivate) { summary.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .disabled(!isNavigationEnabled)
                    .focused($bodyFocused)
                    .accessibilityIdentifier("event-notice.body")
                    .accessibilityHint(navigationHint)
                    .onChange(of: bodyFocused) { onBodyFocusChange($0) }
                    .onDisappear { onBodyFocusChange(false) }
            } else {
                summary
            }
            actions
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.body, design: .rounded).weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
