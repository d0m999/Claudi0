/// Captures the Settings key owner once before a nonactivating Panel borrows keyboard focus.
/// A visible background Settings window must not receive the Panel's automatic key handoff.
public struct PanelSettingsHandback {
    private var settingsWasForeground = false

    public init() {}

    public mutating func begin(settingsWasForeground: Bool) {
        self.settingsWasForeground = settingsWasForeground
    }

    public mutating func takeSettingsRestoration() -> Bool {
        defer { settingsWasForeground = false }
        return settingsWasForeground
    }
}
