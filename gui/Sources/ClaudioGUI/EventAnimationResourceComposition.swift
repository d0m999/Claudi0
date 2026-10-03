import ClaudioGUIComponents
import Foundation

/// The executable is the sole resource-bearing target; both consumers receive this owner.
@MainActor
func makeEventAnimationResources() -> EventAnimationResources {
    EventAnimationResources(
        directory: hostIconResourceBundle.resourceURL?.appendingPathComponent(
            "EventAnimations", isDirectory: true))
}
