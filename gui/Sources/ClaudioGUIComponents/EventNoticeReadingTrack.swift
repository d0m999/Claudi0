import ClaudioCore
import ClaudioGUICore
import Foundation
import SwiftUI

/// Draws the model's reading sample without owning or resetting its deadline.
@MainActor
package struct EventNoticeReadingTrack: View {
    private let reading: EventNoticeReadingTime
    private let event: Event
    private let reduceMotion: Bool
    private let uptime: @MainActor () -> TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    package init(
        reading: EventNoticeReadingTime, event: Event, reduceMotion: Bool,
        uptime: @escaping @MainActor () -> TimeInterval
    ) {
        self.reading = reading
        self.event = event
        self.reduceMotion = reduceMotion
        self.uptime = uptime
    }

    package var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || reading.isPaused))
        { _ in
            let fraction = reduceMotion ? 1 : reading.fraction(at: uptime())
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ClaudioTheme.text(colorScheme).opacity(0.09)
                    ClaudioTheme.event(event, colorScheme).frame(
                        width: geometry.size.width * fraction
                    )
                    .opacity(reduceMotion ? 0.3 : 1)
                }
            }
            .frame(height: 2)
            .clipShape(Capsule())
            .padding(.leading, 17)
            .padding(.trailing, 13)
            .padding(.bottom, 2)
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
