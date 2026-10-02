import SwiftUI

/// Settings-only typography and accent. Panel status capsules keep their own design contract.
package struct SettingsStatusCapsule: View {
    private let text: String
    private let isEmphasized: Bool
    @Environment(\.colorScheme) private var colorScheme

    package init(_ text: String, isEmphasized: Bool = false) {
        self.text = text
        self.isEmphasized = isEmphasized
    }

    package var body: some View {
        Text(text)
            .font(SettingsAppearance.font(.caption))
            .foregroundStyle(
                isEmphasized
                    ? SettingsAppearance.accent(colorScheme)
                    : SettingsAppearance.secondaryText(colorScheme)
            )
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                Capsule().fill(
                    isEmphasized
                        ? SettingsAppearance.accent(colorScheme).opacity(0.12)
                        : SettingsAppearance.hairline(colorScheme)))
    }
}
