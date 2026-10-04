import AppKit
import ClaudioGUICore
import Foundation

/// Expected transfer to the target app is permitted; activation of a third app cancels all
/// subsequent actions. An already sent native action cannot be recalled.
@MainActor
package final class NavigationFocusGuard {
    private var observer: NSObjectProtocol?
    private(set) var isValid = true
    private var handedOff = false
    private var allowsHandoff = false
    func beginHandoff() { allowsHandoff = true }
    private let targetPID: Int32
    private let initialPID: Int32?
    private var onInvalidation: (@MainActor () -> Void)?
    package init(
        targetPID: Int32,
        initialPID: Int32? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) {
        self.targetPID = targetPID
        self.initialPID = initialPID
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid =
                (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.didActivate(pid)
            }
        }
    }
    package func cancelOnInvalidation(
        _ task: Task<Void, Never>,
        complete: @escaping @MainActor (SessionNavigationActionResult) -> Void
    ) {
        onInvalidation = {
            task.cancel()
            // A suspended host may never send a result after cancellation.
            complete(.cancelled)
        }
        if !isValid { onInvalidation?() }
    }

    package func didActivate(_ pid: Int32?) {
        guard isValid else { return }
        if pid == targetPID {
            if allowsHandoff {
                handedOff = true
            } else if pid != initialPID {
                invalidate()
            }
        } else if pid != NSRunningApplication.current.processIdentifier
            && (handedOff || pid != initialPID)
        {
            invalidate()
        }
    }

    private func invalidate() {
        isValid = false
        onInvalidation?()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        onInvalidation = nil
    }
}
