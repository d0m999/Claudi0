import AppKit
import SwiftUI

/// A native pull-down menu: the collapsed title describes the action, never a selected value.
@MainActor
package struct SettingsNativeActionMenu: NSViewRepresentable {
    package struct Item {
        package let title: String
        package let identifier: String
        package let action: @MainActor () -> Void
        package init(_ title: String, identifier: String, action: @escaping @MainActor () -> Void) {
            self.title = title; self.identifier = identifier; self.action = action
        }
    }
    package let title: String
    package let identifier: String
    package let items: [Item]
    package init(_ title: String, identifier: String, items: [Item]) {
        self.title = title; self.identifier = identifier; self.items = items
    }
    package func makeCoordinator() -> Coordinator { Coordinator() }
    package func makeNSView(context: Context) -> SettingsPopUpButton {
        let button = SettingsPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }
    package func updateNSView(_ button: SettingsPopUpButton, context: Context) {
        context.coordinator.items = items
        if button.itemTitles != [title] + items.map(\.title) {
            button.removeAllItems()
            button.addItems(withTitles: [title] + items.map(\.title))
        }
        button.selectItem(at: 0)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        for (index, item) in items.enumerated() {
            button.item(at: index + 1)?.setAccessibilityIdentifier(item.identifier)
        }
    }
    @MainActor package final class Coordinator: NSObject {
        var items: [Item] = []
        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem - 1
            guard sender.isEnabled, items.indices.contains(index) else { return }
            sender.selectItem(at: 0)
            items[index].action()
        }
    }
}
