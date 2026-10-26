import ClaudioGUIComponents
import SwiftUI

/// A persistent forward entry. The session or destination callback owns navigation.
@MainActor
struct SettingsNavigationRow: View {
    let title: String
    let identifier: String
    let action: @MainActor () -> Void

    var body: some View {
        SettingsSectionCard(padding: 0) {
            EventAnimationActionButton(title: title, identifier: identifier, action: action) {
                HStack(spacing: SettingsAppearance.informationGap) {
                    Text(title)
                        .font(SettingsAppearance.font(.body))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(SettingsAppearance.font(.body))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                .frame(minHeight: SettingsAppearance.controlRowHeight)
                .contentShape(Rectangle())
            }
        }
    }
}
