import SwiftUI

/// Settings presentation only. The header stays visible while the single reading column scrolls.
package struct SettingsPageHeader: View {
    private let content: AnyView

    package init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    package var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) { content }
                .font(SettingsAppearance.pageTitle)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(.horizontal, 26)
            Divider()
        }
    }
}

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
