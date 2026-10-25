import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@testable import ClaudioSettingsPresentation

@MainActor
func runSettingsKeyboardConfirmationSuites() async {
    for action in [ActivityDiagnosticsAction.clearActivity, .clearLog] {
        await suite("Settings keyboard: cancellation restores \(action) without clearing") {
            let calls = SettingsClearOperationRecorder()
            let log = ActivityDiagnosticLogSnapshot(
                path: "/fixture/log", state: .missing, failures: [])
            let load = ActivityDiagnosticsLoadResult(readResult: .init(state: .missing), log: log)
            let model = ActivityDiagnosticsModel(
                operations: .init(
                    load: { load },
                    clearActivity: {
                        await calls.record(.clearActivity); return .success(load)
                    },
                    clearLog: {
                        await calls.record(.clearLog); return .success(log)
                    },
                    revealLog: { true }, copyLogPath: { true }))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.integrations), activityDiagnostics: model)
            let probe = NativeSettingsShellProbe(session: fixture.session, width: 1240, dark: false)
            defer { probe.close() }
            await probe.presentAndSettle()
            _ = settingsKeyboardAXElements(probe.shell.view)
            let diagnostics = await settingsKeyboardTabTo(
                "integrations.destination.activity-diagnostics", in: probe.window)
            expect(diagnostics, "Tab reaches the real Connections diagnostics entry")
            guard diagnostics else { return }
            settingsKeyboardPress(49, " ", in: probe.window)
            let mounted = await settingsKeyboardWait {
                fixture.session.state.routeResolution.destination == .usage
                    && fixture.session.renderedNavigationStamp
                        == fixture.session.navigationHistory.stamp
                    && fixture.session.state.navigationRestoration == nil
            }
            expect(
                mounted && probe.window.isKeyWindow,
                "keyboard navigation mounts Activity with native key focus")
            let identifier =
                action == .clearActivity ? "settings.activity.clear" : "settings.activity.clear-log"
            let title = ClaudioL10n(language: .zhHans).text(
                action == .clearActivity ? .settingsUsageClearHistory : .settingsUsageClearLog)
            for cancellation in ["escape", "cancel", "confirm"] {
                let reached = await settingsKeyboardTabTo(identifier, in: probe.window)
                expect(
                    reached,
                    "real Tab reaches \(identifier): \(settingsKeyboardFocusedIdentifier(in: probe.window))"
                )
                guard reached else { return }
                settingsKeyboardPress(49, " ", in: probe.window)
                let presented = await settingsKeyboardWait { probe.window.attachedSheet != nil }
                expect(
                    presented,
                    "\(cancellation): Space opens the native confirmation, responder=\(String(describing: probe.window.firstResponder)), key=\(probe.window.isKeyWindow)"
                )
                guard let sheet = probe.window.attachedSheet, presented else { return }
                let ownsKey = await settingsKeyboardWait { sheet.isKeyWindow }
                expect(ownsKey, "each repeated confirmation owns the actual native key window")
                let previous = await calls.actions
                if cancellation == "escape" {
                    settingsKeyboardPress(53, "\u{1b}", in: sheet)
                } else {
                    let buttonTitle =
                        cancellation == "cancel"
                        ? ClaudioL10n(language: .zhHans).text(.commonCancel) : title
                    let reachedButton = await settingsKeyboardTabToLabel(buttonTitle, in: sheet)
                    expect(reachedButton, "Tab reaches the \(cancellation) button")
                    if reachedButton { settingsKeyboardPress(49, " ", in: sheet) }
                }
                let dismissed = await settingsKeyboardWait { probe.window.attachedSheet == nil }
                expect(dismissed, "\(cancellation) dismisses the native confirmation")
                if !dismissed {
                    // A failed Escape must still close this fixture, without executing its action.
                    let cancelled = await settingsKeyboardTabToLabel(
                        ClaudioL10n(language: .zhHans).text(.commonCancel), in: sheet)
                    if cancelled { settingsKeyboardPress(49, " ", in: sheet) }
                    _ = await settingsKeyboardWait { probe.window.attachedSheet == nil }
                }
                let returned = await settingsKeyboardWait {
                    settingsKeyboardFocusedIdentifier(in: probe.window) == identifier
                }
                if cancellation != "confirm" {
                    expect(returned, "\(cancellation) returns focus to \(identifier)")
                    expect(probe.window.isKeyWindow, "cancellation restores the native key window")
                }
                if cancellation == "confirm" {
                    _ = await settingsKeyboardWait { model.feedback != nil }
                    let recorded = await calls.actions
                    expect(
                        recorded == previous + [action],
                        "explicit confirmation executes exactly once")
                } else {
                    let recorded = await calls.actions
                    expect(recorded == previous, "cancellation never clears either store")
                }
            }
        }
    }
}

private actor SettingsClearOperationRecorder {
    private(set) var actions: [ActivityDiagnosticsAction] = []
    func record(_ action: ActivityDiagnosticsAction) { actions.append(action) }
}

@MainActor
func settingsKeyboardPress(
    _ code: UInt16, _ characters: String, in window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) {
    // AppKit interprets the back-tab character, not a forward Tab with only the Shift flag.
    let keyCharacters = code == 48 && modifiers.contains(.shift) ? "\u{19}" : characters
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: keyCharacters, charactersIgnoringModifiers: keyCharacters,
            isARepeat: false, keyCode: code)!
    }
    // Native buttons can track Space synchronously, just as mouseDown tracks mouseUp.
    NSApp.postEvent(event(.keyUp), atStart: true)
    window.sendEvent(event(.keyDown))
}

@MainActor
func settingsKeyboardFocusedIdentifier(in window: NSWindow) -> String {
    if let view = window.firstResponder as? NSView, !view.accessibilityIdentifier().isEmpty {
        return view.accessibilityIdentifier()
    }
    return settingsKeyboardFocusedElement(in: window)?.accessibilityIdentifier?() ?? ""
}

@MainActor
private func settingsKeyboardFocusedElement(in window: NSWindow) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    return settingsKeyboardAXElements(root).last { $0.isAccessibilityFocused?() == true }
}

@MainActor
func settingsKeyboardTabTo(_ identifier: String, in window: NSWindow) async -> Bool {
    await settingsKeyboardTabTo(in: window) {
        settingsKeyboardFocusedIdentifier(in: window) == identifier
    }
}

@MainActor
private func settingsKeyboardTabToLabel(_ title: String, in window: NSWindow) async -> Bool {
    await settingsKeyboardTabTo(in: window) {
        let element = settingsKeyboardFocusedElement(in: window)
        return element?.accessibilityLabel?() == title
            || (window.firstResponder as? NSButton)?.title == title
    }
}

@MainActor
private func settingsKeyboardTabTo(in window: NSWindow, matches: () -> Bool) async -> Bool {
    for _ in 0..<48 {
        if matches() { return true }
        settingsKeyboardPress(48, "\t", in: window)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return matches()
}

@MainActor
func settingsKeyboardWait(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
func settingsKeyboardFocusIdentity(in window: NSWindow) -> String {
    let element = settingsKeyboardFocusedElement(in: window)
    return [
        settingsKeyboardFocusedIdentifier(in: window),
        element?.accessibilityRole?()?.rawValue ?? "",
        element?.accessibilityLabel?() ?? (window.firstResponder as? NSButton)?.title ?? "",
    ].joined(separator: "|")
}
