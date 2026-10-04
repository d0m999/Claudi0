import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsNativeShellSuites() async {
    NSApplication.shared.setActivationPolicy(.accessory)
    await suite("Native settings shell: toolbar, source list and keyboard transaction") {
        let fixture = SettingsPresentationFixtures.generalLogin()
        let probe = NativeSettingsShellProbe(session: fixture.session, width: 960, dark: false)
        defer { probe.close() }
        await probe.settle()
        let window = probe.window
        let shell = probe.shell
        expect(
            NSApp.activationPolicy() == .accessory
                && window.styleMask.contains(.nonactivatingPanel),
            "The sample uses the actual accessory nonactivating retained window")
        expect(
            window.toolbar != nil && window.toolbarStyle == .unified
                && window.titleVisibility == .hidden,
            "The real unified toolbar owns the single visible page title")
        expect(
            shell.splitViewItems.count == 2 && !shell.splitViewItems[0].canCollapse,
            "The shell has a native fixed sidebar split item and one destination")
        expect(
            shell.sidebarController.table.style == .sourceList
                && !shell.sidebarController.table.allowsMultipleSelection,
            "Sidebar uses a native single-selection source list")
        expect(
            abs(shell.sidebarController.view.bounds.width - 210) < 2,
            "Minimum width preserves 210 pt sidebar")
        expect(
            shell.navigationControl.segmentCount == 2
                && shell.navigationControl.trackingMode == .momentary,
            "Back and Forward are one native momentary control")
        fixture.session.send(.selectSidebar(.notifications))
        await probe.settle()
        shell.sidebarController.focusSelection()
        let version = fixture.session.navigationHistory.version
        shell.sidebarController.table.onMove?(.next)
        await probe.settle()
        expect(
            fixture.session.state.chrome.destination == .general
                && fixture.session.navigationHistory.version == version + 1,
            "Keyboard skips the group spacer and selects exactly one position")
        if window.isKeyWindow {
            expect(
                window.firstResponder === shell.sidebarController.table,
                "Mouse/keyboard selection retains the native table responder")
        } else {
            expect(
                fixture.session.state.navigationRestoration?.focus == .sidebar
                    && fixture.session.renderedNavigationStamp
                        == fixture.session.navigationHistory.stamp,
                "A background window retains the ready sidebar focus request without stealing key focus"
            )
            print("  Native key-window keyboard behavior: NOT VERIFIED (window did not become key)")
        }
        let echoed = fixture.session.navigationHistory.version
        shell.sidebarController.update(fixture.session.state)
        expect(
            fixture.session.navigationHistory.version == echoed,
            "Projection writeback does not echo another route")
        fixture.session.send(.selectSidebar(.eventsAndSounds))
        await probe.settle()
        let boundary = fixture.session.navigationHistory.version
        shell.sidebarController.table.onMove?(.previous)
        expect(
            fixture.session.navigationHistory.version == boundary,
            "The first sidebar row has a stable arrow-key boundary")
        expect(
            !shell.pageTitle.acceptsFirstResponder, "The toolbar heading is not a static Tab stop")
        expect(
            shell.pageTitle.accessibilityRole()?.rawValue == "AXHeading",
            "The single toolbar page title retains heading semantics")
        fixture.session.send(.setNavigationBlocked(id: "fixture-sheet", blocked: true))
        await probe.settle()
        expect(
            !shell.navigationControl.isEnabled(forSegment: 0),
            "Sheet state disables native navigation")
        fixture.session.send(.setNavigationBlocked(id: "fixture-sheet", blocked: false))
    }

    await suite("Native settings shell: 64 basic layout combinations") {
        for destination in SettingsDestination.allCases {
            for language in ClaudioAppLanguage.allCases {
                for dark in [false, true] {
                    for width: CGFloat in [960, 1240] {
                        let fixture = SettingsPresentationFixtures.generalLogin(
                            language: language, route: .destination(destination))
                        let probe = NativeSettingsShellProbe(
                            session: fixture.session, width: width, dark: dark)
                        await probe.settle()
                        expect(
                            probe.shell.pageTitle.stringValue
                                == destination.localizedName(language: language),
                            "\(destination)/\(language)/\(dark)/\(width) title=\(probe.shell.pageTitle.stringValue), route=\(fixture.session.state.routeResolution.route)"
                        )
                        expect(
                            abs(
                                probe.shell.sidebarController.view.bounds.width
                                    - (width == 960 ? 210 : 252)) < 2,
                            "\(destination)/\(language)/\(dark)/\(width) sidebar=\(probe.shell.sidebarController.view.bounds.width), shell=\(probe.shell.view.bounds.width)"
                        )
                        expect(
                            probe.shell.view.bounds.width <= width + 1,
                            "Shell stays within the window width")
                        for (index, name) in [
                            language == .english ? "Back" : "返回",
                            language == .english ? "Forward" : "前进",
                        ].enumerated() {
                            expect(
                                probe.shell.navigationControl.image(forSegment: index)?
                                    .accessibilityDescription == name
                                    && probe.shell.navigationControl.toolTip(forSegment: index)
                                        == name,
                                "History navigation keeps its generic bilingual name on every page")
                        }
                        if let directory = ProcessInfo.processInfo.environment[
                            "CLAUDIO_SETTINGS_NATIVE_CAPTURE_DIR"]
                        {
                            probe.capture(
                                to: URL(fileURLWithPath: directory).appendingPathComponent(
                                    "\(destination.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                                ))
                        }
                        probe.close()
                    }
                }
            }
        }
    }
}

@MainActor
final class NativeSettingsShellProbe {
    let window: RetainedSettingsWindow
    let shell: SettingsNativeShellController
    let session: SettingsPresentationSession
    init(session: SettingsPresentationSession, width: CGFloat, dark: Bool) {
        self.session = session
        shell = SettingsNativeShellController(session: session)
        window = RetainedSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: width == 960 ? 640 : 820),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = shell
        shell.install(in: window)
        window.setContentSize(NSSize(width: width, height: width == 960 ? 640 : 820))
        window.title = ClaudioL10n(language: session.state.language).text(.settingsWindowTitle)
        window.presentForUserRequest()
        session.send(.windowPhaseChanged(.key))
    }
    func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            pumpNativeRunLoop()
        }
    }
    private func pumpNativeRunLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015)) }
    func capture(to url: URL) {
        guard let view = window.contentView?.superview,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
    func close() {
        session.send(.windowWillClose)
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}
