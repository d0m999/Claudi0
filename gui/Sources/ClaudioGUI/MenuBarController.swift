import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioPanelPresentation
import ClaudioSettingsPresentation
import Combine
import SoundPacksWindow
import SwiftUI

/// Breaks the pre-`super.init()` construction cycle: `PanelView` needs an action closure before
/// `MenuBarController` can become that closure's weak owner.
@MainActor
private final class MenuBarActionRouter {
    weak var owner: MenuBarController?

    func requestSoundsSettings(
        route: SoundPacksWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestSoundsSettingsPresentation(route: route, returnFocusTo: target)
    }

    func requestIntegrationsSettings(
        preselect host: HostID?,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestIntegrationsSettingsPresentation(preselect: host, returnFocusTo: target)
    }

    func requestEventsSettings(
        route: EventSettingsWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestEventsSettingsPresentation(route: route, returnFocusTo: target)
    }

    func audibilityInputsChanged() {
        owner?.requestHostIntegrationRefresh()
    }

    func publishHostIntegrationState(
        _ state: HostIntegrationPresentationState
    ) -> IntegrationDestinationContent? {
        owner?.publishHostIntegrationState(state)
    }

    func performGlobalShortcut(_ action: GlobalShortcutAction) {
        owner?.performGlobalShortcut(action)
    }

    /// Settings and the top notice list are mutually exclusive (SPEC: 设置打开和顶部列表互斥显示).
    func closeSettingsForEventNoticeInteraction() -> (@MainActor () -> Void)? {
        owner?.dismissSettingsForEventNoticeInteraction()
    }
}

private struct PendingSettingsPresentation {
    let request: SettingsPresentationRequest
    let panelFocusTarget: PanelFocusTarget?
    let handbackApplication: NSRunningApplication?
}

/// App-lifetime owner for the menu Panel, shared focus coordinator and retained Settings routes.
/// Both native surfaces borrow keyboard focus without activating the app or reordering its peers.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panelWindow: MenuBarPanel
    private let hostingController: NSHostingController<PanelView>
    private let soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator
    private let soundPackLibrary: SoundPackLibrary
    private let settingsWindowController: SettingsWindowController
    private let eventSettingsModel: PanelConfigController
    /// C1：app 生命周期声音作用域选择的唯一事实 —— 面板、设置窗口与全局快捷键共享同一个
    /// owner（注入 `eventSettingsModel`，并直接传给 `PanelView`）。持久化字节仍在
    /// `panelSoundScopeDefaultsKey`，但读写只经这个 owner。
    private let soundScopeSelection: SoundScopeSelection
    private let globalShortcutRegistrar: CarbonGlobalShortcutRegistrar
    private let globalShortcutSettings: GlobalShortcutSettingsModel
    private let languageStore: ClaudioPreferences
    private let integrationsModel: IntegrationDestinationModel
    private let actionRouter: MenuBarActionRouter
    private let hostIntegrations: HostIntegrationPresentationStore
    private let hostIntegrationMatrixProvider: HostIntegrationMatrixProvider
    private let bootstrapReports: BootstrapReportPresentationStore
    private let dynamicQuietObserver: DynamicQuietSystemObserver
    private let eventNoticeRuntime: EventNoticeRuntime
    private let eventNoticeWindowController: EventNoticeWindowController
    private var hostIntegrationRefreshTask: Task<Void, Never>?
    private var appActivationCancellable: AnyCancellable?
    private var menuBarIconCancellable: AnyCancellable?
    private var systemPowerCancellables: Set<AnyCancellable> = []
    private var hostIntegrationRefreshRevision: UInt64 = 0

    /// Owned here (not by `PanelView`) so it survives across every Panel show/close cycle
    /// for the app's whole lifetime, and so `panelDidShow` has something concrete to
    /// signal (a11y-architect FIX 4) — see ``PanelFocusCoordinator``'s doc comment.
    private let focusCoordinator = PanelFocusCoordinator()

    /// External app captured for explicit Settings routing and its close handback.
    /// Ordinary Panel opening and dismissal never activate this application.
    private var previousApp: NSRunningApplication?
    private var panelSettingsHandback = PanelSettingsHandback()
    /// Every production settings entry shares one close-before-show handoff. The typed route and
    /// exact panel focus target travel together, so no legacy window can race with this retained
    /// owner or leave a later Panel close carrying a stale presentation.
    private var pendingSettingsPresentation: PendingSettingsPresentation?
    /// Set by the retained settings window's close callback and consumed by the next
    /// `panelDidShow`, so focus restoration is one-shot rather than sticky across later opens.
    private var pendingRestoredPanelFocusTarget: PanelFocusTarget?

    /// 面板 shell 只接收 manager 已组合的宿主事实。内置 helper 的定位与
    /// shared bootstrap 已上移到 AppDelegate 的 composition root，不再经过面板。
    init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        audioEnvironment: AudioImportEnvironment,
        bundledHelper: URL?,
        hostIntegrationState: HostIntegrationPresentationState,
        integrationMatrixProvider: HostIntegrationMatrixProvider,
        integrationActionProvider: HostIntegrationActionProvider
    ) {
        let languageStore = preferences
        let soundPacksRefreshCoordinator = SoundPacksRefreshCoordinator()
        var audioEnvironment = audioEnvironment
        audioEnvironment.systemSoundSelectionAllowed = {
            installedHelperMatchesBundledRuntime(bundledHelper: bundledHelper)
        }
        let soundPackLibrary = SoundPackLibrary(environment: audioEnvironment)
        let soundPacksEditorOwner = SoundPacksEditorOwner(
            configFile: ClaudioPaths.configFile,
            environment: audioEnvironment,
            soundPackLibrary: soundPackLibrary,
            refreshCoordinator: soundPacksRefreshCoordinator)
        let actionRouter = MenuBarActionRouter()
        let hostIntegrations = HostIntegrationPresentationStore(
            state: hostIntegrationState,
            configurationSources: [
                .claudeCode: ClaudioPaths.claudeSettingsFile.path,
                .codex: ClaudioPaths.codexHooksFile.path,
                .workBuddy: ClaudioPaths.workBuddySettingsFile.path,
            ])
        let bootstrapReports = BootstrapReportPresentationStore()
        let integrationsModel = IntegrationDestinationModel(
            content: hostIntegrations.content,
            refreshHandler: IntegrationDestinationRefreshHandler {
                [weak actionRouter, weak hostIntegrations] in
                let state = try await integrationMatrixProvider()
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actionRouter?.publishHostIntegrationState(state)
                    ?? hostIntegrations.replace(state: state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: .information,
                    feedbackText: .localized(key: .feedbackRedetectedSources, arguments: []))
            },
            actionHandler: IntegrationDestinationActionHandler {
                [weak actionRouter, weak hostIntegrations] action in
                let managerOutcome = try await integrationActionProvider(action)
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actionRouter?.publishHostIntegrationState(managerOutcome.state)
                    ?? hostIntegrations.replace(state: managerOutcome.state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: managerOutcome.feedbackKind,
                    feedbackText: managerOutcome.feedbackText)
            },
            preferences: languageStore,
            clipboardWriter: IntegrationDestinationClipboardAdapter.system,
            onContentChanged: { [weak hostIntegrations] content in
                hostIntegrations?.replace(content: content)
            })
        let soundScopeSelection = SoundScopeSelection(defaults: .standard)
        let eventSettingsModel = makeEventSettingsConfigController(
            configFile: ClaudioPaths.configFile,
            environment: audioEnvironment,
            soundPackLibrary: soundPackLibrary,
            bundledHelper: bundledHelper,
            soundPacksRefreshCoordinator: soundPacksRefreshCoordinator,
            soundScopeSelection: soundScopeSelection,
            afterFullReload: { [weak actionRouter] _ in
                actionRouter?.audibilityInputsChanged()
            })
        let globalShortcutRegistrar = CarbonGlobalShortcutRegistrar()
        let globalShortcutSettings = GlobalShortcutSettingsModel(
            adapter: globalShortcutRegistrar.makeAdapter(),
            persistence: .userDefaults(),
            actionHandler: { [weak actionRouter] action in
                actionRouter?.performGlobalShortcut(action)
            })
        let aiCueTemporaryRoot = ClaudioPaths.root.appendingPathComponent(
            "ai-cue-temporary",
            isDirectory: true)
        let aiCueRuntime = try! AICueRuntime(
            vault: AICueAppCredentialVault(),
            temporaryRoot: aiCueTemporaryRoot,
            durationProbe: audioEnvironment.durationProbe)
        let aiCueViewModel = AICueGenerationViewModel(
            credentialManager: aiCueRuntime.credentialManager,
            generator: aiCueRuntime.dispatcher,
            registry: aiCueRuntime.registry,
            providerPreferences: aiCueRuntime.providerPreferences)
        let dynamicQuietObserver = DynamicQuietSystemObserver()
        let eventNoticeRuntime = EventNoticeRuntime()
        let noticeNavigation = SessionNavigationCoordinator(
            model: eventNoticeRuntime.model,
            openApplication: SourceApplicationAdapter.openApplication)
        let eventNoticeWindowController = EventNoticeWindowController(
            model: eventNoticeRuntime.model,
            languageStore: languageStore,
            navigation: noticeNavigation,
            onViewInPanel: { [weak actionRouter] action in
                actionRouter?.owner?.openNoticeInPanel(action)
            },
            onWillBecomeInteractive: { [weak actionRouter] in
                actionRouter?.closeSettingsForEventNoticeInteraction()
            })
        let activityDiagnostics = makeActivityDiagnosticsModel()
        let soundPacksEditorNativeEffects = SoundPacksEditorNativeEffectsDispatcher(
            adapter: SystemSoundPacksEditorNativeEffectsAdapter())
        let settingsPresentationSession = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: languageStore,
                loginItemSettings: loginItemSettings,
                dynamicQuietPolicy: dynamicQuietObserver.policy,
                activityDiagnostics: activityDiagnostics,
                globalShortcutSettings: globalShortcutSettings,
                aboutSettings: makeSystemAboutSettingsModel(
                    surfaceFacts: hostIntegrations.safeSurfaceFacts),
                soundPacksEditorOwner: soundPacksEditorOwner,
                soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
                eventSettingsModel: eventSettingsModel,
                hostIntegrations: hostIntegrations,
                integrationsModel: integrationsModel,
                aiCueViewModel: aiCueViewModel,
                eventNoticeHealth: eventNoticeRuntime.health,
                eventNoticeModel: eventNoticeRuntime.model,
                noticeNavigation: noticeNavigation,
                productImages: makeSettingsProductImages()),
            actions: makeSystemSettingsPresentationActions(
                onEventAudibilityInputsChanged: { [weak actionRouter] in
                    actionRouter?.audibilityInputsChanged()
                }))
        let settingsWindowController = SettingsWindowController(
            session: settingsPresentationSession)

        // Build the native window before its content so AppKit owns the fixed outer geometry from the
        // moment the SwiftUI content is attached; no user preference or resize callback enters
        // this path.
        let panelWindow = MenuBarPanel()
        // `standardPanelWidth` (`ClaudioGUICore`), never a second hardcoded `312`: DESIGN.md's
        // 312pt panel width already exists as a constant, and `PanelLayoutAdaptation/panelWidth`
        // — the value the SwiftUI side actually sizes itself to — is derived from it.
        // The production panel has one fixed compact width and a 560pt preferred height.
        panelWindow.contentSize = NSSize(width: standardPanelWidth, height: 560)

        let panel = PanelView(
            audioEnvironment: audioEnvironment,
            panelModel: eventSettingsModel,
            soundScopeSelection: soundScopeSelection,
            focusCoordinator: focusCoordinator,
            hostIntegrations: hostIntegrations,
            languageStore: languageStore,
            activityDiagnostics: activityDiagnostics,
            eventNoticeModel: eventNoticeRuntime.model,
            noticeNavigation: noticeNavigation,
            onAudibilityInputsChanged: { [weak actionRouter] in
                actionRouter?.audibilityInputsChanged()
            },
            onOpenSettings: { [weak actionRouter] in
                actionRouter?.owner?.requestSettingsWindowPresentation()
            },
            onEditSoundScope: { [weak actionRouter] route in
                actionRouter?.requestEventsSettings(
                    route: route, returnFocusTo: .soundScope)
            },
            onConfigureSound: { [weak actionRouter] route in
                actionRouter?.requestSoundsSettings(route: route, returnFocusTo: .soundScope)
            },
            onOpenRecentNotices: { [weak eventNoticeWindowController] in
                eventNoticeWindowController?.openInteractive()
            },
            onOpenIntegration: { [weak actionRouter] host in
                actionRouter?.requestIntegrationsSettings(
                    preselect: host, returnFocusTo: .soundScope)
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            onRevealConfig: { configURL in
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
            },
            onAnnounce: { sentence in
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            })
        hostingController = NSHostingController(rootView: panel)

        panelWindow.contentViewController = hostingController
        self.panelWindow = panelWindow
        self.soundPacksRefreshCoordinator = soundPacksRefreshCoordinator
        self.soundPackLibrary = soundPackLibrary
        self.settingsWindowController = settingsWindowController
        self.eventSettingsModel = eventSettingsModel
        self.soundScopeSelection = soundScopeSelection
        self.globalShortcutRegistrar = globalShortcutRegistrar
        self.globalShortcutSettings = globalShortcutSettings
        self.languageStore = languageStore
        self.integrationsModel = integrationsModel
        self.actionRouter = actionRouter
        self.hostIntegrations = hostIntegrations
        self.hostIntegrationMatrixProvider = integrationMatrixProvider
        self.bootstrapReports = bootstrapReports
        self.dynamicQuietObserver = dynamicQuietObserver
        self.eventNoticeRuntime = eventNoticeRuntime
        self.eventNoticeWindowController = eventNoticeWindowController

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        // Template image, auto light/dark. The 16pt Orbit Zero reduction lives in
        // `MenuBarIcon`; panel/onboarding headers use the matching full wordmark.
        Self.applyMenuBarIcon(language: languageStore.language, to: statusItem)

        super.init()

        activityDiagnostics.updateIntegrationStatuses(
            Dictionary(
                uniqueKeysWithValues: hostIntegrationState.snapshots.map {
                    ($0.host, ActivityOverviewProjector.integrationStatus(from: $0))
                }))

        actionRouter.owner = self
        panelWindow.onShow = { [weak self] in self?.panelDidShow() }
        panelWindow.onEscape = { [weak focusCoordinator] in
            focusCoordinator?.consumeNoticeEscape() ?? false
        }
        panelWindow.onClose = { [weak self] reason in self?.panelDidClose(reason) }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.settingsWindowController.protectSettingsDuringStatusActivation(
                        button: self?.statusItem.button)
                }
            }
            .store(in: &systemPowerCancellables)

        menuBarIconCancellable = languageStore.$snapshot
            .sink { [weak statusItem, eventNoticeRuntime] snapshot in
                MainActor.assumeIsolated {
                    guard let statusItem else { return }
                    Self.applyMenuBarIcon(language: snapshot.language, to: statusItem)
                    eventNoticeRuntime.setEnabled(snapshot.showsEventSourcePrompts)
                }
            }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak globalShortcutSettings, weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    globalShortcutSettings?.suspend()
                    eventNoticeRuntime?.suspendForSystemPrivacy(.sleeping)
                }
            }
            .store(in: &systemPowerCancellables)
        workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak globalShortcutSettings, weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    globalShortcutSettings?.resume()
                    eventNoticeRuntime?.resumeAfterSystemPrivacy(.sleeping)
                }
            }
            .store(in: &systemPowerCancellables)
        // Workspace session notifications describe fast-user switching. loginwindow emits
        // separate distributed screen-lock signals; keep those reasons independent so a
        // session-active callback cannot resume while the screen is still locked.
        let screenNotifications = DistributedNotificationCenter.default()
        screenNotifications.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    eventNoticeRuntime?.suspendForSystemPrivacy(.screenLocked)
                }
            }
            .store(in: &systemPowerCancellables)
        screenNotifications.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    eventNoticeRuntime?.resumeAfterSystemPrivacy(.screenLocked)
                }
            }
            .store(in: &systemPowerCancellables)
        workspaceNotifications.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    eventNoticeRuntime?.suspendForSystemPrivacy(.inactiveSession)
                }
            }
            .store(in: &systemPowerCancellables)
        workspaceNotifications.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak eventNoticeRuntime] _ in
                MainActor.assumeIsolated {
                    eventNoticeRuntime?.resumeAfterSystemPrivacy(.inactiveSession)
                }
            }
            .store(in: &systemPowerCancellables)

        dynamicQuietObserver.policy.$presentation
            .sink { [weak eventNoticeRuntime] presentation in
                MainActor.assumeIsolated {
                    eventNoticeRuntime?.model.setAutomaticallySuppressed(
                        presentation.suppressesAutomaticPresentations)
                }
            }
            .store(in: &systemPowerCancellables)

        appActivationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.soundPacksRefreshCoordinator.refreshWindowConfigProjection()
                    Task {
                        await self.soundPackLibrary.requestRefresh(
                            trigger: .applicationActivation)
                    }
                }
            }

        // GUI 首启只运行共享 bootstrap + 双侧 inspect。宿主连接必须始终来自详情窗里的显式动作。
        eventNoticeRuntime.setEnabled(languageStore.showsEventSourcePrompts)
        eventNoticeRuntime.model.setAutomaticallySuppressed(
            dynamicQuietObserver.policy.presentation.suppressesAutomaticPresentations)
        requestHostIntegrationRefresh(bootstrapSharedRuntime: true)
    }

    private static func applyMenuBarIcon(
        language: ClaudioAppLanguage,
        to statusItem: NSStatusItem
    ) {
        let accessibilityLabel = ClaudioL10n(language: language).text(
            .menuBarStatusRunning)
        let icon = MenuBarIcon.make()
        icon.accessibilityDescription = accessibilityLabel
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)
    }

    deinit {
        hostIntegrationRefreshTask?.cancel()
    }

    func applicationWillTerminate() {
        panelWindow.onClose = nil
        panelWindow.close()
        globalShortcutSettings.suspend()
        globalShortcutRegistrar.invalidate()
        eventNoticeWindowController.close()
        eventNoticeRuntime.stopForTermination()
    }

    /// 声音包、manifest 或静音配置变化后重算同一份可听矩阵。代次保护避免较慢的旧 refresh
    /// 覆盖集成目的页动作刚发布的新状态；失败时保留最后一份诚实状态，不伪造 ready。
    fileprivate func requestHostIntegrationRefresh(
        bootstrapSharedRuntime: Bool = false
    ) {
        hostIntegrationRefreshRevision &+= 1
        let revision = hostIntegrationRefreshRevision
        hostIntegrationRefreshTask?.cancel()
        let provider = hostIntegrationMatrixProvider
        hostIntegrationRefreshTask = Task { @MainActor [weak self] in
            do {
                let state =
                    try await
                    (bootstrapSharedRuntime
                    ? provider.bootstrapSharedRuntime()
                    : provider())
                // Bootstrap can create config/packs after PanelConfigController has already read
                // its initial state. Notify that read model before the presentation revision guard:
                // opening the Panel while bootstrap is in flight cancels this task and starts a
                // newer refresh, but cancellation must not discard the completed disk mutation.
                if bootstrapSharedRuntime {
                    self?.bootstrapReports.reload()
                    self?.soundPackLibrary.invalidate(packIDs: [])
                    self?.soundPacksRefreshCoordinator.completeSharedRuntimeBootstrap()
                }
                guard
                    !Task.isCancelled,
                    let self,
                    self.hostIntegrationRefreshRevision == revision
                else { return }
                let content = self.hostIntegrations.replace(state: state)
                self.integrationsModel.replaceExternalContent(content)
            } catch {
                // 集成目的页的显式“重新检测”会显示错误反馈；后台/打开面板刷新只保留
                // 上一份事实，避免一次瞬时 I/O 失败把两条宿主行抹成伪造状态。
            }
        }
    }

    /// 集成目的页的显式 refresh/action 赢过任何较早的后台刷新。发布与失效都在
    /// MainActor 上完成，因此 Panel 与 retained window 永远同时切到同一份 content。
    fileprivate func publishHostIntegrationState(
        _ state: HostIntegrationPresentationState
    ) -> IntegrationDestinationContent {
        hostIntegrationRefreshRevision &+= 1
        hostIntegrationRefreshTask?.cancel()
        return hostIntegrations.replace(state: state)
    }

    @objc private func togglePanel() {
        if panelWindow.isShown {
            panelWindow.close()
        } else {
            showPanel()
        }
    }

    fileprivate func openNoticeInPanel(_ action: EventNoticeAction?) {
        let model = eventNoticeRuntime.model
        if let action, !model.isCurrent(action) { return }
        model.openReading(.panel)
        if let action, !model.readingSnapshot.records.contains(where: { $0.action == action }) {
            model.refreshReading()
        }
        showPanel()
        focusCoordinator.requestNotice(action)
    }

    private func showPanel() {
        guard let button = statusItem.button, !panelWindow.isShown else { return }
        let visibleHeight =
            button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 560
        panelWindow.contentSize.height = min(560, max(400, visibleHeight - 32))
        let settingsWasForeground = settingsWindowController.ownsForegroundBeforePanel
        panelSettingsHandback.begin(settingsWasForeground: settingsWasForeground)
        settingsWindowController.prepareForPanelPresentation(
            settingsWasForeground: settingsWasForeground)
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        panelWindow.show(relativeTo: button.bounds, of: button)
        settingsWindowController.finishStatusActivation()
    }

    /// Every panel destination closes the transient Panel first, then presents the same retained
    /// Settings window from ``panelDidClose(_:)``. The typed route replaces the former parallel
    /// window ownership while preserving the exact panel focus target for the final handback.
    fileprivate func requestSoundsSettingsPresentation(
        route: SoundPacksWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        requestSettingsPresentation(
            request: .route(.sounds(route)),
            returnFocusTo: target)
    }

    /// Carries the panel's exact Sound Scope into the unified Events & Sounds destination.
    fileprivate func requestEventsSettingsPresentation(
        route: EventSettingsWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        requestSettingsPresentation(
            request: .eventShortcut(route),
            returnFocusTo: target)
    }

    /// Global-shortcut actions are owned by MenuBarController, not the Settings view that edits
    /// them. The route reads the panel's stable persisted scope, validates it against the current
    /// production projection, and deliberately preserves a stale known scope so Events can show
    /// the visible recovery reason instead of silently guessing another target.
    fileprivate func performGlobalShortcut(_ action: GlobalShortcutAction) {
        switch action {
        case .togglePanel:
            togglePanel()
        case .openSettings:
            requestSettingsWindowPresentation()
        case .openCurrentScopeEvents:
            requestCurrentScopeEventsFromShortcut()
        }
    }

    private func globalShortcutHandbackApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return resolveGlobalShortcutHandbackApplication(
            frontmostApplication: frontmost,
            previousApplication: previousApp,
            isCurrentApplication: {
                $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
            })
    }

    private func requestCurrentScopeEventsFromShortcut() {
        let scopes = panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: eventSettingsModel.config,
            language: languageStore.language)
        let storedValue = UserDefaults.standard.string(forKey: panelSoundScopeDefaultsKey)
        let route = globalShortcutEventSettingsRoute(
            storedValue: storedValue,
            scopes: scopes)

        requestSettingsPresentation(
            request: .eventShortcut(route),
            returnFocusTo: nil,
            handbackApplication: globalShortcutHandbackApplication())
    }

    /// The Integrations destination follows the same close-before-show rule as other management
    /// routes; the unified Settings close callback reopens the panel at the exact trigger.
    fileprivate func requestIntegrationsSettingsPresentation(
        preselect host: HostID?,
        returnFocusTo target: PanelFocusTarget
    ) {
        let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode
        requestSettingsPresentation(
            request: .route(.integrations(surface: selectedHost.surfaceID)),
            returnFocusTo: target)
    }

    /// Production generic Settings entry. No explicit route is supplied, so the retained owner
    /// restores the last legal top-level destination from the shared typed preferences.
    func requestSettingsWindowPresentation() {
        requestSettingsPresentation(
            request: .route(nil),
            returnFocusTo: nil,
            handbackApplication: globalShortcutHandbackApplication())
    }

    private func requestSettingsPresentation(
        request: SettingsPresentationRequest,
        returnFocusTo target: PanelFocusTarget?,
        handbackApplication explicitHandback: NSRunningApplication? = nil
    ) {
        let presentation = PendingSettingsPresentation(
            request: request,
            panelFocusTarget: target,
            handbackApplication: explicitHandback ?? previousApp)
        previousApp = nil

        guard panelWindow.isShown else {
            presentSettings(presentation)
            return
        }
        pendingSettingsPresentation = presentation
        // Close child surfaces and deliver the pending transition through the same lifecycle.
        panelWindow.close()
    }

    private func presentSettings(_ presentation: PendingSettingsPresentation) {
        // Mutual exclusion: presenting Settings collapses the top notice surface first.
        eventNoticeWindowController.close()
        settingsWindowController.showWindow(
            request: presentation.request,
            returnFocusTo: presentation.handbackApplication
        ) { [weak self] latestHandbackApplication in
            guard let self else { return }
            let handback = latestHandbackApplication ?? presentation.handbackApplication
            if let target = presentation.panelFocusTarget {
                _ = self.restorePanelFocus(
                    to: target,
                    latestHandbackApplication: handback)
            } else {
                self.activateHandbackApplication(handback)
            }
        }
    }

    private func restorePanelFocus(
        to target: PanelFocusTarget,
        latestHandbackApplication: NSRunningApplication?
    ) -> Bool {
        // Preserve the latest explicit Settings handback target if the restored Panel routes
        // back into Settings. Ordinary Panel dismissal never activates another application.
        if let latestHandbackApplication {
            previousApp = latestHandbackApplication
        }
        pendingRestoredPanelFocusTarget = target
        showPanel()
        return panelWindow.isShown
    }

    private func activateHandbackApplication(_ application: NSRunningApplication?) {
        guard
            let application,
            !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: application)
            application.activate()
        } else {
            application.activate(options: [])
            NSApp.deactivate()
        }
    }

    /// Settings and the top notice list are mutually exclusive; the notice window drives this
    /// through the action router before it takes the key status. When the notice was not opened
    /// from the panel, the current frontmost app is captured here so the close path can return
    /// the foreground to it (SPEC: 关闭归还原宿主).
    fileprivate func dismissSettingsForEventNoticeInteraction() -> (@MainActor () -> Void)? {
        if let restoration = settingsWindowController.closeForMutualExclusion() {
            return restoration
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let handback =
            frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmost
        return { [weak self] in self?.handbackEventNoticeFocus(to: handback) }
    }

    /// The notice window requests this only while it still owns the key status. If it was
    /// opened from the panel, focus returns to the panel's recent-notices entry; otherwise the
    /// foreground goes back to the app captured when the notice became interactive.
    private func handbackEventNoticeFocus(to application: NSRunningApplication?) {
        if panelWindow.isShown {
            panelWindow.contentViewController?.view.window?.makeKey()
            focusCoordinator.requestFocus(target: .recentNotices)
        } else {
            activateHandbackApplication(application)
        }
    }

    // MARK: - Native Panel lifecycle

    private func panelDidShow() {
        requestHostIntegrationRefresh()
        panelWindow.contentViewController?.view.window?.makeFirstResponder(
            panelWindow.contentViewController?.view)
        let restoredTarget = pendingRestoredPanelFocusTarget
        pendingRestoredPanelFocusTarget = nil
        focusCoordinator.requestFocus(target: restoredTarget)
    }

    private func panelDidClose(_ reason: MenuBarPanel.Dismissal) {
        focusCoordinator.notePanelHidden()
        defer { settingsWindowController.finishPanelPresentation() }
        let restoreSettings = panelSettingsHandback.takeSettingsRestoration()

        let settingsPresentation = pendingSettingsPresentation
        pendingSettingsPresentation = nil
        if let settingsPresentation {
            presentSettings(settingsPresentation)
            return
        }
        previousApp = nil

        // A nonactivating panel releases keyboard focus itself. Only an explicit dismissal
        // may restore Settings' prior key target; outside interaction belongs to its recipient.
        if reason == .explicit, restoreSettings {
            _ = settingsWindowController.restoreVisibleWindowAfterPanelClose()
        }
    }
}
