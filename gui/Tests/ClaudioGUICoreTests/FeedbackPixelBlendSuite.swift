import AppKit
import Foundation

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
