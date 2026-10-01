import SwiftUI

/// Settings-only palette and rhythm. Panel tokens retain their existing meaning.
package enum SettingsAppearance {
    package static let pageTitle: Font = .system(size: 26, weight: .semibold, design: .rounded)
    package static let sectionGap: CGFloat = 36
    package static let informationGap: CGFloat = 24
    package static let eventGap: CGFloat = 12

    package static func background(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x1A1815 : 0xFAF8F4)
    }

    package static func cardSurface(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x1C1A17 : 0xFFFFFF)
    }

    package static func eventPadding(compact: Bool) -> CGFloat { compact ? 14 : 16 }
    package static func columnGap(compact: Bool) -> CGFloat { compact ? 20 : 26 }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
