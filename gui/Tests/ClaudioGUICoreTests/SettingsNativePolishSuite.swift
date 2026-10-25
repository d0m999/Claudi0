import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsNativePolishSuites() async {
    for language in ClaudioAppLanguage.allCases {
        for dark in [false, true] {
            for width: CGFloat in [960, 1240] {
                await suite(
                    "Settings polish: update switch and sound headings \(language)/\(dark)/\(width)"
                ) {
                    let facts = makeSettingsFixtureAboutSettings(for: nil)
                    let updates = AppUpdateModel(isPublicPreview: true)
                    let about = AboutSettingsModel(
                        bundleFacts: facts.bundleFacts, resources: facts.resources,
                        pathFacts: facts.pathFacts, surfaceFacts: facts.surfaceFacts,
                        actions: .init(copy: { _ in true }, open: { _ in true }),
                        appUpdates: updates)
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, aboutSettings: about)
                    var writes: [Bool] = []
                    updates.connect(
                        check: {}, sessionInProgress: { false },
                        setAutomaticChecks: { writes.append($0) })
                    updates.project(state: .idle, canCheck: true, automaticChecks: false)
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    await probe.presentAndSettle()
                    let l10n = ClaudioL10n(language: language)
                    _ = polishAXElements(probe.shell.view)
                    expect(
                        polishAXElements(probe.shell.view).contains {
                            polishText($0) == l10n.text(.appUpdatePublicPreview)
                        }, "The public-preview heading mounts in both languages and appearances")
                    let switches = polishViews(probe.shell.view).compactMap { $0 as? NSSwitch }
                    let control = switches.first {
                        $0.accessibilityLabel() == l10n.text(.appUpdateAutomatic)
                            || polishText($0.accessibilityTitleUIElement() as AnyObject?)
                                == l10n.text(.appUpdateAutomatic)
                    }
                    expect(
                        control != nil,
                        "Automatic checks retain their accessible title"
                    )
                    expect(control?.controlSize == .mini, "Automatic checks use a mini NSSwitch")
                    capturePolish(probe, "general-\(language.rawValue)-\(dark)-\(Int(width))")
                    _ = control?.accessibilityPerformPress()
                    expect(
                        writes == [true] && !updates.automaticallyChecksForUpdates,
                        "Activation requests one adapter write without inventing confirmation")
                    updates.project(state: .idle, canCheck: true, automaticChecks: true)
                    await probe.settle()
                    expect(
                        control?.state == .on,
                        "The switch follows the confirmed adapter value")
                    updates.project(
                        state: .unavailable(.configuration), canCheck: false, automaticChecks: false
                    )
                    await probe.settle()
                    expect(
                        !polishViews(probe.shell.view).compactMap { $0 as? NSSwitch }.contains {
                            $0.accessibilityLabel() == l10n.text(.appUpdateAutomatic)
                                || polishText($0.accessibilityTitleUIElement() as AnyObject?)
                                    == l10n.text(.appUpdateAutomatic)
                        }, "Unavailable updates remove the control")

                    fixture.session.send(.route(.sounds(.overview)))
                    await probe.presentAndSettle()
                    let headings = polishAXElements(
                        probe.readingScrollView?.documentView ?? probe.shell.view
                    )
                    .filter { $0.accessibilityRole?()?.rawValue == "AXHeading" }
                    expect(
                        !headings.contains {
                            polishText($0) == l10n.text(.settingsDestinationSounds)
                        }, "The list does not repeat the toolbar's Sound Packs heading")
                    expect(
                        probe.shell.pageTitle.stringValue == l10n.text(.settingsDestinationSounds)
                            && probe.shell.pageTitle.accessibilityRole()?.rawValue == "AXHeading",
                        "The native toolbar retains the page's accessible heading")
                    capturePolish(probe, "sounds-\(language.rawValue)-\(dark)-\(Int(width))")
                    fixture.session.send(.inspectSoundPack("settings-fixture-pack"))
                    await probe.presentAndSettle()
                    expect(
                        polishAXElements(probe.readingScrollView?.documentView ?? probe.shell.view)
                            .contains { $0.accessibilityRole?()?.rawValue == "AXHeading" },
                        "Pack detail retains its own heading")
                    fixture.session.send(
                        .route(
                            .sounds(SoundPacksWindowRoute(scope: .global, destination: .history))))
                    await probe.presentAndSettle()
                    expect(
                        polishAXElements(probe.readingScrollView?.documentView ?? probe.shell.view)
                            .contains {
                                $0.accessibilityRole?()?.rawValue == "AXHeading"
                                    && polishText($0) == l10n.text(.soundsHistory)
                            }, "Generation history retains its own heading")
                }

                await suite(
                    "Settings polish: diagnostics keyboard route \(language)/\(dark)/\(width)"
                ) {
                    let route = SettingsRoute.integrations(
                        .init(surface: .codex, level: .application))
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: route)
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    await probe.presentAndSettle()
                    capturePolish(probe, "connections-\(language.rawValue)-\(dark)-\(Int(width))")
                    for keyCode: UInt16 in [49, 36] {
                        guard
                            let control = polishAXElements(probe.shell.view).first(where: {
                                $0.accessibilityLabel?()
                                    == ClaudioL10n(language: language).text(
                                        .integrationsAutoDiagnostics)
                            }) as? NSView
                        else {
                            expect(false, "Diagnostics mounts a native keyboard focus stop"); break
                        }
                        expect(
                            control.accessibilityLabel()
                                == ClaudioL10n(language: language).text(
                                    .integrationsAutoDiagnostics),
                            "The disclosure preserves its localized action name")
                        expect(
                            probe.window.makeFirstResponder(control),
                            "The disclosure accepts keyboard focus")
                        let version = fixture.session.navigationHistory.version
                        let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: probe.window.windowNumber, context: nil,
                            characters: keyCode == 49 ? " " : "\r",
                            charactersIgnoringModifiers: keyCode == 49 ? " " : "\r",
                            isARepeat: false, keyCode: keyCode)!
                        control.keyDown(with: event)
                        await probe.presentAndSettle()
                        expect(
                            fixture.session.state.routeResolution.route
                                == .integrations(
                                    .init(surface: .codex, detailsHost: .codex, level: .diagnostics)
                                ) && fixture.session.navigationHistory.version == version + 1,
                            "Space/Return navigate exactly once to this host's diagnostics")
                        fixture.session.send(.goBack)
                        await probe.presentAndSettle()
                        expect(
                            fixture.session.state.routeResolution.route == route
                                && fixture.actionRecorder.actions.isEmpty,
                            "Back restores host detail without platform effects")
                    }
                }
            }
        }
    }

    for action in [ActivityDiagnosticsAction.clearActivity, .clearLog] {
        await suite("Settings polish: destructive action progress \(action)") {
            let gate = AsyncStream<Void>.makeStream()
            let log = ActivityDiagnosticLogSnapshot(
                path: "/fixture/claudio.log", state: .missing, failures: [])
            let load = ActivityDiagnosticsLoadResult(readResult: .init(state: .missing), log: log)
            let model = ActivityDiagnosticsModel(
                operations: ActivityDiagnosticsOperations(
                    load: { load },
                    clearActivity: {
                        for await _ in gate.stream { break }
                        return .success(load)
                    },
                    clearLog: {
                        for await _ in gate.stream { break }
                        return .success(log)
                    },
                    revealLog: { true }, copyLogPath: { true }))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.usage), activityDiagnostics: model)
            let probe = NativeSettingsShellProbe(
                session: fixture.session, width: 960, dark: action == .clearLog)
            defer { probe.close() }
            await probe.presentAndSettle()
            _ = probe.scrollReading(to: probe.maximumReadingOffset ?? 0)
            await probe.settle()
            let l10n = ClaudioL10n(language: fixture.preferences.language)
            let title = l10n.text(
                action == .clearActivity ? .settingsUsageClearHistory : .settingsUsageClearLog)
            @MainActor func button() -> AnyObject? {
                polishAXElements(probe.shell.view).first {
                    $0.accessibilityRole?() == .button && polishText($0) == title
                }
            }
            capturePolish(probe, "activity-\(action)")
            expect(
                polishText(button()) == title, "The idle clear action retains its localized name")
            if action == .clearActivity { model.clearActivity() } else { model.clearLog() }
            await probe.settle()
            expect(model.activeActions == [action], "Only the confirmed operation is running")
            let progress = polishAXElements(probe.shell.view).first {
                $0.accessibilityRole?()?.rawValue == "AXBusyIndicator"
                    && polishText($0) == l10n.text(.settingsUsageActionInProgress)
            }
            expect(
                progress?.isAccessibilityEnabled?() == false,
                "The clear control is disabled during its operation")
            expect(
                polishText(progress) == l10n.text(.settingsUsageActionInProgress),
                "The action retains its progress label")
            capturePolish(probe, "activity-progress-\(action)")
            gate.continuation.yield(())
            gate.continuation.finish()
            await probe.settle()
            expect(
                model.feedback == .init(action: action, failure: nil) && !model.isOperationActive,
                "Completion restores the idle action and success feedback")
            expect(
                polishText(button()) == title && button()?.isAccessibilityEnabled?() == true,
                "The original action name and enabled state return")
        }
    }
}

@MainActor
private func polishViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(polishViews)
}

@MainActor
private var polishAXPrepared = false

@MainActor
private func polishAXElements(_ root: NSView) -> [AnyObject] {
    if !polishAXPrepared {
        polishAXPrepared = true
        NSApplication.shared.finishLaunching()
        let completed = DispatchSemaphore(value: 0)
        let processID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global().async {
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 1)
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
            completed.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while completed.wait(timeout: .now()) != .success && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }
    var elements: [AnyObject] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ element: AnyObject) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        elements.append(element)
        for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject) }
    }
    visit(root)
    return elements
}

@MainActor
private func polishText(_ element: AnyObject?) -> String? {
    guard let element else { return nil }
    if let label = element.accessibilityLabel?(), !label.isEmpty { return label }
    let role = element.accessibilityRole?()
    if role == .staticText || role?.rawValue == "AXHeading" {
        let value: String? = element.accessibilityValue?()
        return value
    }
    let text = (element.accessibilityChildren?() ?? [])
        .compactMap { polishText($0 as AnyObject) }.joined(separator: " ")
    return text.isEmpty ? nil : text
}

@MainActor
private func capturePolish(_ probe: NativeSettingsShellProbe, _ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["CLAUDIO_SETTINGS_POLISH_CAPTURE_DIR"]
    else { return }
    probe.capture(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}
