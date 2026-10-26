import AppKit
import ApplicationServices
import ClaudioGUICore
import ClaudioLocalization

@testable import ClaudioSettingsPresentation

@MainActor
func runSettingsKeyboardAboutSuites() async {
    for language in [ClaudioAppLanguage.zhHans, .english] {
        await suite("Settings keyboard: About opens and cancels from its entry / \(language)") {
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language, route: .destination(.general))
            let probe = NativeSettingsShellProbe(session: fixture.session, width: 960, dark: false)
            defer { probe.close() }
            guard await probe.presentAndSettle() else { return }
            let identifiers = settingsPublicAXIdentifiers()
            for identifier in [
                "settings.general.language", "settings.general.login-item.toggle",
                "settings.general.login-item.recheck", "settings.general.about",
            ] {
                expect(
                    identifiers.contains(identifier),
                    "Public AX retains the General child's identifier \(identifier): \(identifiers)"
                )
            }
            let entry = "settings.general.about"
            let reached = await settingsKeyboardTabTo(entry, in: probe.window)
            expect(reached, "Tab reaches About")
            guard reached else { return }
            let historyIDs = fixture.session.navigationHistory.entries.map(\.id)
            let cursor = fixture.session.navigationHistory.cursor
            settingsKeyboardPress(36, "\r", in: probe.window)
            let opened = await settingsKeyboardWait {
                probe.window.attachedSheet?.isKeyWindow == true
            }
            expect(opened, "Return presents the actual key About sheet")
            guard opened, let sheet = probe.window.attachedSheet else { return }
            let sheetIdentifiers = settingsPublicAXIdentifiers()
            for identifier in [
                "settings.about.copy-version", "settings.about.diagnostics.copy",
                "settings.about.close",
            ] {
                expect(
                    sheetIdentifiers.contains(identifier),
                    "Public AX retains the About child's identifier \(identifier): \(sheetIdentifiers)"
                )
            }
            fixture.session.send(.selectSidebar(.sounds))
            expect(
                fixture.session.state.routeResolution.destination == .general,
                "About blocks outer navigation")
            var responders = Set<ObjectIdentifier>()
            for modifiers: NSEvent.ModifierFlags in [[], .shift] {
                for _ in 0..<12 {
                    settingsKeyboardPress(48, "\t", in: sheet, modifiers: modifiers)
                    await probe.settle()
                    expect(
                        (sheet.firstResponder as? NSView)?.window === sheet,
                        "Tab / Shift+Tab stays inside About")
                    if let responder = sheet.firstResponder {
                        responders.insert(ObjectIdentifier(responder))
                    }
                }
            }
            expect(responders.count > 1, "About traversal actually changes the responder")
            settingsKeyboardPress(53, "\u{1b}", in: sheet)
            let returned = await settingsKeyboardWait {
                probe.window.attachedSheet == nil && probe.window.isKeyWindow
                    && settingsKeyboardFocusedIdentifier(in: probe.window) == entry
            }
            expect(
                returned,
                "Escape restores the original About entry: \(settingsKeyboardWindowState(probe.window))"
            )
            expect(
                fixture.session.navigationHistory.entries.map(\.id) == historyIDs
                    && fixture.session.navigationHistory.cursor == cursor,
                "About and cancellation do not create browsing history")
            expect(
                fixture.actionRecorder.actions.isEmpty,
                "About traversal performs no platform actions")
        }
    }
}

/// The public AX bridge can expose different wrappers from the NSView first responder.
@MainActor
private func settingsPublicAXIdentifiers() -> [String] {
    let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 2)
    var identifiers: [String] = []
    var remaining = 500
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }
    func visit(_ element: AXUIElement) {
        guard remaining > 0 else { return }
        remaining -= 1
        if let identifier = attribute(element, kAXIdentifierAttribute) as? String {
            identifiers.append(identifier)
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            visit(child)
        }
    }
    visit(app)
    return identifiers
}
