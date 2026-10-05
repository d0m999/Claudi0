import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsScopePickerSuites() async {
    await suite(
        "Settings scope pickers: native actions retain typed routes and selection ownership"
    ) {
        for destination in [SettingsDestination.eventsAndSounds, .sounds] {
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/scope-picker"),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(destination), workspaceRules: [rule])
            let session = fixture.session
            let probe = NativeSettingsShellProbe(session: session, width: 960, dark: false)
            defer { probe.close() }
            await probe.settle()
            let identifier =
                destination == .sounds
                ? "settings.sounds.management-scope" : "workspace.scope-selector"
            func controls(in view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { controls(in: $0) }
            }
            guard
                let picker = controls(in: probe.shell.view).compactMap({ $0 as? NSPopUpButton })
                    .first(where: { $0.accessibilityIdentifier() == identifier })
            else {
                expect(false, "\(destination) mounts its production scope picker")
                continue
            }
            expect(
                picker.numberOfItems == 2 && picker.indexOfSelectedItem == 0,
                "\(destination) initially presents Default Group and the real workspace")
            let configuration = fixture.eventSettingsModel.configState
            for (index, scope) in [
                (1, PanelSoundScopeID.workspace(rule.id)), (0, .global),
                (1, .workspace(rule.id)),
            ] {
                let version = session.navigationHistory.version
                picker.selectItem(at: index)
                _ = picker.sendAction(picker.action, to: picker.target)
                await probe.settle()
                let presentedScope: PanelSoundScopeID
                let capturedTarget: WorkspaceSoundWriteTarget?
                if destination == .sounds {
                    guard case .sounds(let route) = session.state.routeResolution.route else {
                        expect(false, "The Sounds picker submits a typed Sounds route")
                        continue
                    }
                    presentedScope = route.scope
                    capturedTarget = route.workspaceTarget
                    expect(
                        fixture.eventSettingsModel.selectedSoundScope == .global,
                        "Browsing a Sounds management scope does not apply that scope")
                } else {
                    presentedScope = session.state.eventPresentation.route.scope
                    capturedTarget = session.state.eventPresentation.route.workspaceTarget
                    expect(
                        fixture.eventSettingsModel.selectedSoundScope == scope,
                        "The Events picker updates the shared selection owner")
                }
                expect(
                    presentedScope == scope,
                    "\(destination) native action retains the typed browsing scope")
                expect(
                    session.navigationHistory.version == version + 1
                        && picker.indexOfSelectedItem == index,
                    "\(destination) publishes one route transaction and keeps selection after updates"
                )
                if scope.workspaceID != nil {
                    expect(
                        capturedTarget == WorkspaceSoundWriteTarget(rule: rule),
                        "\(destination) retains the selected workspace write target")
                }
            }
            expect(
                fixture.eventSettingsModel.configState == configuration
                    && fixture.actionRecorder.actions.isEmpty,
                "Scope browsing does not rewrite sound configuration or invoke platform effects")
        }
    }
}
