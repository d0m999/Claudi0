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

/// A partial pixel counts only when every discriminating channel has moved the same fraction
/// from the surface toward the fully covered ink. The axis-aligned box between those two colors
/// also contains unrelated antialiased chrome.
func isAntialiasedInkBlend(
    _ components: [CGFloat], background: [CGFloat], full: [CGFloat]
) -> Bool {
    var parameters: [CGFloat] = []
    for index in 0..<3 {
        let span = full[index] - background[index]
        let delta = components[index] - background[index]
        if abs(span) < 0.05 {
            if abs(delta) > 0.03 { return false }
            continue
        }
        let parameter = delta / span
        if parameter < -0.04 || parameter > 1.04 { return false }
        parameters.append(parameter)
    }
    guard let anchor = parameters.first else { return false }
    guard parameters.contains(where: { $0 > 0.12 }) else { return false }
    return parameters.allSatisfy { abs($0 - anchor) <= 0.22 }
}

/// Count fully covered pixels after resolving the semantic color in the actual drawing appearance.
/// Alpha is composited over the fixed settings surface the fixture actually paints. With
/// `partialCoverage`, only antialiased pixels on the blend line inside `sampleRect` count.
/// Omitting that rect fails closed: a whole-view box match lets unrelated chrome satisfy a small
/// threshold. `colorAt(x:y:)` is top-left; view bounds are bottom-left.
@MainActor
func feedbackPixelCount(
    in view: NSView, color: NSColor, group: Bool = false, partialCoverage: Bool = false,
    sampleRect: NSRect? = nil
) -> Int {
    if partialCoverage && sampleRect == nil { return 0 }
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
    let bounds = view.bounds
    let columns: Range<Int>
    let rows: Range<Int>
    if partialCoverage, let sampleRect {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        let scaleX = CGFloat(bitmap.pixelsWide) / bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / bounds.height
        let minX = max(0, Int(floor((sampleRect.minX - bounds.minX) * scaleX)))
        let maxX = min(bitmap.pixelsWide, Int(ceil((sampleRect.maxX - bounds.minX) * scaleX)))
        let minY = max(0, Int(floor((bounds.maxY - sampleRect.maxY) * scaleY)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil((bounds.maxY - sampleRect.minY) * scaleY)))
        columns = minX..<max(minX, maxX)
        rows = minY..<max(minY, maxY)
    } else {
        columns = 0..<bitmap.pixelsWide
        rows = 0..<bitmap.pixelsHigh
    }
    let xStart = columns.lowerBound % 2 == 0 ? columns.lowerBound : columns.lowerBound + 1
    let yStart = rows.lowerBound % 2 == 0 ? rows.lowerBound : rows.lowerBound + 1
    guard xStart < columns.upperBound, yStart < rows.upperBound else { return 0 }
    var count = 0
    for y in stride(from: yStart, to: rows.upperBound, by: 2) {
        for x in stride(from: xStart, to: columns.upperBound, by: 2) {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            if partialCoverage {
                if isAntialiasedInkBlend(
                    components, background: backgroundComponents, full: expected)
                {
                    count += 1
                }
            } else if zip(components, expected).allSatisfy({ abs($0 - $1) <= 0.025 }) {
                count += 1
            }
        }
    }
    return count
}

@MainActor
func runFeedbackPixelBlendSuites() {
    suite("feedback pixels: partial ink must lie on the surface-to-ink blend") {
        let background: [CGFloat] = [1, 1, 1]
        let ink: [CGFloat] = [0.4, 0.4, 0.4]
        let midpoint: [CGFloat] = [0.7, 0.7, 0.7]
        let offLine: [CGFloat] = [0.4, 1, 1]
        expect(
            !isAntialiasedInkBlend(background, background: background, full: ink),
            "the untouched surface is not ink")
        expect(
            isAntialiasedInkBlend(ink, background: background, full: ink),
            "fully covered ink counts")
        expect(
            isAntialiasedInkBlend(midpoint, background: background, full: ink),
            "a grayscale midpoint on the blend line counts")
        expect(
            !isAntialiasedInkBlend(offLine, background: background, full: ink),
            "a pixel inside the channel box but off the blend line does not count")
        expect(
            feedbackPixelCount(
                in: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8)),
                color: .secondaryLabelColor, partialCoverage: true) == 0,
            "partial coverage without a sampled rect fails closed")
    }
}
