import AppKit
import SwiftUI

package struct SettingsMenuOption<Value: Hashable> {
    package let value: Value
    package let title: String
    package let accessibilityLabel: String?
    package var isEnabled: Bool
    package init(
        _ value: Value, _ title: String, isEnabled: Bool = true, accessibilityLabel: String? = nil
    ) {
        self.value = value; self.title = title; self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
    }
}

/// The OS draws the arrow and menu. Only the collapsed control's width is bounded.
@MainActor
package struct SettingsNativePopUp<Value: Hashable>: NSViewRepresentable {
    private let title: String
    private let identifier: String?
    @Binding private var selection: Value
    private let options: [SettingsMenuOption<Value>]

    package init(
        _ title: String, selection: Binding<Value>, options: [SettingsMenuOption<Value>],
        identifier: String? = nil
    ) {
        self.title = title; _selection = selection; self.options = options
        self.identifier = identifier
    }
    package func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    package func makeNSView(context: Context) -> SettingsPopUpButton {
        let control = SettingsPopUpButton(frame: .zero, pullsDown: false)
        control.isBordered = false
        control.controlSize = .small
        control.autoenablesItems = false
        control.cell?.lineBreakMode = .byTruncatingTail
        control.cell?.usesSingleLineMode = true
        control.cell?.wraps = false
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        return control
    }
    package func updateNSView(_ control: SettingsPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        let selected = options.firstIndex { $0.value == selection }
        if control.itemTitles != options.map(\.title) {
            control.removeAllItems()
            control.addItems(withTitles: options.map(\.title))
        }
        for (index, option) in options.enumerated() {
            control.item(at: index)?.isEnabled = option.isEnabled
            control.item(at: index)?.setAccessibilityLabel(
                option.accessibilityLabel ?? option.title)
        }
        control.selectItem(at: selected ?? -1)
        control.isEnabled = context.environment.isEnabled && selected != nil
        control.setAccessibilityLabel(title)
        if let identifier { control.setAccessibilityIdentifier(identifier) }
        control.setAccessibilityValue(
            selected.map { options[$0].accessibilityLabel ?? options[$0].title } ?? "")
        control.toolTip = selected.map { options[$0].title }
        control.invalidateIntrinsicContentSize()
    }

    @available(macOS 13, *)
    package func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: SettingsPopUpButton, context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    package final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [SettingsMenuOption<Value>] = []
        init(selection: Binding<Value>) { self.selection = selection }
        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard sender.isEnabled, options.indices.contains(index), options[index].isEnabled else {
                return
            }
            selection.wrappedValue = options[index].value
        }
    }
}

@MainActor
package final class SettingsPopUpButton: NSPopUpButton {
    package override var needsPanelToBecomeKey: Bool { true }
    package override var alignmentRectInsets: NSEdgeInsets {
        .init(top: 0, left: 0, bottom: 0, right: 0)
    }
    package override var intrinsicContentSize: NSSize {
        let natural = super.intrinsicContentSize
        return NSSize(width: min(280, max(36, natural.width)), height: natural.height)
    }
}
