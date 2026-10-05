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
    let eventAnimations: EventAnimationResources
    private let generationFacts = NativeRegressionGenerationFacts()
    private let library: SoundPackLibrary
    private let refreshes: SoundPacksRefreshCoordinator
    private let environment: AudioImportEnvironment
    private let configFile: URL
    private let receiptStore: HostHookReceiptStore
    private let activityStore: LocalActivitySummaryStore
    private let diagnosticLogStore: ActivityDiagnosticLogStore
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
    private var lastPlainKeyDown: [String: Any] = [:]
    private var observations: Set<AnyCancellable> = []
    private let focus = PanelFocusCoordinator()
    @Published private(set) var captureRevision = 0
    @Published private(set) var handbacks = 0

    init(isolated: Void) throws {
        let clock = NativeRegressionClock(
            live: Bundle.main.object(forInfoDictionaryKey: "ClaudioUIRegressionLiveClock") as? Bool
                == true)
        self.clock = clock
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-ui-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let defaults = SettingsFixtureDefaults(
            file: root.appendingPathComponent("preferences.plist"))
        let restartFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-animation-regression-restart.plist")
        var restored = false
        if let data = try? Data(contentsOf: restartFile), data.count < 65_536,
            let resume = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            resume["bundle"] as? String == Bundle.main.bundlePath,
            let saved = resume["preferences"] as? Data,
            let values = try? PropertyListSerialization.propertyList(from: saved, format: nil)
                as? [String: Any]
        {
            for key in [EventAnimationPreferences.defaultsKey, ClaudioAppLanguage.defaultsKey] {
                if let value = values[key] { defaults.set(value, forKey: key) }
            }
            restored = true
            try? FileManager.default.removeItem(at: restartFile)
        }
        preferences = ClaudioPreferences(defaults: defaults)
        if !restored { preferences.setLanguage(.zhHans) }
        let animationDirectory = root.appendingPathComponent("EventAnimations")
        guard
            let packagedAnimations = hostIconResourceBundle.resourceURL?.appendingPathComponent(
                "EventAnimations")
        else { throw EventAnimationResourceFailure.unavailable }
        try FileManager.default.copyItem(at: packagedAnimations, to: animationDirectory)
        eventAnimations = EventAnimationResources(directory: animationDirectory)
        configFile = root.appendingPathComponent("config.json")
        let integrations = root.appendingPathComponent("integrations", isDirectory: true)
        let receiptStore = HostHookReceiptStore(
            receiptsRoot: integrations.appendingPathComponent("receipts", isDirectory: true),
            locksRoot: integrations.appendingPathComponent("receipt-locks", isDirectory: true),
            installationsRoot: integrations.appendingPathComponent(
                "installations", isDirectory: true),
            installationLocksRoot: integrations.appendingPathComponent(
                "installation-locks", isDirectory: true),
            historyRoot: integrations.appendingPathComponent("receipt-history", isDirectory: true))
        self.receiptStore = receiptStore
        let hostSnapshots = try Self.seedReceiptHistories(in: receiptStore)
        let hostIntegrations = HostIntegrationPresentationStore(
            state: Self.receiptPresentationState(store: receiptStore, snapshots: hostSnapshots),
            configurationSources: Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map {
                    ($0, integrations.appendingPathComponent("\($0.rawValue)-fixture.json").path)
                }))
        let refreshReceiptContent: @MainActor @Sendable () async -> IntegrationDestinationContent =
            {
                let state = await Task.detached {
                    Self.receiptPresentationState(store: receiptStore, snapshots: hostSnapshots)
                }.value
                return hostIntegrations.replace(state: state)
            }
        let integrationsModel = IntegrationDestinationModel(
            content: hostIntegrations.content,
            refreshHandler: IntegrationDestinationRefreshHandler {
                IntegrationDestinationActionOutcome(
                    content: await refreshReceiptContent(), feedbackKind: .information,
                    feedbackText: .localized(key: .feedbackHostStateUpdated, arguments: []))
            },
            actionHandler: IntegrationDestinationActionHandler { action in
                guard case .clearReceiptHistory(let host) = action else {
                    return IntegrationDestinationActionOutcome(
                        content: await refreshReceiptContent(), feedbackKind: .information,
                        feedbackMessage:
                            "Fixture host connection operation; no external host changed")
                }
                let result = await Task.detached {
                    receiptStore.clearReceiptHistory(host: host)
                }.value
                let kind: IntegrationsFeedbackKind
                let text: IntegrationsFeedbackText
                switch result {
                case .success:
                    kind = .information
                    text = .localized(
                        key: .feedbackReceiptHistoryCleared, arguments: [host.displayName])
                case .failure(let error):
                    kind = .failure
                    text = .localized(key: .feedbackOperationFailed, arguments: [error.description])
                }
                return IntegrationDestinationActionOutcome(
                    content: await refreshReceiptContent(), feedbackKind: kind, feedbackText: text)
            },
            preferences: preferences,
            clipboardWriter: IntegrationDestinationClipboardWriter { _ in true },
            onContentChanged: { hostIntegrations.replace(content: $0) })
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
        activityStore = activity
        let log = ActivityDiagnosticLogStore(
            logFile: root.appendingPathComponent("diagnostic.log"),
            logLockFile: root.appendingPathComponent("log.lock"))
        diagnosticLogStore = log
        _ = try activity.clear().get()
        guard
            activity.record(
                host: .claudeCode, event: .taskStart, installationID: installation,
                activeInstallationID: installation, occurredAt: Date()) == .committed,
            appendLogLine(
                event: "stop", reason: "fixture playback failed",
                to: root.appendingPathComponent("diagnostic.log"),
                lockFile: root.appendingPathComponent("log.lock"))
        else {
            throw NSError(domain: "ClaudioNativeFixture", code: 2)
        }
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
            soundPacksEditor: editor, aiCueViewModel: ai,
            hostIntegrations: hostIntegrations, integrationsModel: integrationsModel,
            preferences: preferences,
            eventNoticeModel: notices, noticeNavigation: navigation,
            activityDiagnostics: diagnostics, productImages: makeSettingsProductImages(),
            eventAnimations: eventAnimations,
            nativeEffects: SoundPacksEditorNativeEffectsDispatcher(
                adapter: SystemSoundPacksEditorNativeEffectsAdapter()))
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

    /// Synthetic safe receipts exercise real archive I/O. They do not establish host callback
    /// activation: the independent connection snapshots deliberately remain awaiting a receipt.
    nonisolated private static func seedReceiptHistories(in store: HostHookReceiptStore) throws
        -> [HostIntegrationSnapshot]
    {
        let now = Date()
        return try HostID.productVisibleCases.enumerated().map { ordinal, host in
            let currentID = UUID(
                uuidString: String(format: "00000000-0000-4000-8000-%012d", ordinal + 301))!
            let previousID = UUID(
                uuidString: String(format: "00000000-0000-4000-8000-%012d", ordinal + 401))!
            let scope = "native-fixture-\(host.rawValue)"
            let bindings = HostCapabilityCatalog.bindings(for: host).filter {
                $0.isAudibleCapability && ($0.event == .stop || $0.event == .subagentStop)
            }
            guard bindings.count == 2 else {
                throw NSError(domain: "ClaudioNativeFixture", code: 1)
            }
            for (generation, id) in [previousID, currentID].enumerated() {
                try store.activate(host: host, installationID: id, scopeFingerprint: scope).get()
                for (index, binding) in bindings.enumerated() {
                    let receipt = HostHookReceipt(
                        installationID: id, host: host, bindingID: binding.id,
                        nativeEvent: binding.nativeEvent!, semanticEvent: binding.event,
                        timestamp: now.addingTimeInterval(
                            TimeInterval(-120 + generation * 60 + index)),
                        playbackResult: generation == 0 ? .muted : .playbackFailed)
                    _ = try store.store(
                        receipt, expectedScopeFingerprint: scope, scopeFingerprint: { scope }
                    ).get()
                }
            }
            return HostIntegrationSnapshot(
                host: host, runtime: .ready, availability: .available,
                configuration: .configured, writability: .writable,
                activation: .awaitingReceipt(installationID: currentID),
                installationID: currentID)
        }
    }

    nonisolated private static func receiptPresentationState(
        store: HostHookReceiptStore, snapshots: [HostIntegrationSnapshot]
    ) -> HostIntegrationPresentationState {
        let capabilities = Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, HostCapabilityCatalog.bindings(for: $0))
            })
        let matrix = AudibilityMatrix.make(
            snapshots: snapshots, capabilities: capabilities,
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
        var state = HostIntegrationPresentationState(snapshots: snapshots, matrix: matrix)
        state.receiptHistories = Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, store.receiptHistorySnapshot(host: $0))
            })
        return state
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
            eventAnimations: eventAnimations,
            onViewInPanel: { [weak self] action in self?.showPanel(action: action) })
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        statusItem?.button?.title = "UI"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusClicked)
        panel.contentView = NSHostingView(
            rootView: PanelView(
                audioEnvironment: environment, configFile: configFile,
                panelModel: fixture.eventSettingsModel,
                soundScopeSelection: fixture.eventSettingsModel.soundScopeSelection,
                focusCoordinator: focus,
                hostIntegrations: fixture.hostIntegrations, languageStore: preferences,
                activityDiagnostics: fixture.activityDiagnostics, eventNoticeModel: notices,
                noticeNavigation: navigation, onAudibilityInputsChanged: {},
                onOpenSettings: { [weak self] in self?.showSettings() },
                onEditSoundScope: { [weak self] route in
                    self?.showSettings(request: .eventShortcut(route))
                },
                onConfigureSound: { [weak self] route in
                    self?.showSettings(request: .route(.sounds(route)))
                }, onOpenRecentNotices: {},
                onOpenIntegration: { [weak self] host in
                    self?.showSettings(
                        request: .route(
                            .integrations(IntegrationsSettingsRoute(surface: host.surfaceID))))
                }, onQuit: { NSApp.terminate(nil) }, onRevealConfig: { _ in }, onAnnounce: { _ in })
        )
        panel.contentSize = NSSize(width: 312, height: 740)
        panel.onEscape = { [weak self] in self?.focus.consumeNoticeEscape() ?? false }
        panel.onShow = { [weak self] in self?.focus.requestFocus() }
        panel.onClose = { [weak self] _ in
            self?.focus.notePanelHidden(); self?.notices.closeReading(.panel)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Let native file panels own their Go to Folder shortcut.
            guard !(event.window is NSSavePanel) else { return event }
            guard event.modifierFlags.contains([.command, .shift]) else {
                MainActor.assumeIsolated {
                    self?.lastPlainKeyDown = [
                        "keyCode": Int(event.keyCode),
                        "characters": event.characters ?? "",
                        "window": event.window?.title ?? "none",
                    ]
                    // Observe after normal dispatch; the fixture never consumes ordinary keys.
                    Task { @MainActor [weak self] in self?.capture() }
                }
                return event
            }
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
            fixture.integrationsModel.objectWillChange,
            fixture.activityDiagnostics.objectWillChange,
            preferences.objectWillChange,
            fixture.session.animationPreview.objectWillChange,
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
    func notice(verified: Bool = false, updated: Bool = false, transient: Bool = false) {
        if clock.isLive {
            // Keep the automatic banner nonactivating and independently capturable. These are
            // fixture-owned windows; no user settings or host windows are affected.
            _ = settings.closeForMutualExclusion()
            panel.close()
            controls?.orderOut(nil)
        }
        sourceBehavior.verified = verified
        let native = transient ? "Stop" : "PermissionRequest"
        let binding = HostCapabilityCatalog.bindings(for: .codex).first {
            $0.nativeEvent == native
        }!
        _ = notices.accept(
            HostEventNotice(
                id: UUID(), receiverEpoch: notices.receiverEpoch, surface: .codex,
                bindingID: binding.id, installationID: installation,
                nativeEvent: native, event: binding.event, occurredAt: Date(),
                source: HostEventSource(
                    projectLabel: updated ? "Fixture updated" : "Fixture workspace",
                    projectKey: "fixture-key", sessionID: "fixture-session",
                    mainSessionIsKnown: true), reason: transient ? nil : .permission,
                observedUptime: clock.time,
                processAncestors: verified
                    ? [HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)] : nil))
        if !clock.isLive { clock.advance(0.18) }
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
        let currentUptime = clock.time
        let readingTime = notices.bannerSnapshot.readingTime
        let pauseReasons: [String] = [
            (EventNoticePauseReason.hover, "hover"), (.keyboardFocus, "keyboardFocus"),
        ].compactMap { reason, name in
            notices.bannerSnapshot.pauseReasons.contains(reason) ? name : nil
        }
        let bannerWindow = NSApp.windows.first { $0.title == "claudi0 event notice" }
        let bannerFrame = bannerWindow?.frame ?? .zero
        let inspectedPack: String?
        if case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode {
            inspectedPack = sounds.selectedPack?.id
        } else {
            inspectedPack = nil
        }
        let readback: [String: Any] = [
            "revision": captureRevision,
            "destination": fixture.session.state.routeResolution.destination.rawValue,
            "language": preferences.language.rawValue, "reminders": notices.snapshot.totalCount,
            "eventAnimation": [
                "style": preferences.eventAnimation.style.rawValue,
                "effectiveStyle": preferences.eventAnimation.effectiveStyle.rawValue,
                "showsCharacter": preferences.eventAnimation.showsCharacter,
                "usesStaticExpression": preferences.eventAnimation.usesStaticExpression,
                "previewActive": fixture.session.animationPreview.isActive,
                "previewEvent": fixture.session.animationPreview.event.rawValue,
                "previewRevision": fixture.session.animationPreview.replayRevision,
            ],
            "readingCount": notices.readingSnapshot.records.count,
            "readingOpen": notices.readingSnapshot.isOpen,
            "banner": notices.bannerSnapshot.phase.rawValue,
            "remaining": notices.bannerSnapshot.remainingTime ?? 0,
            "clockMode": clock.isLive ? "live" : "manual",
            "readingTime": [
                "available": readingTime != nil,
                "fraction": readingTime?.fraction(at: currentUptime) ?? 0,
                "sampledUptime": readingTime?.sampledUptime ?? 0,
                "currentUptime": currentUptime,
                "remaining": readingTime?.remaining ?? 0,
                "budget": readingTime?.budget ?? 0,
                "isPaused": readingTime?.isPaused ?? false,
            ],
            "pauseReasons": pauseReasons,
            "readingExpanded": notices.snapshot.isExpanded,
            "bannerWindow": [
                "available": bannerWindow != nil,
                "visible": bannerWindow?.isVisible ?? false,
                "key": bannerWindow?.isKeyWindow ?? false,
                "frame": [
                    "x": bannerFrame.origin.x, "y": bannerFrame.origin.y,
                    "width": bannerFrame.size.width, "height": bannerFrame.size.height,
                ],
            ],
            "navigation": String(describing: navigation.result),
            "bannerKeyboardPaused": notices.bannerSnapshot.pauseReasons.contains(.keyboardFocus),
            "aiPhase": String(describing: fixture.aiCueViewModel.phase),
            "generationRequests": generationFacts.requestCount,
            "libraryFresh": fixture.eventSettingsModel.libraryPresentationState == .ready,
            "libraryState": String(describing: fixture.eventSettingsModel.libraryPresentationState),
            "description": fixture.aiCueViewModel.soundDescription,
            "candidateCount": fixture.aiCueViewModel.generation?.candidates.count ?? 0,
            "selectedPack": fixture.eventSettingsModel.config.selectedPack,
            "inspectedPack": inspectedPack ?? "none",
            "volume": fixture.eventSettingsModel.config.masterVolume, "handbacks": handbacks,
            "windowGeometry": settings.regressionGeometry,
            "settingsLayout": settings.regressionLayoutEvidence,
            "panelVisible": panel.isVisible, "panelKey": panel.isKeyWindow,
            "keyWindow": NSApp.keyWindow?.title ?? "none",
            "isActive": NSApp.isActive,
            "keyWindowFirstResponder": NSApp.keyWindow?.firstResponder.map {
                String(reflecting: type(of: $0))
            } ?? "none",
            "keyWindowFirstResponderIdentifier": (NSApp.keyWindow?.firstResponder as? NSView)?
                .accessibilityIdentifier() ?? "none",
            "lastPlainKeyDown": lastPlainKeyDown,
            "receiptHistories": receiptHistoryReadback(),
            "activity": activityReadback(),
            "diagnosticLog": diagnosticLogReadback(),
            "copiedFixtureSession": navigation.result == .copied
                && NSPasteboard.general.string(forType: .string) == "fixture-session",
        ]
        try? JSONSerialization.data(
            withJSONObject: readback, options: [.sortedKeys, .prettyPrinted]
        ).write(to: root.appendingPathComponent("readback.json"), options: .atomic)
    }

    func breakAnimationResources() {
        preferences.selectEventAnimationStyle(.mechanicalDuck)
        for name in ["sprites.png", "sprites-dark.png"] {
            try? Data("broken fixture atlas".utf8).write(
                to: root.appendingPathComponent("EventAnimations/E/\(name)"), options: .atomic)
        }
        Task {
            for dark in [false, true] {
                await eventAnimations.load(.mechanicalDuck, dark: dark, retry: true)
            }
            capture()
        }
    }

    func restoreAnimationResources() {
        guard
            let packagedAnimations = hostIconResourceBundle.resourceURL?.appendingPathComponent(
                "EventAnimations/E")
        else { return }
        for name in ["sprites.png", "sprites-dark.png"] {
            if let data = try? Data(contentsOf: packagedAnimations.appendingPathComponent(name)) {
                try? data.write(
                    to: root.appendingPathComponent("EventAnimations/E/\(name)"), options: .atomic)
            }
        }
        capture()
    }

    func restartAnimationFixture() {
        guard
            let preferences = try? Data(
                contentsOf: root.appendingPathComponent("preferences.plist")),
            let data = try? PropertyListSerialization.data(
                fromPropertyList: ["bundle": Bundle.main.bundlePath, "preferences": preferences],
                format: .binary, options: 0)
        else { return }
        do {
            try data.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "claudio-animation-regression-restart.plist"), options: .atomic)
            NSApp.terminate(nil)
        } catch { return }
    }

    private func receiptHistoryReadback() -> [String: Any] {
        Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map { host in
                let disk = receiptStore.receiptHistorySnapshot(host: host)
                let facts = fixture.integrationsModel.content.facts(for: host)
                let history = facts?.receiptHistory
                let installationID = receiptStore.currentInstallationID(host: host)
                let scope = receiptStore.currentInstallationScopeFingerprint(host: host)
                let currentEvidenceCount = HostCapabilityCatalog.bindings(for: host).filter {
                    guard let nativeEvent = $0.nativeEvent, let installationID, let scope else {
                        return false
                    }
                    return receiptStore.receiptEvidence(
                        host: host, nativeEvent: nativeEvent, installationID: installationID,
                        scopeFingerprint: scope) != nil
                }.count
                let values: [String: Any] = [
                    "diskCount": disk.receipts.count,
                    "diskState": String(describing: disk.state),
                    "presentationCount": history?.entries.count ?? 0,
                    "presentationState": history.map { String(describing: $0.state) } ?? "missing",
                    "generations": history?.entries.map { String(describing: $0.generation) } ?? [],
                    "events": disk.receipts.map { $0.semanticEvent.rawValue },
                    "currentReceiptEvidenceCount": currentEvidenceCount,
                    "installationID": installationID?.uuidString ?? "none",
                    "connectionStatus": facts.map { String(describing: $0.status) } ?? "missing",
                ]
                return (host.rawValue, values)
            })
    }

    private func activityReadback() -> [String: Any] {
        let result = activityStore.read()
        let count: UInt64
        let state: String
        switch result.state {
        case .ready(let document), .stale(let document):
            if case .ready = result.state { state = "ready" } else { state = "stale" }
            count = document.buckets.reduce(0) { total, bucket in
                total + bucket.counts.values.reduce(0, +)
            }
        case .missing:
            state = "missing"; count = 0
        case .unavailable:
            state = "unavailable"; count = 0
        }
        return [
            "state": state, "count": count, "path": "activity.json",
            "bytes": (try? Data(contentsOf: root.appendingPathComponent("activity.json")))?.count
                ?? 0,
        ]
    }

    private func diagnosticLogReadback() -> [String: Any] {
        let snapshot = diagnosticLogStore.diagnosticLogSnapshot()
        return [
            "state": String(describing: snapshot.state), "failureCount": snapshot.failures.count,
            "path": "diagnostic.log",
            "bytes": (try? Data(contentsOf: root.appendingPathComponent("diagnostic.log")))?.count
                ?? 0,
        ]
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
                Button("Break animation resources") { owner.breakAnimationResources() }
                Button("Restore animation resources") { owner.restoreAnimationResources() }
                Button("Restart animation fixture") { owner.restartAnimationFixture() }
                Button("Unknown-source reminder") { owner.notice() }
                Button("Verified-source reminder") { owner.notice(verified: true) }
                Button("Verified-source ordinary notice") {
                    owner.notice(verified: true, transient: true)
                }
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
