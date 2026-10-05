import CoreGraphics
import Foundation

// Only configure the disposable GitHub runner, never a developer's display.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    fatalError("Native CI display preparation requires a GitHub Actions runner")
}

let display = CGMainDisplayID()
let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] ?? []
guard let mode = modes.first(where: { $0.width == 1920 && $0.height == 1080 }) else {
    fatalError("Native CI requires the runner's 1920x1080 display mode")
}

let originalBounds = CGDisplayBounds(display)
var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success else {
    fatalError("Unable to begin native CI display configuration")
}
guard CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success else {
    CGCancelDisplayConfiguration(configuration)
    fatalError("Unable to select the native CI display mode")
}
// App-only mode would revert when this script exits, before the harness starts.
guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
    fatalError("Unable to apply the native CI display mode for this runner session")
}
let bounds = CGDisplayBounds(display)
guard bounds.width >= 1920 && bounds.height >= 1080 else {
    fatalError("Native CI display did not reach 1920x1080: \(bounds)")
}
print("Native CI display: \(originalBounds) -> \(bounds)")
