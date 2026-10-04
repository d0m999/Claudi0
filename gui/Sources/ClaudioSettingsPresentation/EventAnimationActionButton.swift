import AppKit
import SwiftUI

/// A native key-view stop with a SwiftUI label. AppKit owns keyboard activation and the focus
/// ring even when system Keyboard navigation is disabled; the supplied owner owns the action.
@MainActor
struct EventAnimationActionButton<Label: View>: NSViewRepresentable {
    let title: String
    let identifier: String
    var value: String = ""
    var selected = false
    var requestsFocus = false
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    func makeNSView(context _: Context) -> EventAnimationActionView<Label> {
        EventAnimationActionView(label: label())
    }

    func updateNSView(_ view: EventAnimationActionView<Label>, context: Context) {
        view.host.rootView = EventAnimationActionLabel(content: label())
        view.onActivate = action
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
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

@MainActor
struct EventAnimationSwitch: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding var isOn: Bool

    func makeNSView(context _: Context) -> EventAnimationActionView<EventAnimationSwitchLabel> {
        EventAnimationActionView(label: EventAnimationSwitchLabel(title: title, isOn: isOn))
    }

    func updateNSView(
        _ view: EventAnimationActionView<EventAnimationSwitchLabel>, context: Context
    ) {
        view.host.rootView = EventAnimationActionLabel(
            content: EventAnimationSwitchLabel(title: title, isOn: isOn))
        view.onActivate = { isOn.toggle() }
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityRole(.checkBox)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityValue(NSNumber(value: isOn))
        view.invalidateIntrinsicContentSize()
    }
}

struct EventAnimationSwitchLabel: View {
    let title: String
    let isOn: Bool
    var body: some View {
        Toggle(title, isOn: .constant(isOn)).toggleStyle(.switch).font(.system(size: 13))
    }
}
