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

    await runSettingsNativeReadingSuites()

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
                            probe.window.contentView?.bounds.size
                                == NSSize(width: width, height: width == 960 ? 640 : 820),
                            "Layout fixture must retain the requested content size; actual=\(String(describing: probe.window.contentView?.bounds.size))"
                        )
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
func runSettingsNativeReadingSuites() async {
    await suite("Native settings shell: later activity groups retain reading position") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.usage))
        let probe = NativeSettingsShellProbe(session: fixture.session, width: 960, dark: false)
        defer { probe.close() }
        await probe.presentAndSettle()
        expect(probe.window.isKeyWindow, "Reading restoration exercises a real key window")
        guard probe.window.isKeyWindow, let maximum = probe.maximumReadingOffset,
            let viewportHeight = probe.readingScrollView?.contentView.bounds.height
        else { return }
        let groups = probe.readingFrames(identifier: "settings.semantic-surface.group")
            .sorted { $0.minY < $1.minY }
        expect(groups.count > 1, "The actual activity page contains repeated group backgrounds")
        guard let first = groups.first,
            let later = groups.dropFirst().last(where: {
                $0.minY > first.minY + 100 && $0.minY < maximum + viewportHeight
            })
        else {
            expect(false, "The native activity fixture exposes a later scrollable functional group")
            return
        }
        expect(probe.scrollReading(to: min(maximum, later.minY - 1)), "Scroll to a later group")
        await probe.presentAndSettle()
        guard let originalOffset = probe.readingOffset,
            let bookmark = fixture.session.captureReadingPosition?()
        else {
            expect(false, "The shell captures the mounted page's reading bookmark")
            return
        }
        expect(originalOffset > first.minY + 100, "The reading position is beyond the first group")
        if let identifier = bookmark.scrollAnchorIdentifier {
            expect(
                probe.readingFrames(identifier: identifier).count == 1
                    && !identifier.hasPrefix("settings.semantic-surface."),
                "A captured scroll anchor identifies one semantic view: \(identifier)")
        }
        probe.shell.sidebarController.focusSelection()
        expect(
            probe.window.firstResponder === probe.shell.sidebarController.table,
            "Leaving via the sidebar establishes the actual native list responder")
        fixture.session.send(.selectSidebar(.general))
        await probe.presentAndSettle()
        fixture.session.send(.goBack)
        await probe.presentAndSettle()
        expect(
            fixture.session.state.chrome.destination == .usage
                && fixture.session.state.navigationRestoration == nil,
            "Back consumes the activity page's actual ready restoration request: \(probe.readingRestorationStatus)"
        )
        expect(
            abs((probe.readingOffset ?? -1) - originalOffset) < 2,
            "Back retains later activity reading position: before=\(originalOffset), after=\(probe.readingOffset ?? -1)"
        )
    }

    await suite("Native settings shell: ambiguous saved anchors use the relative fallback") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.usage))
        let probe = NativeSettingsShellProbe(session: fixture.session, width: 960, dark: false)
        defer { probe.close() }
        await probe.presentAndSettle()
        expect(probe.window.isKeyWindow, "Ambiguous-anchor restoration exercises a real key window")
        guard probe.window.isKeyWindow, let maximum = probe.maximumReadingOffset,
            let stamp = fixture.session.navigationHistory.stamp
        else { return }
        expect(maximum > 100, "The real activity page has a scrollable reading range")
        expect(
            probe.readingFrames(identifier: "settings.semantic-surface.group").count > 1,
            "A saved decorative identifier is ambiguous on the mounted page")
        fixture.session.send(.setNavigationBlocked(id: "reading-fixture", blocked: true))
        fixture.session.send(
            .rememberReading(
                .init(
                    scrollAnchorIdentifier: "settings.semantic-surface.group", anchorOffset: 0,
                    relativeScrollPosition: 0.72), stamp: stamp))
        expect(probe.scrollReading(to: 0), "Move away from the saved reading position")
        fixture.session.send(.setNavigationBlocked(id: "reading-fixture", blocked: false))
        await probe.presentAndSettle()
        let expected = (probe.maximumReadingOffset ?? maximum) * 0.72
        expect(
            fixture.session.state.navigationRestoration == nil,
            "Cancel consumes the mounted page's restoration request: \(probe.readingRestorationStatus)"
        )
        expect(
            abs((probe.readingOffset ?? -1) - expected) < 2,
            "An ambiguous anchor restores the normalized position: expected=\(expected), actual=\(probe.readingOffset ?? -1)"
        )
    }
}

@MainActor
final class NativeSettingsShellProbe: NSObject, NSWindowDelegate {
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
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = shell
        shell.install(in: window)
        window.setContentSize(NSSize(width: width, height: width == 960 ? 640 : 820))
        window.title = ClaudioL10n(language: session.state.language).text(.settingsWindowTitle)
        window.presentForUserRequest()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else {
            return
        }
        session.send(.windowPhaseChanged(.key))
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else {
            return
        }
        session.send(.windowPhaseChanged(.visibleNonKey))
    }
    func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            pumpNativeRunLoop()
        }
    }
    func presentAndSettle() async {
        // Match an explicit foreground Settings request; do not bypass native key/readiness guards.
        window.presentForUserRequest()
        await settle()
        for _ in 0..<32 {
            if window.isKeyWindow,
                session.renderedNavigationStamp == session.navigationHistory.stamp,
                session.state.navigationRestoration == nil
            {
                return
            }
            // SwiftUI can clear its prior FocusState while mounting a new destination. Wait for
            // that real mount, then repeat the probe's explicit native foreground request.
            if session.renderedNavigationStamp == session.navigationHistory.stamp,
                !window.isKeyWindow
            {
                window.makeKey()
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
    var readingRestorationStatus: String {
        let request = session.state.navigationRestoration
        return
            "key=\(window.isKeyWindow), canKey=\(window.canBecomeKey), visible=\(window.isVisible), deferred=\(window.defersAutomaticFocusForPanel), appKey=\(NSApp.keyWindow === window), shellWindow=\(shell.view.window === window), stamp=\(request?.stamp == session.navigationHistory.stamp), ready=\(session.renderedNavigationStamp == session.navigationHistory.stamp), requestReady=\(request?.stamp == session.renderedNavigationStamp), enabled=\(session.state.chrome.navigationEnabled), sheet=\(window.attachedSheet != nil), request=\(String(describing: request?.focus))"
    }
    var readingScrollView: NSScrollView? {
        guard shell.splitViewItems.count == 2 else { return nil }
        return descendants(shell.splitViewItems[1].viewController.view)
            .compactMap { $0 as? NSScrollView }
            .max { $0.bounds.height < $1.bounds.height }
    }
    var readingOffset: CGFloat? { readingScrollView?.contentView.bounds.minY }
    var maximumReadingOffset: CGFloat? {
        guard let scroll = readingScrollView, let document = scroll.documentView else { return nil }
        return max(0, document.bounds.height - scroll.contentView.bounds.height)
    }
    func readingFrames(identifier: String) -> [CGRect] {
        guard let document = readingScrollView?.documentView else { return [] }
        return descendants(document).filter { $0.accessibilityIdentifier() == identifier }
            .map { document.convert($0.bounds, from: $0) }
    }
    func scrollReading(to offset: CGFloat) -> Bool {
        guard let scroll = readingScrollView, let maximum = maximumReadingOffset else {
            return false
        }
        let target = min(maximum, max(0, offset))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        return abs(scroll.contentView.bounds.minY - target) < 2
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
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
        window.delegate = nil
        session.send(.windowWillClose)
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}
