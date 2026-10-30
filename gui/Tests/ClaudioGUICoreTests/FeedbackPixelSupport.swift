import AppKit
import ClaudioGUIComponents
import Foundation

@MainActor
func feedbackSettle(_ view: NSView) {
    for _ in 0..<8 {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
}

/// Count fully covered pixels after resolving the semantic color in the actual drawing appearance.
/// Alpha is composited over the fixed settings surface the fixture actually paints. With
/// `partialCoverage`, antialiased pixels on the blend path between the surface and the fully
/// covered ink are also counted — small text on 1x displays may never reach full coverage.
@MainActor
func feedbackPixelCount(
    in view: NSView, color: NSColor, group: Bool = false, partialCoverage: Bool = false
) -> Int {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let bitmap = rep.converting(to: .sRGB, renderingIntent: .default) else { return 0 }
    let surface =
        group
        ? SettingsAppearance.groupSurface(view.effectiveAppearance)
        : SettingsAppearance.windowSurface(view.effectiveAppearance)
    guard let background = surface.usingColorSpace(.sRGB) else { return 0 }
    let backgroundComponents = [
        background.redComponent, background.greenComponent, background.blueComponent,
    ]
    var expected: [CGFloat] = []
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        guard let ink = color.usingColorSpace(.sRGB) else { return }
        expected = zip(
            [ink.redComponent, ink.greenComponent, ink.blueComponent],
            backgroundComponents
        ).map {
            $0 * ink.alphaComponent + $1 * (1 - ink.alphaComponent)
        }
    }
    guard expected.count == 3 else { return 0 }
    var count = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            if partialCoverage {
                let onBlendPath = zip(zip(components, backgroundComponents), expected)
                    .allSatisfy { pair in
                        let (value, background) = pair.0
                        let full = pair.1
                        return value >= min(background, full) - 0.02
                            && value <= max(background, full) + 0.02
                    }
                let deviates = zip(components, backgroundComponents).contains {
                    abs($0 - $1) > 0.02
                }
                if onBlendPath && deviates { count += 1 }
            } else if zip(components, expected).allSatisfy({ abs($0 - $1) <= 0.025 }) {
                count += 1
            }
        }
    }
    return count
}
