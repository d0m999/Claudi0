import AppKit
import SwiftUI

/// A native action button that can receive an explicit focus request even when macOS Keyboard
/// navigation is off. Focus remains presentation state; activation stays in the supplied owner.
@MainActor
package struct SettingsFocusableButton: NSViewRepresentable {
    private let title: String
    private let requestsFocus: Bool
    private let action: @MainActor () -> Void

    package init(
        _ title: String, requestsFocus: Bool, action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.requestsFocus = requestsFocus
        self.action = action
    }

    package func makeNSView(context _: Context) -> NSView {
        SettingsActionView()
    }

    package func updateNSView(_ view: NSView, context: Context) {
        guard let control = view as? SettingsActionView else { return }
        control.button.title = title
        control.button.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(title)
        control.setAccessibilityEnabled(context.environment.isEnabled)
        control.invalidateIntrinsicContentSize()
        control.onActivate = action
        control.requestsFocus = requestsFocus
        control.applyFocusRequest()
    }
}

@MainActor
private final class SettingsActionView: NSView {
    let button = NSButton(title: "", target: nil, action: nil)
    var onActivate: @MainActor () -> Void = {}
    var requestsFocus = false {
        didSet { if !requestsFocus { appliedFocusRequest = false } }
    }
    private var appliedFocusRequest = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.setButtonType(.momentaryPushIn)
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.target = self
        button.action = #selector(activate)
        button.setAccessibilityElement(false)
        addSubview(button)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
    override var acceptsFirstResponder: Bool { button.isEnabled }

    override func layout() {
        super.layout()
        button.frame = button.frame(forAlignmentRect: bounds)
        noteFocusRingMaskChanged()
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 4, dy: 3) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill()
    }

    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func accessibilityPerformPress() -> Bool {
        guard button.isEnabled else { return false }
        activate()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
        applyFocusRequest()
    }

    @objc private func windowBecameKey() {
        appliedFocusRequest = false
        applyFocusRequest()
    }

    func applyFocusRequest() {
        guard requestsFocus, !appliedFocusRequest, let window,
            window.isKeyWindow, window.attachedSheet == nil
        else { return }
        appliedFocusRequest = window.makeFirstResponder(self)
    }

    @objc private func activate() { if button.isEnabled { onActivate() } }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 49 || event.keyCode == 36 {
            if button.isEnabled, modifiers.isEmpty { activate() }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode != 49 && event.keyCode != 36 { super.keyUp(with: event) }
    }
}
