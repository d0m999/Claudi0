import ClaudioCore
import SwiftUI

/// Event color describes the action's context. The label keeps the normal body text contrast.
public struct EventNoticeActionStyle: ButtonStyle {
    public static let fillOpacity = 0.12
    public static let interactionOpacity = 0.15
    let event: Event
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    public init(event: Event) { self.event = event }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(ClaudioTheme.text(colorScheme))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                ClaudioTheme.event(event, colorScheme)
                    .opacity(
                        configuration.isPressed || hovering
                            ? Self.interactionOpacity : Self.fillOpacity)
            )
            // A stable panel base keeps the event border above 3:1 even at the dark
            // gradient's elevated end. The event tint remains 12% / 15% in both themes.
            .background(ClaudioTheme.panel(colorScheme))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(ClaudioTheme.event(event, colorScheme), lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}
