import AppKit
import SwiftUI

/// AppKit paints a fixed settings surface selected by the view's drawing appearance.
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
        (nsView as? SettingsSemanticSurfaceView)?.kind = kind
        nsView.needsDisplay = true
    }
}

@MainActor
private final class SettingsSemanticSurfaceView: NSView {
    var kind = SettingsNativeSurface.Kind.window
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let surface =
            kind == .window
            ? SettingsAppearance.windowSurface(effectiveAppearance)
            : SettingsAppearance.groupSurface(effectiveAppearance)
        surface.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
