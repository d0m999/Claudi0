import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@testable import ClaudioSettingsPresentation

@MainActor
func runSettingsNavigationRowSuites() async {
    for language in [ClaudioAppLanguage.zhHans, .english] {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/navigation-row"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let workspace = PanelSoundScopeID.workspace(rule.id)
        let cases: [(SettingsRoute, String, SettingsDestination)] = [
            (.destination(.integrations), "integrations.destination.activity-diagnostics", .usage),
            (
                .integrations(IntegrationsSettingsRoute(surface: .codex, detailsHost: .codex)),
                "integrations.destination.manage-events.codex", .eventsAndSounds
            ),
            (.events(scope: .global, event: nil), "workspace.manage-sounds", .sounds),
            (.events(scope: workspace, event: nil), "workspace.manage-sounds", .sounds),
            (.events(scope: workspace, event: nil), "workspace.manage-connections", .integrations),
            (.destination(.notifications), "settings.notifications.open-events", .eventsAndSounds),
        ]
        for (source, identifier, destination) in cases {
            for key: UInt16 in [49, 36] {
                await suite("Settings navigation row: \(identifier)/\(source)/\(language)/\(key)") {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: source, workspaceRules: [rule])
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: 960, dark: language == .english)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    let reached = await settingsKeyboardTabTo(identifier, in: probe.window)
                    expect(reached, "Tab reaches the persistent forward entry \(identifier)")
                    guard reached else { return }
                    let session = fixture.session
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    let config = try? encoder.encode(fixture.eventSettingsModel.config)
                    let scope = fixture.eventSettingsModel.selectedSoundScope
                    let persisted = fixture.eventSettingsModel.soundScopeSelection.projection
                        .persistedStoredValue
                    let origin = session.navigationHistory.current?.location
                    let offset = probe.readingOffset
                    let version = session.navigationHistory.version
                    let cursor = session.navigationHistory.cursor
                    let row = probe.window.firstResponder as? NSView
                    expect(row?.accessibilityRole() == .button, "The row is one native button")
                    expect(
                        row?.accessibilityChildren()?.isEmpty == true,
                        "The label and decorative arrow are not additional accessible elements")
                    settingsKeyboardPress(key, key == 49 ? " " : "\r", in: probe.window)
                    guard await probe.presentAndSettle() else { return }
                    expect(
                        session.navigationHistory.version == version + 1
                            && session.navigationHistory.cursor == cursor + 1,
                        "One key activation creates exactly one visit")
                    expect(
                        session.state.routeResolution.destination == destination,
                        "The entry retains its existing destination")
                    let sidebar = probe.shell.sidebarController.table
                    expect(
                        sidebar.rowView(atRow: sidebar.selectedRow, makeIfNecessary: true)?
                            .accessibilityIdentifier()
                            == "settings.sidebar.\(destination.sidebarDestination.rawValue)",
                        "Diagnostics belongs to Connections and the other destinations retain their sidebar"
                    )
                    if identifier == "workspace.manage-sounds" {
                        if case .sounds(let route) = session.state.routeResolution.route {
                            expect(
                                route.scope == scope && route.destination == .overview,
                                "Manage sounds retains the captured scope")
                            expect(
                                route.workspaceTarget
                                    == (scope == workspace
                                        ? WorkspaceSoundWriteTarget(rule: rule) : nil),
                                "Manage sounds retains the workspace directory identity")
                        } else {
                            expect(false, "Manage sounds has a typed sounds route")
                        }
                    }
                    session.send(.goBack)
                    guard await probe.presentAndSettle() else { return }
                    expect(
                        session.navigationHistory.current?.location == origin,
                        "Back restores the captured browsing location")
                    expect(
                        settingsKeyboardFocusedIdentifier(in: probe.window) == identifier,
                        "Back restores focus to the original navigation row")
                    expect(
                        abs((probe.readingOffset ?? 0) - (offset ?? 0)) < 2,
                        "Back restores the original reading position")
                    let modal = NSAlert()
                    modal.messageText = "Navigation fixture"
                    modal.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
                    modal.beginSheetModal(for: probe.window, completionHandler: { _ in })
                    let blocked = await settingsKeyboardWait {
                        probe.window.attachedSheet === modal.window
                            && !session.state.chrome.navigationEnabled
                    }
                    expect(blocked, "An attached native sheet blocks outer navigation")
                    let blockedStamp = session.navigationHistory.stamp
                    // AX can still address an underlying view while the sheet owns key dispatch.
                    _ = settingsKeyboardAXElements(probe.shell.view).first {
                        $0.accessibilityIdentifier?() == identifier
                    }?.accessibilityPerformPress?()
                    expect(
                        session.navigationHistory.stamp == blockedStamp,
                        "The underlying navigation row cannot change history during a sheet")
                    settingsKeyboardPress(53, "\u{1b}", in: modal.window)
                    guard await probe.presentAndSettle() else { return }
                    expect(
                        session.navigationHistory.current?.location == origin,
                        "Cancelling the sheet retains the original navigation location")
                    session.send(.goForward)
                    guard await probe.presentAndSettle() else { return }
                    expect(
                        session.state.routeResolution.destination == destination,
                        "Forward restores the destination")
                    expect(
                        (try? encoder.encode(fixture.eventSettingsModel.config)) == config
                            && fixture.eventSettingsModel.selectedSoundScope == scope
                            && fixture.eventSettingsModel.soundScopeSelection.projection
                                .persistedStoredValue == persisted
                            && fixture.actionRecorder.actions.isEmpty,
                        "Navigation does not write configuration, scope selection or platform actions"
                    )
                }
            }
        }
    }
}

@MainActor
func runSettingsNavigationRowLayoutSuites() async {
    for language in [ClaudioAppLanguage.zhHans, .english] {
        for dark in [false, true] {
            for width: CGFloat in [960, 1240] {
                let rule = WorkspaceSoundRule(
                    directory: WorkspaceDirectory(
                        kind: .directory, path: "/fixture/navigation-layout"),
                    surfaces: [.codex],
                    profile: WorkspaceSoundProfile(
                        selectedPack: "settings-fixture-pack", volume: 0.7))
                let cases: [(SettingsRoute, String)] = [
                    (.destination(.integrations), "integrations.destination.activity-diagnostics"),
                    (
                        .integrations(
                            IntegrationsSettingsRoute(surface: .codex, detailsHost: .codex)),
                        "integrations.destination.manage-events.codex"
                    ),
                    (.events(scope: .global, event: nil), "workspace.manage-sounds"),
                    (.events(scope: .workspace(rule.id), event: nil), "workspace.manage-sounds"),
                    (
                        .events(scope: .workspace(rule.id), event: nil),
                        "workspace.manage-connections"
                    ),
                    (.destination(.notifications), "settings.notifications.open-events"),
                ]
                for (index, item) in cases.enumerated() {
                    await suite("Settings navigation layout: \(index)/\(language)/\(dark)/\(width)")
                    {
                        let fixture = SettingsPresentationFixtures.generalLogin(
                            language: language, route: item.0, workspaceRules: [rule])
                        let probe = NativeSettingsShellProbe(
                            session: fixture.session, width: width, dark: dark)
                        defer { probe.close() }
                        guard await probe.presentAndSettle() else { return }
                        let reached = await settingsKeyboardTabTo(item.1, in: probe.window)
                        expect(reached, "Tab reaches the navigation row")
                        guard reached, let row = probe.window.firstResponder as? NSView else {
                            return
                        }
                        expect(
                            row.bounds.width > 300 && row.bounds.height >= 38,
                            "The entire group row provides its hit region: \(row.bounds)")
                        expect(
                            row.visibleRect.height >= row.bounds.height - 1,
                            "Focused navigation row scrolls fully into view: \(row.visibleRect) / \(row.bounds)"
                        )
                        let frame = row.convert(row.bounds, to: probe.window.contentView)
                        expect(
                            frame.minX >= 0 && frame.maxX <= width,
                            "The navigation row is not clipped horizontally")
                        let elements = settingsKeyboardAXElements(probe.shell.view).filter {
                            $0.accessibilityIdentifier?() == item.1
                                && $0.accessibilityRole?() == .button
                        }
                        expect(elements.count == 1, "The row exposes one accessible action")
                        if let directory = ProcessInfo.processInfo.environment[
                            "CLAUDIO_SETTINGS_NAVIGATION_CAPTURE_DIR"]
                        {
                            probe.capture(
                                to: URL(fileURLWithPath: directory).appendingPathComponent(
                                    "row-\(index)-\(language.rawValue)-\(dark)-\(Int(width)).png"))
                        }
                    }
                }
            }
        }
    }
    await suite("Settings navigation layout: long label, whole-row hit and disabled action") {
        var actions = 0
        let title = String(repeating: "工作区声音设置 Workspace Sound Settings ", count: 4)
        let host = NSHostingView(
            rootView: VStack {
                SettingsNavigationRow(title: title, identifier: "row.long") { actions += 1 }
                SettingsNavigationRow(title: "Disabled", identifier: "row.disabled") {
                    actions += 100
                }
                .disabled(true)
            }.padding(20).frame(width: 350))
        let window = RetainedSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.presentForUserRequest()
        let ready = await settingsKeyboardWait {
            window.isKeyWindow && settingsKeyboardWindowOrder().contains(window.windowNumber)
        }
        expect(ready, "The long-label fixture owns key dispatch")
        guard ready else { return }
        host.layoutSubtreeIfNeeded()
        @MainActor func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        guard let row = views(host).first(where: { $0.accessibilityIdentifier() == "row.long" }),
            let disabled = views(host).first(where: {
                $0.accessibilityIdentifier() == "row.disabled"
            })
        else { expect(false, "Both row controls mount"); return }
        expect(
            row.bounds.height > 60 && row.bounds.width <= 310,
            "A long label wraps within the parent's width")
        expect(row.accessibilityLabel() == title, "The complete long label remains accessible")
        if let directory = ProcessInfo.processInfo.environment[
            "CLAUDIO_SETTINGS_NAVIGATION_CAPTURE_DIR"],
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("row-long-disabled.png"))
        }
        expect(
            !disabled.acceptsFirstResponder && !disabled.isAccessibilityEnabled()
                && !disabled.accessibilityPerformPress(),
            "Disabled rows cannot be focused or activated through AX")
        for target in [disabled, row] {
            let point = target.convert(
                NSPoint(x: target.bounds.maxX - 3, y: target.bounds.midY), to: nil)
            guard
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { expect(false, "Create a window mouse event"); return }
            window.sendEvent(event)
        }
        expect(
            actions == 1,
            "The trailing whole-row region activates once; the disabled row stays inert")
    }
}
