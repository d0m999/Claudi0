import SwiftUI

package struct EventNoticeHeightPreference: PreferenceKey {
    package static let defaultValue: [String: Double] = [:]
    package static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    package func noticeHeight(_ key: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: EventNoticeHeightPreference.self, value: [key: geometry.size.height])
            }
        }
    }
}
