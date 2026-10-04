import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow
import SwiftUI

@MainActor
func runSettingsRootInteractionSuites() async {
    await suite("Settings native sidebar: full row hit geometry and one selection transaction") {
        for (destination, fraction) in [
            (SettingsDestination.integrations, CGFloat(0.08)), (.notifications, 0.5),
            (.sounds, 0.92),
        ] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                availability: PreviewFixtures.settingsRouteAvailability)
            let probe = SettingsRootNativeProbe(session: fixture.session)
            defer { probe.close() }
            await probe.settle()
            let revision = fixture.session.navigationHistory.version
            expect(
                probe.selectSidebar(destination, horizontalFraction: fraction),
                "The native table hit region resolves the entire requested row")
            expect(
                fixture.session.state.chrome.destination == destination
                    && fixture.session.navigationHistory.version == revision + 1,
                "A native selection invokes one session transaction")
        }
    }
    await suite("Settings native sidebar: arrows skip spacers, boundaries and modal state") {
        let fixture = SettingsPresentationFixtures.generalLogin()
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        await probe.settle()
        _ = probe.selectSidebar(.eventsAndSounds, horizontalFraction: 0.5)
        probe.sendSidebarKey(125)
        expect(
            fixture.session.state.chrome.destination == .sounds,
            "Down uses the real NSTableView keyDown implementation")
        probe.sendSidebarKey(126)
        expect(
            fixture.session.state.chrome.destination == .eventsAndSounds,
            "Up returns to the previous real row")
        let revision = fixture.session.navigationHistory.version
        probe.sendSidebarKey(126)
        expect(
            fixture.session.navigationHistory.version == revision,
            "The first-row boundary emits no navigation")
        fixture.session.send(.setNavigationBlocked(id: "sheet", blocked: true))
        probe.sendSidebarKey(125)
        expect(
            fixture.session.navigationHistory.version == revision,
            "A sheet blocks the same native arrow-key path")
        fixture.session.send(.setNavigationBlocked(id: "sheet", blocked: false))
    }
    await suite("Settings native content: Login toggle invokes its existing owner") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            loginItemRegistration: .disabled,
            availability: PreviewFixtures.settingsRouteAvailability)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        await probe.settle()
        expect(
            probe.changeNativeSwitch(
                SettingsPresentationAccessibilityID.loginItemToggle, isOn: true),
            "The compiled native Login switch invokes its target/action binding")
        expect(
            fixture.session.state.loginItemRegistration == .enabled,
            "The binding updates the retained login projection")
    }
}

@MainActor
final class SettingsRootNativeProbe {
    private let window: RetainedSettingsWindow
    private let hostingView: NSView
    private let shell: SettingsNativeShellController
    private let session: SettingsPresentationSession
    private let size = NSSize(width: 1_240, height: 820)
    private var eventNumber = 1

    init(session: SettingsPresentationSession) {
        _ = NSApplication.shared
        SoundPacksLayoutRecorder.reset()
        self.session = session
        shell = SettingsNativeShellController(session: session)
        window = RetainedSettingsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        hostingView = shell.view
        window.contentViewController = shell
        shell.install(in: window)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.presentForUserRequest()
        refresh()
    }

    var hasAttachedSheet: Bool {
        refresh()
        return window.attachedSheet != nil || !window.sheets.isEmpty
    }

    var isActiveKeyWindow: Bool { window.isKeyWindow }

    var isNativeListFocused: Bool { window.firstResponder === shell.sidebarController.table }

    var focusedPopUpItems: [String]? {
        (window.firstResponder as? NSPopUpButton)?.itemTitles
    }

    var focusedPopUpSelection: String? {
        (window.firstResponder as? NSPopUpButton)?.titleOfSelectedItem
    }

    func activate() {
        window.center()
        window.presentForUserRequest()
        refresh()
    }

    func settle() async { for _ in 0..<4 { await Task.yield(); refresh() } }

    func selectSidebar(_ destination: SettingsDestination, horizontalFraction: CGFloat) -> Bool {
        refresh()
        let table = shell.sidebarController.table
        guard let frame = shell.sidebarController.frame(for: destination) else { return false }
        let point = NSPoint(x: frame.minX + frame.width * horizontalFraction, y: frame.midY)
        let row = table.row(at: point)
        guard row >= 0 && table.hitTest(point) != nil else { return false }
        if table.selectedRow == row {
            table.reselectRow(row)
        } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return true
    }

    func sendSidebarKey(_ keyCode: UInt16) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
        else { return }
        shell.sidebarController.table.keyDown(with: event)
    }

    func clickSidebar(
        _ destination: SettingsDestination,
        horizontalFraction: CGFloat
    ) -> Bool {
        refresh()
        guard
            let frame = SoundPacksLayoutRecorder.frames[
                "settings.sidebar.item.\(destination.rawValue)"]
        else { return false }
        let x = frame.minX + frame.width * horizontalFraction
        return click(windowPoint: NSPoint(x: x, y: size.height - frame.midY))
    }

    func clickOutsideSidebarRow(_ destination: SettingsDestination) -> Bool {
        refresh()
        guard
            let frame = SoundPacksLayoutRecorder.frames[
                "settings.sidebar.item.\(destination.rawValue)"]
        else { return false }
        let sidebarWidth = CGFloat(
            settingsSidebarWidth(windowWidth: size.width))
        return click(windowPoint: NSPoint(x: sidebarWidth + 4, y: size.height - frame.midY))
    }

    func clickContent(x: CGFloat, yFromTop: CGFloat) -> Bool {
        click(windowPoint: NSPoint(x: x, y: size.height - yFromTop))
    }

    func clickRecordedControl(_ identifier: String) -> Bool {
        refresh()
        guard let frame = SoundPacksLayoutRecorder.frames[identifier] else { return false }
        return clickContent(x: frame.maxX - 16, yFromTop: frame.midY)
    }

    func changeNativeSwitch(_ identifier: String, isOn: Bool) -> Bool {
        refresh()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard
            let control = descendants(hostingView).compactMap({ $0 as? NSSwitch })
                .first(where: { $0.accessibilityIdentifier() == identifier })
        else { return false }
        control.state = isOn ? .on : .off
        let sent = control.sendAction(control.action, to: control.target)
        refresh()
        return sent
    }

    func sendKey(
        keyCode: UInt16, characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode),
            let up = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode)
        else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        refresh()
        return true
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        session.send(.windowWillClose)
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private func click(windowPoint: NSPoint) -> Bool {
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: 1),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber + 1,
                clickCount: 1,
                pressure: 1)
        else { return false }
        eventNumber += 2
        window.sendEvent(down)
        window.sendEvent(up)
        refresh()
        return true
    }

    private func refresh() {
        hostingView.layoutSubtreeIfNeeded()
        shell.synchronizeLayout()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
