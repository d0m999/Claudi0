import AppKit
import SwiftUI

/// A native key-view stop with a SwiftUI label. AppKit owns keyboard activation and the focus
/// ring even when system Keyboard navigation is disabled; the supplied owner owns the action.
@MainActor
struct EventAnimationActionButton<Label: View>: View {
    let title: String
    let identifier: String
    var value: String = ""
    var selected = false
    var requestsFocus = false
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        // Keep the label in the parent's SwiftUI layout so text measures the available width.
        // The native overlay supplies interaction/focus without imposing a host's fittingSize.
        label().accessibilityHidden(true)
            .overlay {
                EventAnimationActionSurface(
                    title: title, identifier: identifier, value: value, selected: selected,
                    requestsFocus: requestsFocus, action: action
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}

@MainActor
private struct EventAnimationActionSurface: NSViewRepresentable {
    let title: String
    let identifier: String
    let value: String
    let selected: Bool
    let requestsFocus: Bool
    let action: @MainActor () -> Void

    func makeNSView(context _: Context) -> EventAnimationActionView<Color> {
        EventAnimationActionView(label: Color.clear)
    }

    func updateNSView(_ view: EventAnimationActionView<Color>, context: Context) {
        view.onActivate = action
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityLabel(title)
        view.actionIdentifier = identifier
        view.setAccessibilityValue(value)
        view.setAccessibilitySelected(selected)
        view.requestsFocus = requestsFocus
        view.invalidateIntrinsicContentSize()
        view.applyFocusRequest()
    }
}

@MainActor
final class EventAnimationActionView<Label: View>: NSView {
    let host: NSHostingView<EventAnimationActionLabel<Label>>
    var onActivate: @MainActor () -> Void = {}
    var onMove: ((Int) -> Void)?
    private(set) var isHovered = false
    var isEnabled = true
    // SwiftUI may apply an ancestor's AX identifier to a representable after updateNSView.
    // Keep the action's identity at the native focus/reading-restoration seam.
    var actionIdentifier = ""
    var requestsFocus = false {
        didSet { if !requestsFocus { appliedFocusRequest = false } }
    }
    private var appliedFocusRequest = false

    init(label: Label) {
        host = NSHostingView(rootView: EventAnimationActionLabel(content: label))
        super.init(frame: .zero)
        host.setAccessibilityElement(false)
        addSubview(host)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        scrollToVisible(bounds.insetBy(dx: -2, dy: -2))
        return true
    }
    override var needsPanelToBecomeKey: Bool { true }
    override var intrinsicContentSize: NSSize { host.fittingSize }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }
    override func layout() {
        super.layout()
        host.frame = bounds
        noteFocusRingMaskChanged()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        host.rootView.hovered = true
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        host.rootView.hovered = false
    }
    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        onActivate()
    }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func accessibilityIdentifier() -> String {
        actionIdentifier.isEmpty ? super.accessibilityIdentifier() : actionIdentifier
    }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate()
        return true
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isEnabled, modifiers.isEmpty, let onMove, event.keyCode == 123 || event.keyCode == 124 {
            onMove(event.keyCode == 123 ? -1 : 1)
            return
        }
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            if isEnabled, modifiers.isEmpty { onActivate() }
            return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode != 49 && event.keyCode != 36 { super.keyUp(with: event) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification,
                object: window)
        }
        applyFocusRequest()
    }
    @objc private func windowBecameKey() {
        applyFocusRequest()
    }
    func applyFocusRequest() {
        guard requestsFocus, !appliedFocusRequest, let window,
            window.isKeyWindow, window.attachedSheet == nil
        else { return }
        appliedFocusRequest = window.makeFirstResponder(self)
    }
}

struct EventAnimationActionLabel<Content: View>: View {
    let content: Content
    var hovered = false
    var body: some View {
        content.accessibilityHidden(true)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                    hovered ? Color(nsColor: .tertiaryLabelColor) : .clear, lineWidth: 1))
    }
}
