import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@testable import ClaudioSettingsPresentation

/// Opt-in native key-view regression; requires system Keyboard navigation to be enabled.
@MainActor
func runSettingsNavigationFocusSuites() async {
    NSApp.finishLaunching()
    expect(
        NSApp.isFullKeyboardAccessEnabled, "enable system Keyboard navigation for this regression")
    guard NSApp.isFullKeyboardAccessEnabled else { return }
    suite("Settings native focus: an occluded key window retains keyboard lifecycle") {
        expect(
            SettingsWindowPhase.native(isVisible: true, isKey: true, hasVisiblePixels: false)
                == .key,
            "native key ownership must not be downgraded by an occlusion callback")
        expect(
            SettingsWindowPhase.native(isVisible: true, isKey: false, hasVisiblePixels: false)
                == .hidden,
            "an occluded window without key ownership remains hidden")
        expect(
            SettingsWindowPhase.native(isVisible: true, isKey: false, hasVisiblePixels: true)
                == .visibleNonKey,
            "ordinary visible non-key windows retain their existing phase")
    }
    for (language, width, dark) in [
        (ClaudioAppLanguage.zhHans, CGFloat(1240), false), (.english, 960, true),
    ] {
        for destination in SettingsDestination.sidebarCases {
            await suite("Settings native focus: five-page traversal \(destination)/\(language)") {
                let rule = WorkspaceSoundRule(
                    directory: WorkspaceDirectory(kind: .directory, path: "/fixture/keyboard"),
                    surfaces: [.codex],
                    profile: WorkspaceSoundProfile(
                        selectedPack: "settings-fixture-pack", volume: 0.7))
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language, workspaceRules: [rule])
                let probe = NativeSettingsShellProbe(
                    session: fixture.session, width: width, dark: dark)
                defer { probe.close() }
                await probe.presentAndSettle()
                _ = settingsKeyboardAXElements(probe.shell.view)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let before = try? encoder.encode(fixture.eventSettingsModel.config)
                expect(
                    settingsKeyboardClickSidebar(destination, probe: probe),
                    "select the real sidebar row")
                await probe.presentAndSettle()
                expect(
                    probe.window.firstResponder === probe.shell.sidebarController.table,
                    "navigation retains sidebar focus")
                let first: [SettingsDestination: String] = [
                    .eventsAndSounds: "workspace.rule.global", .sounds: "settings.sounds.new-pack",
                    .integrations: "integrations.destination.agent-list.desktop",
                    .notifications: "settings.notifications.focus-toggle",
                    .general: "settings.general.language",
                ]
                var forward: [String] = []
                var identifiers: [String] = []
                for index in 0..<48 {
                    settingsKeyboardPress(48, "\t", in: probe.window)
                    await probe.settle()
                    guard let responder = probe.window.firstResponder else {
                        expect(false, "Tab retains a responder"); break
                    }
                    forward.append(settingsKeyboardFocusIdentity(in: probe.window))
                    let identifier = settingsKeyboardFocusedIdentifier(in: probe.window)
                    identifiers.append(identifier)
                    if index == 0 {
                        expect(
                            identifier == first[destination],
                            "first action is \(first[destination] ?? ""): \(identifier)")
                    }
                    expect(
                        !identifier.hasPrefix("settings.title."),
                        "static headings are not Tab stops")
                    if let control = responder as? NSControl {
                        expect(control.isEnabled, "disabled controls are skipped")
                    }
                    if responder === probe.shell.sidebarController.table { break }
                }
                expect(
                    forward.count > 2
                        && probe.window.firstResponder === probe.shell.sidebarController.table,
                    "Tab completes the current page and returns to the sidebar")
                var reverse: [String] = []
                for _ in forward {
                    settingsKeyboardPress(48, "\t", in: probe.window, modifiers: .shift)
                    await probe.settle()
                    if probe.window.firstResponder != nil {
                        reverse.append(settingsKeyboardFocusIdentity(in: probe.window))
                    }
                }
                expect(
                    reverse == Array(forward.dropLast().reversed()) + forward.suffix(1),
                    "Shift+Tab reverses the same native controls: \(reverse) vs \(forward)")
                expect(
                    fixture.session.state.routeResolution.destination == destination,
                    "passive traversal does not navigate")
                expect(
                    (try? encoder.encode(fixture.eventSettingsModel.config)) == before
                        && fixture.actionRecorder.actions.isEmpty
                        && fixture.actionRecorder.eventAudibilityChangeCount == 0,
                    "traversal does not write sound configuration or perform platform actions")
                if destination == .sounds {
                    expect(
                        Array(identifiers.prefix(3)) == [
                            "settings.sounds.new-pack", "settings.sounds.import-pack",
                            "settings.sounds.history",
                        ], "sound toolbar follows reading order")
                    let pack = "settings.sounds.pack.settings-fixture-pack"
                    let reached = await settingsKeyboardTabTo(pack, in: probe.window)
                    expect(reached, "Tab reaches the actual pack detail entry")
                    if reached {
                        settingsKeyboardPress(49, " ", in: probe.window)
                        await probe.presentAndSettle()
                        expect(
                            fixture.session.navigationHistory.current?.location.viewedPackID
                                == "settings-fixture-pack",
                            "Space inspects a pack without applying it")
                        fixture.session.send(.goBack)
                        await probe.presentAndSettle()
                        expect(
                            settingsKeyboardFocusedIdentifier(in: probe.window) == pack,
                            "Back restores the pack entry's actual focus")
                    }
                }
                if destination == .notifications {
                    let reached = await settingsKeyboardTabTo(
                        "settings.notifications.event-source-prompts", in: probe.window)
                    expect(reached, "Tab reaches banner prompts")
                    if reached {
                        let previous = fixture.preferences.showsEventSourcePrompts
                        settingsKeyboardPress(49, " ", in: probe.window)
                        await probe.settle()
                        expect(
                            fixture.preferences.showsEventSourcePrompts != previous,
                            "one Space toggles the existing preference once")
                    }
                }
                print("  Tab order: \(identifiers.joined(separator: ", "))")
            }
        }
    }
    await suite("Settings native focus: sidebar arrows follow the five visible destinations") {
        let fixture = SettingsPresentationFixtures.generalLogin()
        let probe = NativeSettingsShellProbe(session: fixture.session, width: 1240, dark: false)
        defer { probe.close() }
        await probe.presentAndSettle()
        expect(
            settingsKeyboardClickSidebar(.eventsAndSounds, probe: probe),
            "focus the first native row")
        await probe.presentAndSettle()
        for destination in SettingsDestination.sidebarCases.dropFirst() {
            settingsKeyboardPress(125, "\u{f701}", in: probe.window)
            await probe.presentAndSettle()
            expect(
                fixture.session.state.chrome.destination == destination
                    && probe.window.firstResponder === probe.shell.sidebarController.table,
                "Down navigates once and retains the source list")
        }
        for destination in SettingsDestination.sidebarCases.dropLast().reversed() {
            settingsKeyboardPress(126, "\u{f700}", in: probe.window)
            await probe.presentAndSettle()
            expect(
                fixture.session.state.chrome.destination == destination,
                "Up skips the sidebar spacer")
        }
    }
    await suite("Settings native focus: event-animation radio arrows use window key dispatch") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .notifications(.eventAnimation))
        let probe = NativeSettingsShellProbe(session: fixture.session, width: 1240, dark: false)
        defer { probe.close() }
        await probe.presentAndSettle()
        _ = settingsKeyboardAXElements(probe.shell.view)
        let first = EventAnimationStyle.allCases[0]
        let second = EventAnimationStyle.allCases[1]
        let reached = await settingsKeyboardTabTo(
            "settings.animation.style.\(first.rawValue)", in: probe.window)
        expect(reached, "Tab enters the native radio group")
        guard reached else { return }
        settingsKeyboardPress(124, "\u{f703}", in: probe.window)
        await probe.settle()
        expect(
            fixture.preferences.eventAnimation.style == second
                && settingsKeyboardFocusedIdentifier(in: probe.window)
                    == "settings.animation.style.\(second.rawValue)",
            "Right moves both focus and selection")
        for code: UInt16 in [49, 36] {
            settingsKeyboardPress(code, code == 49 ? " " : "\r", in: probe.window)
            await probe.settle()
            expect(
                fixture.preferences.eventAnimation.style == second,
                "Space/Return retain the chosen radio")
        }
        settingsKeyboardPress(123, "\u{f702}", in: probe.window)
        await probe.settle()
        expect(fixture.preferences.eventAnimation.style == first, "Left selects the prior radio")
    }
    await suite("Settings native focus: empty sound library has no phantom pack stop") {
        await withTempDirectory { root in
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "missing-pack"), packCards: [],
                selectedPackID: nil, selectedEventRows: [],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs")), activation: nil)
            let fixture = SettingsPresentationFixtures.generalLogin(soundPacksEditor: owner)
            let probe = NativeSettingsShellProbe(session: fixture.session, width: 1240, dark: false)
            defer { probe.close() }
            await probe.presentAndSettle()
            _ = settingsKeyboardAXElements(probe.shell.view)
            expect(settingsKeyboardClickSidebar(.sounds, probe: probe), "select empty Sounds")
            await probe.presentAndSettle()
            for _ in 0..<12 {
                settingsKeyboardPress(48, "\t", in: probe.window)
                await probe.settle()
                expect(
                    !settingsKeyboardFocusedIdentifier(in: probe.window).hasPrefix(
                        "settings.sounds.pack."), "empty library contributes no pack focus")
                if probe.window.firstResponder === probe.shell.sidebarController.table { break }
            }
            expect(fixture.actionRecorder.actions.isEmpty, "empty traversal performs no writes")
        }
    }
}

@MainActor
func settingsKeyboardAXElements(_ root: NSView) -> [AnyObject] {
    if !settingsKeyboardAXPrepared {
        settingsKeyboardAXPrepared = true
        let completed = DispatchSemaphore(value: 0)
        let processID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global().async {
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 1)
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                application, kAXChildrenAttribute as CFString, &children)
            completed.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while completed.wait(timeout: .now()) != .success && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        root.layoutSubtreeIfNeeded()
    }
    var result: [AnyObject] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ element: AnyObject) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        result.append(element)
        for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject) }
    }
    visit(root)
    return result
}

@MainActor
private var settingsKeyboardAXPrepared = false

@MainActor
private func settingsKeyboardClickSidebar(
    _ destination: SettingsDestination, probe: NativeSettingsShellProbe
) -> Bool {
    guard let frame = probe.shell.sidebarController.frame(for: destination) else { return false }
    let table = probe.shell.sidebarController.table
    let point = table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    @MainActor func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: probe.window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
    probe.window.sendEvent(mouse(.leftMouseDown))
    return true
}
