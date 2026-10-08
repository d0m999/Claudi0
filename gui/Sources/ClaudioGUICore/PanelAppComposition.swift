import ClaudioCore
import Foundation

/// App-lifetime assembly of the shared core owners. Native windows, system observers and
/// refresh-task lifecycle remain in the executable; consumers borrow these exact instances.
@MainActor
package final class PanelAppComposition {
    package struct Environment {
        package let configFile: URL
        package let configLockFile: URL
        package let audioEnvironment: AudioImportEnvironment
        package let preferences: ClaudioPreferences
        package let soundScopeDefaults: UserDefaults
        package let aiCueTemporaryRoot: URL
        package let hostIntegrationState: HostIntegrationPresentationState
        package let configurationSources: [HostID: String]
        package let integrationMatrixProvider: HostIntegrationMatrixProvider
        package let integrationActionProvider: HostIntegrationActionProvider
        package let integrationRefreshFeedback: IntegrationsFeedbackText

        package init(
            configFile: URL,
            configLockFile: URL,
            audioEnvironment: AudioImportEnvironment,
            preferences: ClaudioPreferences,
            soundScopeDefaults: UserDefaults,
            aiCueTemporaryRoot: URL,
            hostIntegrationState: HostIntegrationPresentationState,
            configurationSources: [HostID: String],
            integrationMatrixProvider: HostIntegrationMatrixProvider,
            integrationActionProvider: HostIntegrationActionProvider,
            integrationRefreshFeedback: IntegrationsFeedbackText = .localized(
                key: .feedbackRedetectedSources, arguments: [])
        ) {
            self.configFile = configFile
            self.configLockFile = configLockFile
            self.audioEnvironment = audioEnvironment
            self.preferences = preferences
            self.soundScopeDefaults = soundScopeDefaults
            self.aiCueTemporaryRoot = aiCueTemporaryRoot
            self.hostIntegrationState = hostIntegrationState
            self.configurationSources = configurationSources
            self.integrationMatrixProvider = integrationMatrixProvider
            self.integrationActionProvider = integrationActionProvider
            self.integrationRefreshFeedback = integrationRefreshFeedback
        }
    }

    package struct Adapters {
        package let previewPlayer: (any AudioPreviewPlaying)?
        package let globalHotKeys: GlobalHotKeyAdapter
        package let shortcutPersistence: GlobalShortcutPersistenceAdapter
        package let clipboardWriter: IntegrationDestinationClipboardWriter
        package let makeAICueViewModel:
            @MainActor (URL, any AudioDurationProbing) throws -> AICueGenerationViewModel
        package let makeActivityDiagnostics: @MainActor () -> ActivityDiagnosticsModel
        package let makeAboutSettings: @MainActor ([AboutSurfaceFact]) -> AboutSettingsModel

        package init(
            previewPlayer: (any AudioPreviewPlaying)? = nil,
            globalHotKeys: GlobalHotKeyAdapter,
            shortcutPersistence: GlobalShortcutPersistenceAdapter,
            clipboardWriter: IntegrationDestinationClipboardWriter,
            makeAICueViewModel:
                @escaping @MainActor (URL, any AudioDurationProbing) throws ->
                AICueGenerationViewModel,
            makeActivityDiagnostics: @escaping @MainActor () -> ActivityDiagnosticsModel,
            makeAboutSettings: @escaping @MainActor ([AboutSurfaceFact]) -> AboutSettingsModel
        ) {
            self.previewPlayer = previewPlayer
            self.globalHotKeys = globalHotKeys
            self.shortcutPersistence = shortcutPersistence
            self.clipboardWriter = clipboardWriter
            self.makeAICueViewModel = makeAICueViewModel
            self.makeActivityDiagnostics = makeActivityDiagnostics
            self.makeAboutSettings = makeAboutSettings
        }
    }

    package struct Actions {
        package let audibilityInputsChanged: @MainActor @Sendable () -> Void
        package let performGlobalShortcut: @MainActor @Sendable (GlobalShortcutAction) -> Void
        /// A nil result means the native router is not bound yet. Publish through the same
        /// retained store in that case, just as the pre-super.init composition did.
        package let publishHostIntegrationState:
            @MainActor @Sendable (HostIntegrationPresentationState) ->
                IntegrationDestinationContent?

        package init(
            audibilityInputsChanged: @escaping @MainActor @Sendable () -> Void,
            performGlobalShortcut: @escaping @MainActor @Sendable (GlobalShortcutAction) -> Void,
            publishHostIntegrationState:
                @escaping @MainActor @Sendable (HostIntegrationPresentationState) ->
                IntegrationDestinationContent?
        ) {
            self.audibilityInputsChanged = audibilityInputsChanged
            self.performGlobalShortcut = performGlobalShortcut
            self.publishHostIntegrationState = publishHostIntegrationState
        }
    }

    package let manualPreview: ManualAudioPreviewSession
    package let audioEnvironment: AudioImportEnvironment
    package let preferences: ClaudioPreferences
    package let soundPackLibrary: SoundPackLibrary
    package let soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator
    package let soundPacksEditorOwner: SoundPacksEditorOwner
    package let soundScopeSelection: SoundScopeSelection
    package let eventSettingsModel: PanelConfigController
    package let hostIntegrations: HostIntegrationPresentationStore
    package let integrationMatrixProvider: HostIntegrationMatrixProvider
    package let integrationsModel: IntegrationDestinationModel
    package let globalShortcutSettings: GlobalShortcutSettingsModel
    package let aiCueViewModel: AICueGenerationViewModel
    package let generationHistory: GenerationHistoryStore
    package var generationCoordinator: AICueGenerationCoordinator { aiCueViewModel.coordinator }
    package var soundPackDrafts: SoundPackDraftStore { soundPacksEditorOwner.draftStore }
    package let activityDiagnostics: ActivityDiagnosticsModel
    package let aboutSettings: AboutSettingsModel

    package init(environment: Environment, adapters: Adapters, actions: Actions) throws {
        manualPreview = ManualAudioPreviewSession(
            player: adapters.previewPlayer ?? UnavailablePreviewPlayer())
        audioEnvironment = environment.audioEnvironment
        preferences = environment.preferences
        integrationMatrixProvider = environment.integrationMatrixProvider
        let refreshCoordinator = SoundPacksRefreshCoordinator()
        soundPacksRefreshCoordinator = refreshCoordinator
        let library = SoundPackLibrary(environment: environment.audioEnvironment)
        soundPackLibrary = library
        soundPacksEditorOwner = SoundPacksEditorOwner(
            configFile: environment.configFile,
            lockFile: environment.configLockFile,
            environment: environment.audioEnvironment,
            soundPackLibrary: library,
            refreshCoordinator: refreshCoordinator)
        let selection = SoundScopeSelection(defaults: environment.soundScopeDefaults)
        soundScopeSelection = selection
        eventSettingsModel = PanelConfigController(
            configFile: environment.configFile,
            lockFile: environment.configLockFile,
            environment: environment.audioEnvironment,
            soundPackLibrary: library,
            afterFullReload: { _ in actions.audibilityInputsChanged() },
            soundPacksRefreshCoordinator: refreshCoordinator,
            soundScopeSelection: selection)

        let hostIntegrations = HostIntegrationPresentationStore(
            state: environment.hostIntegrationState,
            configurationSources: environment.configurationSources)
        self.hostIntegrations = hostIntegrations
        let matrixProvider = environment.integrationMatrixProvider
        let actionProvider = environment.integrationActionProvider
        integrationsModel = IntegrationDestinationModel(
            content: hostIntegrations.content,
            refreshHandler: IntegrationDestinationRefreshHandler { [weak hostIntegrations] in
                let state = try await matrixProvider()
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actions.publishHostIntegrationState(state)
                    ?? hostIntegrations.replace(state: state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: .information,
                    feedbackText: environment.integrationRefreshFeedback)
            },
            actionHandler: IntegrationDestinationActionHandler { [weak hostIntegrations] action in
                let outcome = try await actionProvider(action)
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actions.publishHostIntegrationState(outcome.state)
                    ?? hostIntegrations.replace(state: outcome.state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: outcome.feedbackKind,
                    feedbackText: outcome.feedbackText)
            },
            preferences: environment.preferences,
            clipboardWriter: adapters.clipboardWriter,
            onContentChanged: { [weak hostIntegrations] content in
                hostIntegrations?.replace(content: content)
            })
        globalShortcutSettings = GlobalShortcutSettingsModel(
            adapter: adapters.globalHotKeys,
            persistence: adapters.shortcutPersistence,
            actionHandler: actions.performGlobalShortcut)
        generationHistory = GenerationHistoryStore(
            directory: environment.aiCueTemporaryRoot
                .deletingLastPathComponent().appendingPathComponent("generation-history"))
        aiCueViewModel = try adapters.makeAICueViewModel(
            environment.aiCueTemporaryRoot, environment.audioEnvironment.durationProbe)
        aiCueViewModel.installGenerationHistory(generationHistory)
        activityDiagnostics = adapters.makeActivityDiagnostics()
        aboutSettings = adapters.makeAboutSettings(hostIntegrations.safeSurfaceFacts)
    }
}

@MainActor
private final class UnavailablePreviewPlayer: AudioPreviewPlaying {
    func play(fileAt url: URL, volume: Float) -> Bool { false }
    func play(
        fileAt url: URL, volume: Float,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool { false }
    func stop() {}
}
