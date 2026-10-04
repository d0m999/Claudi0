import AppKit
import SwiftUI

@MainActor
package struct SettingsNativeSwitch: NSViewRepresentable {
    package let title: String
    private let identifier: String?
    @Binding package var isOn: Bool
    package init(_ title: String, isOn: Binding<Bool>, identifier: String? = nil) {
        self.title = title; _isOn = isOn; self.identifier = identifier
    }
    package func makeCoordinator() -> Coordinator { Coordinator(binding: $isOn) }
    package func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
        control.target = context.coordinator
        control.action = #selector(Coordinator.change(_:))
        return control
    }
    package func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.binding = $isOn
        control.state = isOn ? .on : .off
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(title)
        if let identifier { control.setAccessibilityIdentifier(identifier) }
    }
    @MainActor
    package final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func change(_ sender: NSSwitch) {
            guard sender.isEnabled else { return }
            binding.wrappedValue = sender.state == .on
        }
    }
}
