import AppKit
import Foundation

@MainActor
func feedbackSettle(_ view: NSView) {
    for _ in 0..<8 {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
}

/// Count fully covered pixels after resolving the semantic color in the actual drawing appearance.
/// Alpha is composited over the window and (when requested) the translucent system group.
@MainActor
func feedbackPixelCount(in view: NSView, color: NSColor, group: Bool = false) -> Int {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let bitmap = rep.converting(to: .sRGB, renderingIntent: .default) else { return 0 }
    var expected: [CGFloat] = []
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        guard let ink = color.usingColorSpace(.sRGB),
            let page = NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
            let surface = (group ? NSColor.underPageBackgroundColor : NSColor.windowBackgroundColor)
                .usingColorSpace(.sRGB)
        else { return }
        let bg = zip(
            [surface.redComponent, surface.greenComponent, surface.blueComponent],
            [page.redComponent, page.greenComponent, page.blueComponent]
        ).map {
            $0 * surface.alphaComponent + $1 * (1 - surface.alphaComponent)
        }
        expected = zip([ink.redComponent, ink.greenComponent, ink.blueComponent], bg).map {
            $0 * ink.alphaComponent + $1 * (1 - ink.alphaComponent)
        }
    }
    guard expected.count == 3 else { return 0 }
    var count = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            if zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], expected)
                .allSatisfy({ abs($0 - $1) <= 0.025 })
            {
                count += 1
            }
        }
    }
    return count
}
