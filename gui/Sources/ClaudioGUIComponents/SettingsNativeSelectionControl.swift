import AppKit
import SwiftUI

@MainActor
package struct SettingsNativeSelectionControl<Value: Hashable>: NSViewRepresentable {
    package let title: String
    private let identifier: String?
    @Binding package var selection: Value
    package let options: [SettingsMenuOption<Value>]

    package init(
        title: String, selection: Binding<Value>, options: [SettingsMenuOption<Value>],
        identifier: String? = nil
    ) {
        self.title = title; _selection = selection; self.options = options
        self.identifier = identifier
    }
    package func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    package func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.controlSize = .regular
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        return control
    }
    package func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        control.isEnabled = context.environment.isEnabled && options.contains(where: \.isEnabled)
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            control.setLabel(option.title, forSegment: index)
            control.setToolTip(option.title, forSegment: index)
            control.setEnabled(context.environment.isEnabled && option.isEnabled, forSegment: index)
        }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        control.setAccessibilityLabel(title)
        if let identifier { control.setAccessibilityIdentifier(identifier) }
        control.setAccessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }
    @MainActor
    package final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [SettingsMenuOption<Value>] = []
        init(selection: Binding<Value>) { self.selection = selection }
        @objc func choose(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard options.indices.contains(index), control.isEnabled(forSegment: index) else {
                return
            }
            selection.wrappedValue = options[index].value
        }
    }
}
