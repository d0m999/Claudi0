import SwiftUI

/// Settings-only palette and rhythm. Panel tokens retain their existing meaning.
package enum SettingsAppearance {
    package static let pageTitle: Font = .system(size: 17, weight: .semibold)
    package static let sectionGap: CGFloat = 28
    package static let informationGap: CGFloat = 16
    package static let eventGap: CGFloat = 0
    package static let groupRadius: CGFloat = 10
    package static let readingWidth: CGFloat = 780
    package static let sidebarRowHeight: CGFloat = 32
    package static let sidebarGroupGap: CGFloat = 16

    package static func font(_ role: ClaudioTheme.FontRole) -> Font {
        switch role {
        case .productTitle: .system(size: 17, weight: .semibold)
        case .sectionTitle: .system(size: 13, weight: .semibold)
        case .body: .system(size: 13)
        case .secondary: .system(size: 12)
        case .caption: .system(size: 11)
        case .technical: .system(size: 11, design: .monospaced)
        }
    }

    package static func background(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x202022 : 0xFFFFFF)
    }

    package static func cardSurface(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x2D2D30 : 0xF5F5F7)
    }

    package static func sidebar(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x2B2B2E : 0xE9E9EC)
    }

    package static func sidebarSelection(_ contrast: ColorSchemeContrast) -> Color {
        color(contrast == .increased ? 0x0056B3 : 0x006FE6)
    }

    package static func text(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0xF0F0F2 : 0x202023)
    }

    package static func secondaryText(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0xAAAAB0 : 0x6E6E73)
    }

    package static func accent(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? 0x0A84FF : 0x007AFF)
    }

    package static func hairline(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : Color.black).opacity(scheme == .dark ? 0.085 : 0.075)
    }

    package static func horizontalPadding(compact: Bool) -> CGFloat { compact ? 26 : 32 }
    package static func eventPadding(compact _: Bool) -> CGFloat { 14 }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
