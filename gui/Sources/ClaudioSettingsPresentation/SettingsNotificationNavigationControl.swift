import AppKit
import SwiftUI

/// AppKit draws the bezel, separator, disabled arrows and keyboard focus as one native control.
@MainActor
struct SettingsNotificationNavigationControl: NSViewRepresentable {
    let backTitle: String
    let forwardTitle: String
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: @MainActor () -> Void
    let goForward: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .rounded
        control.controlSize = .large
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        #endif
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.navigate(_:))
        control.setAccessibilityIdentifier("settings.notifications.navigation")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.goBack = goBack
        context.coordinator.goForward = goForward
        for (index, item) in [
            ("chevron.backward", backTitle, canGoBack),
            ("chevron.forward", forwardTitle, canGoForward),
        ].enumerated() {
            let image = NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            control.setImage(image, forSegment: index)
            control.setToolTip(item.1, forSegment: index)
            control.setEnabled(item.2 && context.environment.isEnabled, forSegment: index)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var goBack: @MainActor () -> Void = {}
        var goForward: @MainActor () -> Void = {}

        @objc func navigate(_ control: NSSegmentedControl) {
            let segment = control.selectedSegment
            guard (0..<2).contains(segment), control.isEnabled(forSegment: segment) else { return }
            if segment == 0 { goBack() } else { goForward() }
        }
    }
}
