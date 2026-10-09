import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
struct AppUpdateSettingsView: View {
    @ObservedObject var model: AppUpdateModel
    let language: ClaudioAppLanguage
    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }

    var body: some View {
        SettingsSectionCard(title: l10n.text(.appUpdateTitle)) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isPublicPreview {
                    Text(l10n.text(.appUpdatePublicPreview)).font(.headline)
                    Text(l10n.text(.appUpdatePreviewLimit)).foregroundStyle(.secondary)
                }
                if let status = statusText {
                    Text(status).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.about.update-status")
                }
                Button(l10n.text(.appUpdateCheck)) { model.checkForUpdates() }
                    .disabled(!model.canCheckForUpdates)
                    .accessibilityIdentifier("settings.about.check-updates")
                if case .unavailable = model.state {
                } else {
                    Toggle(
                        l10n.text(.appUpdateAutomatic),
                        isOn: Binding(
                            get: { model.automaticallyChecksForUpdates },
                            set: { model.setAutomaticallyChecksForUpdates($0) })
                    )
                    .accessibilityIdentifier("settings.about.automatic-updates")
                }
                if model.state == .failed || model.state == .unavailable(.configuration) {
                    Link(
                        l10n.text(.appUpdateRecovery),
                        destination:
                            URL(string: "https://d0m999.github.io/Claudi0/preview/")!)
                }
            }
        }
    }

    private var statusText: String? {
        switch model.state {
        case .idle: nil
        case .checking: l10n.text(.appUpdateChecking)
        case .available(let version): l10n.format(.appUpdateAvailable, version as NSString)
        case .upToDate: l10n.text(.appUpdateCurrent)
        case .failed: l10n.text(.appUpdateFailed)
        case .unavailable(.developmentBuild): l10n.text(.appUpdateDevelopment)
        case .unavailable(.moveToApplications): l10n.text(.appUpdateMove)
        case .unavailable(.configuration): l10n.text(.appUpdateConfiguration)
        }
    }
}
