import SwiftUI

package struct EventNoticeHeightPreference: PreferenceKey {
    package static let defaultValue: [EventNoticeMeasurementToken: Double] = [:]
    package static func reduce(
        value: inout [EventNoticeMeasurementToken: Double],
        nextValue: () -> [EventNoticeMeasurementToken: Double]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    package func noticeHeight(_ key: EventNoticeMeasurementToken) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: EventNoticeHeightPreference.self, value: [key: geometry.size.height])
            }
        }
    }
}
