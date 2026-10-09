import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
struct PanelAppUpdateReminder: View {
    @ObservedObject var model: AppUpdateModel
    let language: ClaudioAppLanguage

    var body: some View {
        if case .available(let version) = model.state {
            Button {
                model.checkForUpdates()
            } label: {
                Label(
                    ClaudioL10n(language: language).format(
                        .appUpdateAvailable, version as NSString),
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canCheckForUpdates)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .accessibilityIdentifier("panel.update-available")
        }
    }
}
