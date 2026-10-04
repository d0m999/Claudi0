import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

@MainActor
func runSettingsNativeControlsSuites() async {
    await suite("Native settings controls: full names, content width, disabled and publication") {
        let model = NativeSettingsControlFixture()
        let long =
            "A very long sound pack name whose full identity must remain available to accessibility and the menu"
        let host = NSHostingView(
            rootView: NativeSettingsControlFixtureView(model: model, longTitle: long))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 70)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        guard let popup = allNativeSettingsViews(host).compactMap({ $0 as? NSPopUpButton }).first
        else {
            expect(false, "Production control must be a real NSPopUpButton")
            return
        }
        expect(
            !popup.isBordered && popup.intrinsicContentSize.width <= 280,
            "The collapsed popup is borderless and bounded, with content-based width")
        expect(popup.itemTitles == ["Short", long], "The native menu retains the full long value")
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        expect(
            model.value == "long" && model.changes == 1,
            "One native selection emits exactly one binding mutation")
        expect(
            (popup.accessibilityValue() as? String) == long,
            "Accessibility retains the entire collapsed value")
        expect(
            popup.bounds.width <= 280 && popup.bounds.height < 30,
            "The rendered long value remains one compact native line: \(popup.bounds), intrinsic \(popup.intrinsicContentSize)"
        )
        model.isEnabled = false
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        expect(!popup.isEnabled, "Disabled presentation reaches the AppKit control")
        popup.selectItem(at: 0)
        _ = popup.sendAction(popup.action, to: popup.target)
        expect(model.changes == 1, "Disabled native action cannot write the binding")
        model.isEnabled = true
        model.isChinese = true
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        expect(
            popup.item(at: 1)?.accessibilityLabel() == long + " · 只读 · CC0"
                && (popup.accessibilityValue() as? String) == long + " · 只读 · CC0",
            "A bilingual publication preserves full pack metadata in the menu and selected accessibility value"
        )
        expect(model.changes == 1, "Localization updates do not write the selected value")
    }

    await suite("Native settings controls: preview selection and radio gallery keyboard") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.notifications))
        let session = fixture.session
        session.send(.route(.notifications(.eventAnimation)))
        let probe = NativeSettingsShellProbe(session: session, width: 960, dark: false)
        defer { probe.close() }
        await probe.settle()
        let preferences = fixture.preferences.snapshot
        let segments = allNativeSettingsViews(probe.shell.view).compactMap {
            $0 as? NSSegmentedControl
        }
        guard
            let preview = segments.first(where: {
                $0.trackingMode == .selectOne && $0.segmentCount == 5
            })
        else {
            expect(
                false, "Five-event preview must mount one native single-selection segmented control"
            )
            return
        }
        expect(
            preview.selectedSegment
                == Event.allCases.firstIndex(of: session.animationPreview.event),
            "The current event remains visibly selected after pointer focus leaves")
        preview.selectedSegment = 1
        _ = preview.sendAction(preview.action, to: preview.target)
        await probe.settle()
        expect(
            session.animationPreview.event == Event.allCases[1],
            "Native segment action only selects the preview event")
        expect(
            fixture.preferences.snapshot == preferences && fixture.actionRecorder.actions.isEmpty,
            "Preview does not persist preferences or produce sound/platform effects")
        let radios = allNativeSettingsViews(probe.shell.view).filter {
            $0.accessibilityRole() == .radioButton
        }
        expect(
            radios.count == 4,
            "The retained four-character gallery exposes four native radio buttons")
        if radios.count == 4,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: probe.window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: 124)
        {
            probe.window.makeFirstResponder(radios[0])
            radios[0].keyDown(with: event)
            await probe.settle()
            expect(
                fixture.preferences.eventAnimation.style == EventAnimationStyle.allCases[1],
                "Right selects the next character")
            expect(
                probe.window.firstResponder === radios[1],
                "Selection and keyboard focus move to the same radio, with distinct drawing")
        }
        if radios.count == 4 {
            for keyCode: UInt16 in [49, 36] {
                guard
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: probe.window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: keyCode)
                else { continue }
                radios[2].keyDown(with: event)
                await probe.settle()
                expect(
                    fixture.preferences.eventAnimation.style == EventAnimationStyle.allCases[2],
                    "Space/Return activate the focused gallery item through its native responder")
            }
        }
    }
}

@MainActor
private final class NativeSettingsControlFixture: ObservableObject {
    @Published var value = "short"
    @Published var isEnabled = true
    @Published var isChinese = false
    var changes = 0
}

@MainActor
private struct NativeSettingsControlFixtureView: View {
    @ObservedObject var model: NativeSettingsControlFixture
    let longTitle: String
    var body: some View {
        SettingsNativePopUp(
            "Viewed sound pack",
            selection: Binding(
                get: { model.value },
                set: {
                    model.changes += 1; model.value = $0
                }),
            options: [
                SettingsMenuOption("short", model.isChinese ? "短名" : "Short"),
                SettingsMenuOption(
                    "long", longTitle,
                    accessibilityLabel: model.isChinese ? longTitle + " · 只读 · CC0" : nil),
            ]
        )
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!model.isEnabled)
    }
}

@MainActor
private func allNativeSettingsViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allNativeSettingsViews)
}
