import ClaudioGUICore
import SwiftUI

/// Production and fixture hosts mount the same native shell and the same destination content.
@MainActor
package struct SettingsRootView: NSViewControllerRepresentable {
    package let session: SettingsPresentationSession
    package init(session: SettingsPresentationSession) { self.session = session }
    package func makeNSViewController(context: Context) -> SettingsNativeShellController {
        SettingsNativeShellController(session: session)
    }
    package func updateNSViewController(_: SettingsNativeShellController, context: Context) {}
}
