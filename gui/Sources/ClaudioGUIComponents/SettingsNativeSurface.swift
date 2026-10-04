import AppKit
import SwiftUI

/// AppKit paints the system semantic color in the window's drawing appearance.
/// The enclosing group owns its radius; this view owns no focus or state.
package struct SettingsNativeSurface: NSViewRepresentable {
    package enum Kind { case window, group }
    private let kind: Kind

    package init(_ kind: Kind) { self.kind = kind }

    package func makeNSView(context: Context) -> NSView {
        let view = SettingsSemanticSurfaceView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(
            kind == .group ? "settings.semantic-surface.group" : "settings.semantic-surface.window")
        updateNSView(view, context: context)
        return view
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsSemanticSurfaceView)?.color =
            kind == .window ? .windowBackgroundColor : .underPageBackgroundColor
        nsView.needsDisplay = true
    }
}

@MainActor
private final class SettingsSemanticSurfaceView: NSView {
    var color = NSColor.windowBackgroundColor
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Preserve the system color's alpha as well as its appearance. AppKit may
            // supply a translucent under-page color, so this view must not claim opacity.
            (color.usingColorSpace(.sRGB) ?? color).setFill()
            NSBezierPath(rect: dirtyRect).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
