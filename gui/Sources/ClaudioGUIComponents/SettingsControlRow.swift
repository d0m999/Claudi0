import SwiftUI

/// A Settings label and its trailing native control. Callers retain bindings, focus and actions.
package struct SettingsControlRow: View {
    private let title: String
    private let subtitle: String?
    private let control: AnyView

    package init<Control: View>(
        title: String, subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = AnyView(control())
    }

    package var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SettingsAppearance.font(.body))
                    .accessibilityHidden(true)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsAppearance.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            control
                .labelsHidden()
                .nativeMenuControl()
        }
        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: subtitle == nil
                ? SettingsAppearance.controlRowHeight
                : SettingsAppearance.multilineControlRowHeight)
    }
}
