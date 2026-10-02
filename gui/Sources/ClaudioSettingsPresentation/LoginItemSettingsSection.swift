import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

package enum SettingsPresentationAccessibilityID {
    package static let root = "settings.presentation.root"
    package static let general = "settings.presentation.general"
    package static let loginItemToggle = "settings.general.login-item.toggle"
}

/// The Login Item section rendered by the importable Settings root. All mutations and system
/// effects return through the session seam.
@MainActor
struct LoginItemSettingsSection: View {
    @ObservedObject private var session: SettingsPresentationSession

    init(session: SettingsPresentationSession) {
        self.session = session
    }

    var body: some View {
        let l10n = ClaudioL10n(language: session.state.language)
        let loginItemStatusText = SettingsPresentationAnnouncement.Meaning.loginItemStatus(
            session.state.loginItemRegistration
        ).localizedSentence(language: session.state.language)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.text(.settingsGeneralLoginItem.toggle))
                        .font(SettingsAppearance.font(.body))
                    Text(loginItemStatusText)
                        .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(l10n.text(.settingsGeneralLoginItem.toggle), isOn: enabledBinding)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!session.state.loginItemRegistration.canToggle)
                    .accessibilityHint(l10n.text(.settingsGeneralLoginItem.hint))
                    .accessibilityValue(loginItemStatusText)
                    .accessibilityIdentifier(SettingsPresentationAccessibilityID.loginItemToggle)
                    .soundPacksLayoutProbe(SettingsPresentationAccessibilityID.loginItemToggle)
            }.frame(minHeight: 61)
            Divider()
            HStack(spacing: 16) {
                Text(l10n.text(.settingsGeneralLoginItem.description))
                    .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(l10n.text(.settingsNativeRecheck)) { session.send(.refreshLoginItemState) }
                    .accessibilityIdentifier("settings.general.login-item.recheck")
            }.frame(minHeight: 48)

            if session.state.loginItemRegistration == .requiresApproval {
                Button(l10n.text(.settingsGeneralLoginItem.openSettings)) {
                    session.send(.performPlatformAction(.openLoginItemsSettings))
                }
                .accessibilityHint(l10n.text(.settingsGeneralLoginItem.openSettingsHint))
                .accessibilityIdentifier("settings.general.login-item.open-settings")
            }

            if let failure = session.state.loginItemFailure {
                VStack(alignment: .leading, spacing: 8) {
                    FailureRow(
                        message: SettingsPresentationAnnouncement.Meaning.loginItemFailure(
                            failure
                        ).localizedSentence(language: session.state.language)
                    )

                    Button(l10n.text(.commonRetry)) {
                        session.send(.retryLoginItemOperation)
                    }
                    .accessibilityIdentifier("settings.general.login-item.retry")
                }
            }

            if session.state.platformActionFailure == .openLoginItemsSettings {
                FailureRow(message: l10n.text(.settingsGeneralLoginItem.unavailable))
                    .accessibilityIdentifier("settings.general.login-item.settings-failure")
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { session.state.loginItemRegistration.isOn },
            set: { _ = session.send(.setLoginItemEnabled($0)) })
    }

}
