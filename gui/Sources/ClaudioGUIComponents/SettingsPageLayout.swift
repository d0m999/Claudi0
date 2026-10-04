import SwiftUI

private struct SettingsReadingColumn: ViewModifier {
    @Environment(\.settingsUsesCompactLayout) private var compact

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SettingsAppearance.horizontalPadding(compact: compact))
            .padding(.top, 27)
            .padding(.bottom, 46)
            .frame(maxWidth: SettingsAppearance.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    package func settingsReadingColumn() -> some View { modifier(SettingsReadingColumn()) }
}
