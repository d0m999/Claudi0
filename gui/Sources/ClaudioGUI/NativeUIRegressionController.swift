#if DEBUG && CLAUDIO_UI_REGRESSION
import AppKit
import Combine
import ClaudioCore
import ClaudioGUICore
import ClaudioGUIComponents
import ClaudioLocalization
import ClaudioPanelPresentation
import ClaudioSettingsPresentation
import SoundPacksWindow
import SwiftUI

private struct RegressionDurationProbe: AudioDurationProbing {
    func probeDuration(of url: URL) -> TimeInterval? { 0.2 }
}

/// Created before any production owner. All writes, libraries, defaults and activity facts are
/// isolated. The control window accepts only these fixed scenarios, never arbitrary commands.
@MainActor
final class NativeUIRegressionController: NSObject, ObservableObject {
    let root: URL
    let preferences: ClaudioPreferences
    let fixture: SettingsPresentationFixture
    let clock: NativeRegressionClock
    let notices: EventNoticeModel
    let navigation: SessionNavigationCoordinator
    let generator: NativeRegressionGenerator
    private let generationFacts = NativeRegressionGenerationFacts()
    private let library: SoundPackLibrary
    private let refreshes: SoundPacksRefreshCoordinator
    private let environment: AudioImportEnvironment
    private let configFile: URL
    private let defaultsName: String
    private var clipboardBackup: [NSPasteboardItem] = []
    private var config: ClaudioConfig
    private let installation = UUID()
    private let sourceBehavior: RegressionSourceBehavior
    private let settings: SettingsWindowController
    private var banner: EventNoticeWindowController?
    private let panel = MenuBarPanel()
    private var statusItem: NSStatusItem?
    private var controls: NSWindow?
    private var keyMonitor: Any?
    private var observations: Set<AnyCancellable> = []
    private let focus = PanelFocusCoordinator()
    @Published private(set) var captureRevision = 0
    @Published private(set) var handbacks = 0

    init(isolated: Void) throws {
        let clock = NativeRegressionClock()
        self.clock = clock
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-ui-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defaultsName = "com.claudio.app.ui-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        preferences = ClaudioPreferences(defaults: defaults)
        preferences.setLanguage(.zhHans)
        configFile = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs", isDirectory: true)
        let factory = root.appendingPathComponent("factory", isDirectory: true)
        for directory in [packs, factory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        for (id, parent) in [
            ("regression-pack", packs), ("second-pack", packs), ("builtin-pack", packs),
            ("builtin-pack", factory),
        ] {
            let directory = parent.appendingPathComponent(id)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try NativeRegressionGenerator.wav(ordinal: 1).write(
                to: directory.appendingPathComponent("tone.wav"), options: .atomic)
            let manifest: [String: Any] = [
                "id": id, "name": id, "schema": 1, "version": "1", "author": "Claudio fixture",
                "license": "CC0-1.0",
                "events": Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.manifestKey, "tone.wav") }),
                "audio_names": ["tone.wav": "Fixture tone"],
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
                to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
        config = ClaudioConfig(selectedPack: "regression-pack", masterVolume: 0.7)
        config.workspaceRules = [
            WorkspaceSoundRule(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("workspace").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "regression-pack", volume: 0.6))
        ]
        try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
        environment = AudioImportEnvironment(
            userPacksDirectory: packs, factoryPacksDirectory: factory,
            durationProbe: RegressionDurationProbe(),
            packsLockFile: root.appendingPathComponent("packs.lock"))
        library = SoundPackLibrary(environment: environment)
        refreshes = SoundPacksRefreshCoordinator()
        let eventModel = PanelConfigController(
            configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
            environment: environment, soundPackLibrary: library,
            soundPacksRefreshCoordinator: refreshes)
        let editor = SoundPacksEditorOwner(
            configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
            environment: environment, soundPackLibrary: library, refreshCoordinator: refreshes)
        let behavior = RegressionSourceBehavior()
        sourceBehavior = behavior
        notices = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                guard behavior.verified else { return nil }
                return SourceApplicationTarget(
                    action: action,
                    process: HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0),
                    bundleIdentifier: "com.claudio.fixture.source",
                    applicationURL: URL(fileURLWithPath: "/ClaudioFixtureSource.app"),
                    name: "Fixture Source")
            })
        navigation = SessionNavigationCoordinator(
            model: notices, scheduler: clock.scheduler(),
            openApplication: { _, current, complete in
                if current() && !behavior.timesOut {
                    complete(behavior.succeeds ? .opened : .failed)
                }
                return EventNoticeCancellation {}
            })
        generator = NativeRegressionGenerator(
            root: root.appendingPathComponent("candidates"), facts: generationFacts)
        let ai = AICueGenerationViewModel(
            credentialManager: NativeRegressionCredentials(), generator: generator,
            providerPreferences: AICueProviderPreferences(defaults: defaults))
        let activity = LocalActivitySummaryStore(
            summaryFile: root.appendingPathComponent("activity.json"),
            lockFile: root.appendingPathComponent("activity.lock"),
            pendingDirectory: root.appendingPathComponent("pending"))
        let log = ActivityDiagnosticLogStore(
            logFile: root.appendingPathComponent("diagnostic.log"),
            logLockFile: root.appendingPathComponent("log.lock"))
        _ = activity.clear()
        let diagnostics = ActivityDiagnosticsModel(
            operations: ActivityDiagnosticsOperations(
                load: {
                    ActivityDiagnosticsLoadResult(
                        readResult: activity.read(), log: log.diagnosticLogSnapshot())
                },
                clearActivity: {
                    switch activity.clear() {
                    case .success(let document):
                        .success(
                            ActivityDiagnosticsLoadResult(
                                readResult: LocalActivitySummaryReadResult(state: .ready(document)),
                                log: log.diagnosticLogSnapshot()))
                    case .failure: .failure(.activityClearFailed)
                    }
                },
                clearLog: {
                    switch log.clearLog() {
                    case .success: .success(log.diagnosticLogSnapshot());
                    case .failure: .failure(.logClearFailed)
                    }
                }, revealLog: { false }, copyLogPath: { false }))
        fixture = SettingsPresentationFixtures.generalLogin(
            temporaryParent: root, route: .destination(.eventsAndSounds),
            workspaceRules: config.workspaceRules, eventSettingsModel: eventModel,
            soundPacksEditor: editor, aiCueViewModel: ai, preferences: preferences,
            eventNoticeModel: notices, noticeNavigation: navigation,
            activityDiagnostics: diagnostics)
        settings = SettingsWindowController(session: fixture.session)
        super.init()
        clipboardBackup = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let saved = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
    }

    func start() {
        let controls = NSWindow(
            contentRect: NSRect(x: 20, y: 80, width: 440, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        controls.title = "Claudio UI Regression"
        controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: NativeRegressionControls(owner: self))
        self.controls = controls
        controls.orderFrontRegardless()
        banner = EventNoticeWindowController(
            model: notices, languageStore: preferences, navigation: navigation,
            onViewInPanel: { [weak self] action in self?.showPanel(action: action) })
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        statusItem?.button?.title = "UI"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusClicked)
        panel.contentView = NSHostingView(
            rootView: PanelView(
                audioEnvironment: environment, configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"), focusCoordinator: focus,
                hostIntegrations: fixture.hostIntegrations, languageStore: preferences,
                activityDiagnostics: fixture.activityDiagnostics, soundPackLibrary: library,
                soundPacksRefreshCoordinator: refreshes, eventNoticeModel: notices,
                noticeNavigation: navigation, onAudibilityInputsChanged: {},
                onOpenSettings: { [weak self] in self?.showSettings() },
                onEditSoundScope: { [weak self] route in
                    self?.showSettings(request: .eventShortcut(route))
                },
                onConfigureSound: { [weak self] route in
                    self?.showSettings(request: .route(.sounds(route)))
                }, onOpenRecentNotices: {},
                onOpenIntegration: { [weak self] host in
                    self?.showSettings(request: .route(.integrations(surface: host.surfaceID)))
                }, onQuit: { NSApp.terminate(nil) }, onRevealConfig: { _ in }, onAnnounce: { _ in })
        )
        panel.contentSize = NSSize(width: 312, height: 740)
        panel.onEscape = { [weak self] in self?.focus.consumeNoticeEscape() ?? false }
        panel.onShow = { [weak self] in self?.focus.requestFocus() }
        panel.onClose = { [weak self] _ in
            self?.focus.notePanelHidden(); self?.notices.closeReading(.panel)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]) else { return event }
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated {
                switch keyCode {
                case 29: self?.controls?.makeKeyAndOrderFront(nil)
                case 25: NSApp.terminate(nil)
                case 28: self?.showSettings(request: .route(nil))
                case 35: self?.showPanel(action: nil)
                case 11: self?.controls?.orderOut(nil); self?.banner?.focusForRegression()
                case 37: self?.controls?.orderOut(nil); self?.settings.focusForRegression()
                case 18: self?.notice()
                case 19: self?.notice(verified: true)
                case 32: self?.notice(updated: true)
                case 14: self?.advance(1_801)
                case 15: self?.advance(1)
                case 3: self?.source("failure")
                case 1: self?.source("success")
                case 17: self?.source("timeout")
                case 5: self?.finishGeneration()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
        for publisher in [
            notices.objectWillChange, navigation.objectWillChange, fixture.session.objectWillChange,
            fixture.eventSettingsModel.objectWillChange, fixture.aiCueViewModel.objectWillChange,
            focus.objectWillChange,
        ] {
            publisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.capture() }
            }.store(in: &observations)
        }
        showSettings()
        capture()
        try? JSONSerialization.data(
            withJSONObject: [
                "root": root.path, "pid": ProcessInfo.processInfo.processIdentifier,
                "bundle": Bundle.main.bundlePath,
            ], options: [.sortedKeys]
        ).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent(
                "claudio-native-regression-active.json"), options: .atomic)
    }

    func finish() {
        guard NSPasteboard.general.string(forType: .string) == "fixture-session" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(clipboardBackup)
    }

    @objc private func statusClicked() { showPanel(action: nil) }
    func showSettings(request: SettingsPresentationRequest = .route(.destination(.eventsAndSounds)))
    {
        panel.close()
        settings.showWindow(
            request: request, returnFocusTo: nil,
            onClose: { [weak self] _ in
                self?.handbacks += 1; self?.capture()
            })
    }
    func showPanel(action: EventNoticeAction?) {
        guard let button = statusItem?.button else { return }
        controls?.orderOut(nil)
        if !panel.isShown { panel.show(relativeTo: button.bounds, of: button) }
        if let action { notices.openReading(.panel); focus.requestNotice(action) }
    }
    func matrix(language: ClaudioAppLanguage, dark: Bool, minimum: Bool) {
        preferences.setLanguage(language)
        showSettings()
        settings.applyRegressionGeometry(minimum: minimum, dark: dark)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        capture()
    }
    func notice(verified: Bool = false, updated: Bool = false) {
        sourceBehavior.verified = verified
        let binding = HostCapabilityCatalog.bindings(for: .codex).first {
            $0.nativeEvent == "PermissionRequest"
        }!
        _ = notices.accept(
            HostEventNotice(
                id: UUID(), receiverEpoch: notices.receiverEpoch, surface: .codex,
                bindingID: binding.id, installationID: installation,
                nativeEvent: "PermissionRequest", event: binding.event, occurredAt: Date(),
                source: HostEventSource(
                    projectLabel: updated ? "Fixture updated" : "Fixture workspace",
                    projectKey: "fixture-key", sessionID: "fixture-session",
                    mainSessionIsKnown: true), reason: .permission, observedUptime: clock.time,
                processAncestors: verified
                    ? [HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)] : nil))
        clock.advance(0.18)
        capture()
    }
    func scenario(_ scenario: String) {
        do {
            switch scenario {
            case "zero-volume": config.masterVolume = 0
            case "normal": config.masterVolume = 0.7
            case "invalid-workspace": config.workspaceRules.removeAll()
            case "stale-snapshot":
                Task { [weak self] in
                    guard let self, case .ready(let snapshot) = await library.stateForTesting()
                    else { return }
                    await library.replayStateForTesting(
                        .failed(
                            previous: snapshot,
                            error: .scanFailed(reason: "Fixture refresh unavailable")))
                    capture()
                }
                return
            case "duplicate-mapping": break
            case "damaged-pack":
                try Data("{".utf8).write(
                    to: environment.userPacksDirectory.appendingPathComponent(
                        "regression-pack/manifest.json"), options: .atomic)
            case "empty-library":
                for id in ["regression-pack", "second-pack", "builtin-pack"] {
                    try FileManager.default.removeItem(
                        at: environment.userPacksDirectory.appendingPathComponent(id))
                }
            default: return
            }
            try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
            fixture.eventSettingsModel.reload()
            refreshes.refreshWindowConfigProjection()
            if scenario == "damaged-pack" || scenario == "empty-library" {
                Task { [weak self] in
                    guard let self else { return }
                    _ = await library.refreshSnapshot(trigger: .write)
                    capture()
                }
            }
        } catch { NSLog("Fixed regression scenario failed") }
        capture()
    }
    func source(_ mode: String) {
        sourceBehavior.succeeds = mode == "success"; sourceBehavior.timesOut = mode == "timeout"
    }
    func finishGeneration() { Task { await generator.finish() } }
    func generationOutcome(_ outcome: NativeRegressionGenerator.Outcome) {
        Task { await generator.setOutcome(outcome) }
    }
    func advance(_ seconds: TimeInterval) { clock.advance(seconds); capture() }
    func capture() {
        captureRevision += 1
        let readback: [String: Any] = [
            "revision": captureRevision,
            "destination": fixture.session.state.routeResolution.destination.rawValue,
            "language": preferences.language.rawValue, "reminders": notices.snapshot.totalCount,
            "readingCount": notices.readingSnapshot.records.count,
            "readingOpen": notices.readingSnapshot.isOpen,
            "banner": notices.bannerSnapshot.phase.rawValue,
            "remaining": notices.bannerSnapshot.remainingTime ?? 0,
            "navigation": String(describing: navigation.applicationResult),
            "aiPhase": String(describing: fixture.aiCueViewModel.phase),
            "generationRequests": generationFacts.requestCount,
            "libraryFresh": fixture.eventSettingsModel.libraryPresentationState == .ready,
            "libraryState": String(describing: fixture.eventSettingsModel.libraryPresentationState),
            "description": fixture.aiCueViewModel.soundDescription,
            "candidateCount": fixture.aiCueViewModel.generation?.candidates.count ?? 0,
            "selectedPack": fixture.eventSettingsModel.config.selectedPack,
            "volume": fixture.eventSettingsModel.config.masterVolume, "handbacks": handbacks,
            "windowGeometry": settings.regressionGeometry,
            "settingsLayout": settings.regressionLayoutEvidence,
            "panelVisible": panel.isVisible, "panelKey": panel.isKeyWindow,
            "keyWindow": NSApp.keyWindow?.title ?? "none",
            "copiedFixtureSession": navigation.result == .copied
                && NSPasteboard.general.string(forType: .string) == "fixture-session",
        ]
        try? JSONSerialization.data(
            withJSONObject: readback, options: [.sortedKeys, .prettyPrinted]
        ).write(to: root.appendingPathComponent("readback.json"), options: .atomic)
    }
}

@MainActor private final class RegressionSourceBehavior {
    var verified = false; var succeeds = false; var timesOut = false
}

@MainActor private struct NativeRegressionControls: View {
    @ObservedObject var owner: NativeUIRegressionController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Isolated fixture v1").font(.headline)
                ForEach(0..<8, id: \.self) { index in
                    Button("Matrix \(index + 1)") {
                        owner.matrix(
                            language: index < 4 ? .zhHans : .english, dark: index % 4 >= 2,
                            minimum: index % 2 == 1)
                    }
                }
                Button("Show settings") { owner.showSettings() }
                Button("Return to settings") { owner.showSettings(request: .route(nil)) }
                Button("Show panel") { owner.showPanel(action: nil) }
                Button("Unknown-source reminder") { owner.notice() }
                Button("Verified-source reminder") { owner.notice(verified: true) }
                Button("Update reminder") { owner.notice(updated: true) }
                Button("Source failure") { owner.source("failure") }
                Button("Source success") { owner.source("success") }
                Button("Source timeout") { owner.source("timeout") }
                Button("Advance 1 second") { owner.advance(1) }
                Button("Advance 4 seconds") { owner.advance(4) }
                Button("Expire reminders") { owner.advance(1_801) }
                Button("AI complete") { owner.generationOutcome(.complete) }
                Button("AI partial") { owner.generationOutcome(.partial) }
                Button("AI failure") { owner.generationOutcome(.failure) }
                Button("Finish generation") { owner.finishGeneration() }
                ForEach(
                    [
                        "normal", "zero-volume", "invalid-workspace", "stale-snapshot",
                        "duplicate-mapping", "damaged-pack", "empty-library",
                    ], id: \.self
                ) { scenario in
                    Button("Scenario \(scenario)") { owner.scenario(scenario) }
                }
                Button("Capture state") { owner.capture() }
                Text("Capture \(owner.captureRevision) · handbacks \(owner.handbacks)")
            }.padding(20)
        }
    }
}
#endif
