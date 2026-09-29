import AppKit

/// Settings receives keyboard focus without making application activation own its window order.
/// A background Settings window also declines automatic key handoff when the menu closes.
@MainActor
package final class RetainedSettingsWindow: NSPanel {
    package var defersAutomaticFocusForPanel = false

    package override init(
        contentRect: NSRect, styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel),
            backing: backing, defer: flag)
        hidesOnDeactivate = false
        isFloatingPanel = false
        level = .normal
    }

    /// Only an explicit Settings request may change its position among normal windows.
    /// `orderFront` alone cannot cross another application's key window while we are inactive.
    package func presentForUserRequest() {
        if isMiniaturized { deminiaturize(nil) }
        orderFrontRegardless()
        makeKey()
    }

    package override func accessibilityPerformRaise() -> Bool {
        presentForUserRequest()
        return isVisible
    }

    private var acceptsFocusDuringPanel: Bool {
        guard defersAutomaticFocusForPanel else { return true }
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return settingsWindowOwnsKeyFocus(self, keyWindow: event.window)
        default:
            return false
        }
    }

    package override var canBecomeKey: Bool {
        acceptsFocusDuringPanel && super.canBecomeKey
    }

    package override var canBecomeMain: Bool {
        false
    }
}
