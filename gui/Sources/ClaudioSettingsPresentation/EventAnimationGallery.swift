import AppKit
import ClaudioGUICore
import SwiftUI

/// A radio group with separate selection, hover and native keyboard focus.
@MainActor
struct EventAnimationGallery: NSViewRepresentable {
    let title: String
    let selected: EventAnimationStyle
    let label: (EventAnimationStyle) -> AnyView
    let name: (EventAnimationStyle) -> String
    let select: (EventAnimationStyle) -> Void

    func makeNSView(context: Context) -> EventAnimationGalleryView { EventAnimationGalleryView() }
    func updateNSView(_ view: EventAnimationGalleryView, context: Context) {
        view.setAccessibilityLabel(title)
        view.setAccessibilityValue(name(selected))
        for (index, style) in EventAnimationStyle.allCases.enumerated() {
            let button = view.buttons[index]
            button.host.rootView = EventAnimationActionLabel(
                content: label(style), hovered: button.isHovered)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(name(style))
            button.setAccessibilityIdentifier("settings.animation.style.\(style.rawValue)")
            button.setAccessibilityValue(NSNumber(value: selected == style))
            button.setAccessibilitySelected(selected == style)
            button.isEnabled = context.environment.isEnabled
            button.onActivate = { select(style) }
            button.onMove = { [weak view] delta in
                guard let view else { return }
                let next = min(view.buttons.count - 1, max(0, index + delta))
                guard next != index else { return }
                select(EventAnimationStyle.allCases[next])
                view.window?.makeFirstResponder(view.buttons[next])
            }
        }
    }
}

@MainActor
final class EventAnimationGalleryView: NSView {
    let buttons = EventAnimationStyle.allCases.map { _ in
        EventAnimationActionView(label: AnyView(EmptyView()))
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 153)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier("settings.animation.choices")
        setAccessibilityChildren(buttons)
        let stack = NSStackView(views: buttons)
        for button in buttons {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
}
