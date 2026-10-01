import SwiftUI

/// Shared functional-group surface for Settings and its embedded sound editor.
package struct SettingsSectionSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    private let padding: CGFloat

    // Retain the existing host override label; this surface is opaque in both modes.
    package init(padding: CGFloat = 16, reduceTransparencyOverride _: Bool? = nil) {
        self.padding = padding
    }

    package func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsAppearance.cardSurface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .strokeBorder(
                        colorSchemeContrast == .increased
                            ? ClaudioTheme.secondaryText(colorScheme).opacity(0.38)
                            : ClaudioTheme.hairline(colorScheme),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
            }
    }
}
