import SwiftUI

private struct SettingsSuppressesAutomaticContentFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Sidebar selection and history restoration let the shell consume the shared request.
    package var settingsSuppressesAutomaticContentFocus: Bool {
        get { self[SettingsSuppressesAutomaticContentFocusKey.self] }
        set { self[SettingsSuppressesAutomaticContentFocusKey.self] = newValue }
    }
}
