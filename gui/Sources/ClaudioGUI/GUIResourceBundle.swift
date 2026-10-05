import Foundation

/// SwiftPM's generated `Bundle.module` accessor looks beside `Bundle.main.bundleURL`, which is
/// correct for `swift run` but not for our hand-assembled macOS app: its resource bundle lives in
/// `Contents/Resources`. Resolve that packaged location explicitly and keep `.module` only as the
/// development/Xcode Preview fallback. The assembly scripts enforce the same exactly-one contract.
let hostIconResourceBundle: Bundle = {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        return .module
    }
    guard let resourcesURL = Bundle.main.resourceURL else {
        preconditionFailure("claudi0.app is missing Contents/Resources")
    }

    let candidates: [URL]
    do {
        candidates = try FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasSuffix("_ClaudioGUI.bundle") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        preconditionFailure("Cannot inspect Claudio app resources: \(error)")
    }

    guard candidates.count == 1 else {
        preconditionFailure(
            "Expected exactly one *_ClaudioGUI.bundle in Contents/Resources, found \(candidates.count)"
        )
    }
    guard let bundle = Bundle(url: candidates[0]) else {
        preconditionFailure("Cannot load GUI resource bundle at \(candidates[0].path)")
    }
    return bundle
}()
