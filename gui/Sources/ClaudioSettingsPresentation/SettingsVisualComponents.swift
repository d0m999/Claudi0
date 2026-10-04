import ClaudioGUIComponents
import SwiftUI

#if DEBUG
private struct SettingsReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Controlled visual-environment seam. Production leaves this nil and follows AppKit;
    /// deterministic render and snapshot hosts may inject the same platform fact explicitly.
    package var settingsReduceTransparencyOverride: Bool? {
        get { self[SettingsReduceTransparencyOverrideKey.self] }
        set { self[SettingsReduceTransparencyOverrideKey.self] = newValue }
    }
}
#endif

/// One shared native Settings surface. It keeps the approved 10 pt group radius and strengthens
/// its boundary under Increase Contrast without replacing the system control background.
struct SettingsSectionCard: View {
    private let content: AnyView
    private let padding: CGFloat
    private let title: String?
    private let description: String?

    init<Content: View>(
        title: String? = nil, description: String? = nil,
        padding: CGFloat = 16, @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.title = title
        self.description = description
        self.content = AnyView(content())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(SettingsAppearance.font(.sectionTitle))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
            }
            if let description {
                Text(description).font(SettingsAppearance.font(.secondary)).foregroundStyle(
                    .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
            }
            content.modifier(SettingsSectionSurface(padding: padding))
        }
    }
}

extension View {
    func settingsSectionSurface(padding: CGFloat = 16) -> some View {
        SettingsSectionCard(padding: padding) { self }
    }
}
