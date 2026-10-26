import AppKit
import SwiftUI

/// Settings-only palette and rhythm. Panel tokens retain their existing meaning.
package enum SettingsAppearance {
    package static let pageTitle: Font = .system(size: 17, weight: .semibold)
    package static let sectionGap: CGFloat = 20
    package static let informationGap: CGFloat = 12
    package static let controlRowHeight: CGFloat = 38
    package static let multilineControlRowHeight: CGFloat = 51
    package static let controlRowHorizontalPadding: CGFloat = 14
    package static let controlRowVerticalPadding: CGFloat = 7
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
        Color(nsColor: .windowBackgroundColor)
    }
    package static func cardSurface(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .underPageBackgroundColor)
    }
    package static func sidebar(_ scheme: ColorScheme) -> Color { .clear }
    package static func sidebarSelection(_ contrast: ColorSchemeContrast) -> Color { .accentColor }
    package static func text(_ scheme: ColorScheme) -> Color { Color(nsColor: .labelColor) }
    package static func secondaryText(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .secondaryLabelColor)
    }
    package static func accent(_ scheme: ColorScheme) -> Color { .accentColor }

    // Settings feedback reuses DESIGN.md's measured UI semantic palette: the light values are
    // darkened so the icon-only categories clear the non-text ≥3:1 floor.
    package static func success(_ scheme: ColorScheme) -> Color { ClaudioTheme.success(scheme) }
    package static func warning(_ scheme: ColorScheme) -> Color { ClaudioTheme.warning(scheme) }
    package static func error(_ scheme: ColorScheme) -> Color { ClaudioTheme.error(scheme) }
    package static func hairline(_ scheme: ColorScheme) -> Color { Color(nsColor: .separatorColor) }

    package static func horizontalPadding(compact: Bool) -> CGFloat { compact ? 26 : 32 }
    package static func eventPadding(compact _: Bool) -> CGFloat { 14 }

}

private struct SettingsAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Presentation context only; shared components keep their panel defaults elsewhere.
    package var usesSettingsAppearance: Bool {
        get { self[SettingsAppearanceEnvironmentKey.self] }
        set { self[SettingsAppearanceEnvironmentKey.self] = newValue }
    }
}
