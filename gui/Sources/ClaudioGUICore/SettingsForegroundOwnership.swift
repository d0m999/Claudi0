/// Remembers that the retained Settings window owned the foreground before a status-item click.
/// The status item's transient popover may take key focus before its action is delivered, so a
/// key-window snapshot at that action is not sufficient. An actual external app activation or
/// closing Settings ends this ownership.
public struct SettingsForegroundOwnership {
    private var settingsWasForeground = false

    public init() {}

    public mutating func noteSettingsBecameKey() {
        settingsWasForeground = true
    }

    public mutating func noteExternalApplicationActivated() {
        settingsWasForeground = false
    }

    public mutating func noteSettingsClosed() {
        settingsWasForeground = false
    }

    public func canRestore(
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isWindowOnActiveSpace: Bool
    ) -> Bool {
        settingsWasForeground && isWindowVisible && !isWindowMiniaturized
            && isWindowOnActiveSpace
    }
}
