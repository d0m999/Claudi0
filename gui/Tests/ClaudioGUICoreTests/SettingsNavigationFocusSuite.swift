import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

@testable import ClaudioSettingsPresentation

/// Opt-in native key-view regression; requires system Keyboard navigation to be enabled.
@MainActor
func runSettingsNavigationFocusSuites() async {
    await suite("Settings native focus: navigation after Tab and Shift-Tab reaches the new page") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.about))
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        await Task.yield()

        expect(
            probe.sendKey(keyCode: 48, characters: "\t"),
            "Tab must reach the About page's first action")
        expect(
            probe.sendKey(keyCode: 48, characters: "\t", modifiers: .shift),
            "Shift-Tab must return from the first action to the About title")
        expect(
            probe.clickSidebar(.notifications, horizontalFraction: 0.5),
            "switch destinations through the real sidebar mouse route after keyboard traversal")
        expect(
            fixture.session.state.routeResolution.destination == .notifications,
            "the click must select Notifications")
        expect(probe.isActiveKeyWindow, "navigation must retain the native key window")
        expect(
            fixture.session.state.windowPhase == .key,
            "the presentation session must still own key focus")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the new destination's focus request")
        await Task.yield()

        let preferences = fixture.session.dependencies.preferences
        let previousPrompts = preferences.showsEventSourcePrompts
        expect(
            probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the Notifications title")
        expect(
            probe.sendKey(keyCode: 49, characters: " "),
            "Space must activate the Event Source Prompts control")
        let activated = await settingsNavigationFocusWait {
            preferences.showsEventSourcePrompts != previousPrompts
        }
        expect(
            activated && fixture.session.state.routeResolution.destination == .notifications,
            "after Tab/Shift-Tab then navigation, keyboard traversal must toggle Event Source Prompts instead of a sidebar row"
        )
    }

    await suite("Settings native focus: Sounds title leads to management scope") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.about))
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        expect(
            probe.clickSidebar(.sounds, horizontalFraction: 0.5),
            "open Sounds through the real sidebar")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the Sounds title focus request")
        await Task.yield()

        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the Sounds title")
        // Opening an NSPopUpButton starts a synchronous AppKit menu loop. External native UI
        // automation verifies its Space/arrow/Return interaction; this seam verifies actual focus.
        let activated = await settingsNavigationFocusWait { probe.focusedPopUpItems != nil }
        expect(
            activated && fixture.session.state.routeResolution.destination == .sounds,
            "Tab from the Sounds title must focus the actual management-scope picker"
        )
        expect(
            probe.focusedPopUpSelection == "默认组",
            "the first Sounds action must show the current management scope")
    }

    await suite("Settings native focus: Events title leads to the first sound scope") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/keyboard-scope"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.about), workspaceRules: [rule])
        let workspace = PanelSoundScopeID.workspace(rule.id)
        fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: workspace))
        fixture.eventSettingsModel.selectSoundScope(workspace)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        expect(
            probe.clickSidebar(.eventsAndSounds, horizontalFraction: 0.5),
            "open Events through the real sidebar")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the Events title focus request")
        await Task.yield()
        expect(
            fixture.eventSettingsSelection.route.scope == workspace,
            "ordinary navigation must preserve the workspace until the first scope action is activated"
        )

        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the Events title")
        let activated = await settingsNavigationFocusWait { probe.focusedPopUpItems != nil }
        expect(
            activated && fixture.session.state.routeResolution.destination == .eventsAndSounds,
            "Tab from the Events title must focus the current sound-scope picker")
        expect(
            fixture.eventSettingsSelection.route.scope == workspace,
            "focusing the picker must retain the selected Workspace")
    }

    await suite("Settings native focus: scope then pack picker has one stop per native control") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.about))
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        expect(
            probe.clickSidebar(.sounds, horizontalFraction: 0.5),
            "open Sounds through the real sidebar")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the Sounds title focus request")
        await Task.yield()
        guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "the Sounds editor must be mounted")
            return
        }
        let originalPackID = sounds.selectedPack?.id
        expect(
            sounds.packs.count > 1 && originalPackID != nil,
            "the list needs distinct inspectable packs")
        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must reach management scope")
        expect(
            probe.sendKey(keyCode: 48, characters: "\t"), "the next Tab must reach the pack picker")
        expect(
            (probe.focusedPopUpItems?.count ?? 0) == sounds.packs.count + 1,
            "the native pack picker must contain every inspectable pack and None")
        expect(
            fixture.soundPacksEditor.presentation.mode == .sounds(sounds),
            "keyboard focus must not apply or inspect another pack")
    }

    await suite("Settings native focus: an empty sound-pack list contributes no Tab stop") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        await withTempDirectory { root in
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "missing-pack"),
                packCards: [], selectedPackID: nil, selectedEventRows: [],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
                activation: nil)
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.about), soundPacksEditor: owner)
            let probe = SettingsRootNativeProbe(session: fixture.session)
            defer { probe.close() }
            probe.activate()
            let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
            expect(active, "the native focus regression requires an active key window")
            guard active else { return }
            _ = fixture.session.send(.windowPhaseChanged(.key))
            let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
            expect(ready, "the mounted root must consume the initial title focus request")
            expect(
                probe.clickSidebar(.sounds, horizontalFraction: 0.5),
                "open empty Sounds through the real sidebar")
            let routed = await settingsNavigationFocusWait {
                fixture.session.state.focusDebt == nil
            }
            expect(routed, "the mounted root must consume the Sounds title focus request")
            await Task.yield()
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "the empty Sounds editor must be mounted")
                return
            }
            expect(sounds.packs.isEmpty, "the native list must have no inspectable pack")
            expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must reach management scope")
            expect(
                probe.sendKey(keyCode: 48, characters: "\t"),
                "Tab must skip the disabled empty pack picker")
            expect(
                !probe.isNativeListFocused && probe.focusedPopUpItems == nil,
                "an empty pack picker must contribute no keyboard focus stop")
        }
    }
}

@MainActor
private func settingsNavigationFocusWait(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
