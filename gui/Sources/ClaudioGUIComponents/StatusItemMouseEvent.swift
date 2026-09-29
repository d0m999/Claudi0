import AppKit

/// Uses the event's location so delayed menu-bar delivery is independent of later mouse motion.
@MainActor
package func statusItemContainsMouseEvent(_ event: NSEvent, button: NSView) -> Bool {
    guard button.window != nil else { return false }
    let screenLocation: NSPoint
    if let eventWindow = event.window {
        screenLocation = eventWindow.convertPoint(toScreen: event.locationInWindow)
    } else {
        screenLocation = event.cgEvent?.unflippedLocation ?? event.locationInWindow
    }
    return statusItemContainsScreenPoint(screenLocation, button: button)
}

/// AppKit screen coordinates, used at the earlier application-deactivation boundary.
@MainActor
package func statusItemContainsScreenPoint(_ screenPoint: NSPoint, button: NSView) -> Bool {
    guard let window = button.window else { return false }
    let point = button.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    return button.bounds.contains(point)
}
