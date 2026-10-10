import Foundation

/// An explicit, byte-for-byte keymap profile for the Debug managed-session experiment.
/// The adapter only reads this profile; it never installs or edits Zed configuration.
public enum ZedNavigationBindings {
    public static let managedKeymap = Data(
        ("""
        [
          {
            "context": "Workspace",
            "bindings": {
              "ctrl-alt-cmd-shift-f16": "workspace::ActivatePaneLeft",
              "ctrl-alt-cmd-shift-f17": "workspace::ActivatePaneRight",
              "ctrl-alt-cmd-shift-f18": "workspace::ActivatePaneUp",
              "ctrl-alt-cmd-shift-f19": "workspace::ActivatePaneDown"
            }
          }
        ]
        """ + "\n").utf8)

    public static func hasManagedDirections(_ keymap: Data?) -> Bool { keymap == managedKeymap }

    /// Carbon virtual key codes verified against the macOS SDK. No text or prefix chord.
    public static func directionKey(_ step: ZedNavigationSearch.Step) -> UInt16? {
        switch step {
        case .left: return 0x6A
        case .right: return 0x40
        case .up: return 0x4F
        case .down: return 0x50
        case .nextTab: return nil
        }
    }
}
