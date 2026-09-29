import AppKit
import QuartzCore

/// Keeps an already-foreground Settings window in place while macOS transfers a status-item
/// click away from an accessory application. The protection ends when the menu is shown; it
/// never gives a background Settings window permission to move forward.
@MainActor
package final class StatusItemWindowOrderGuard {
    private weak var window: NSWindow?
    private var originalLevel: NSWindow.Level?
    private var expiry: DispatchWorkItem?
    private let maximumDuration: TimeInterval

    package init(maximumDuration: TimeInterval = 0.5) {
        self.maximumDuration = maximumDuration
    }

    package func isProtecting(_ candidate: NSWindow) -> Bool {
        originalLevel != nil && window === candidate
    }

    /// The caller must establish that Settings owns key and the primary mouse button is down
    /// over its own status item, at applicationWillResignActive rather than the later action.
    @discardableResult
    package func begin(window: NSWindow) -> Bool {
        guard originalLevel == nil, window.isVisible, !window.isMiniaturized,
            window.level == .normal
        else { return false }
        self.window = window
        originalLevel = window.level
        commit {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        }
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // A lost/cancelled status-item action must not leave Settings elevated or
                // restore it over a newer user choice.
                self?.finish(restoringOrder: false)
            }
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumDuration, execute: expiry)
        return true
    }

    package func finish(restoringOrder: Bool) {
        guard let level = originalLevel else { return }
        expiry?.cancel()
        expiry = nil
        originalLevel = nil
        let window = window
        self.window = nil
        guard let window else { return }
        commit {
            window.level = level
            if restoringOrder, window.isVisible, !window.isMiniaturized, window.isOnActiveSpace {
                window.orderFrontRegardless()
            }
        }
    }

    private func commit(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            changes()
        }
        // AppKit otherwise defers the level transaction until after WindowManager has raised
        // the previous regular app. Both entry and release must reach the compositor now.
        CATransaction.flush()
    }
}
