import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioPanelPresentation
import ClaudioSettingsPresentation
import Foundation

// Dependency-free test harness — mirrors `helper/Tests/ClaudioCoreTests/main.swift`
// exactly (down to comment wording), for the same reason: this machine has
// CommandLineTools only (no Xcode), so `swift test` cannot resolve XCTest (absent) or
// Swift Testing (bundled but not exposed to SwiftPM / no macro plugin) here. Green
// signal: `swift run --package-path gui claudio-gui-tests`, exit 0.
//
// `main.swift` is the only file allowed top-level executable statements, so it stays a
// thin orchestrator: shared `expect`/`suite` primitives + calls into per-area suite
// functions defined in sibling files (`OnboardingStateSuite.swift`,
// `OnboardingCopySuite.swift`, `OnboardingDetectorSuite.swift`,
// `OnboardingViewModelSuite.swift`, `AudioFormatSniffSuite.swift`, `AudioImportSuite.swift`,
// `AudioImportBatchSuite.swift`, `AudioImportViewModelSuite.swift`,
// `CoverageStateSuite.swift`, `ManifestBindingSuite.swift`,
// `PackGallerySuite.swift`, `PackAudioInventorySuite.swift`, `PackForkSuite.swift`,
// `PackRestoreSuite.swift`,
// `EventMuteControllerSuite.swift`, `MasterVolumeControllerSuite.swift`,
// `PanelFocusOrderSuite.swift`, `ContrastSuite.swift`,
// `PanelSoundScopeInteractionSuite.swift`,
// `ContrastHexParsingSuite.swift`,
// `PanelTypeSizeSuite.swift`, `PanelAccessibilitySuite.swift`, `PanelConfigSuite.swift`,
// `PanelFocusCoordinatorSuite.swift`,
// `PreviewFixturesSuite.swift`, `OnboardingActionsSuite.swift`, `ReleaseLayoutSuite.swift`,
// `MultiProviderPrototypeContractSuite.swift`,
// `ReleaseCandidateArtifactSuite.swift`,
// `ChatAXTracerSuite.swift`, `ChatAXTracerWiringSuite.swift`,
// `WorkBuddyKeyboardAccessibilitySuite.swift`, `VolumeDragSessionSuite.swift`,
// `PanelWriteFailuresSuite.swift`, `HitTargetSuite.swift`).

var totalChecks = 0
var failures = 0

@MainActor
func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    totalChecks += 1
    if !condition {
        failures += 1
        print("  ✗ \(message())  (\(file):\(line))")
    }
}

@MainActor
func suite(_ name: String, _ body: @MainActor () -> Void) {
    print("• \(name)")
    body()
}

/// Async overload of ``suite(_:_:)`` — for suites whose body must `await` (the
/// `AudioImportViewModel` drop handlers became `async` so their import pipeline runs off
/// the `@MainActor`, a T8 swift-review follow-up). Sync suites keep using the overload
/// above; the presence/absence of `await` at the call site selects the overload.
@MainActor
func suite(_ name: String, _ body: @MainActor () async -> Void) async {
    print("• \(name)")
    await body()
}

// A separate process holds the same flock as the production manifest writer. The parent
// closes stdin to release it; no test path under the user's home is involved.
if let index = CommandLine.arguments.firstIndex(of: "--manifest-lock-holder") {
    guard CommandLine.arguments.count > index + 1 else { exit(2) }
    let lock = FileLock(path: CommandLine.arguments[index + 1])
    guard lock.tryLock() else { exit(3) }
    _ = readLine()
    lock.unlock()
    exit(0)
}

if CommandLine.arguments.contains("--settings-notification-navigation") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSettingsNotificationNavigationSuites()
        print("Settings notification navigation: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--settings-navigation-native-focus") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    Task { @MainActor in
        await runSettingsNavigationFocusSuites()
        print("Settings navigation native focus: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--workspace-deletion-native-focus") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    Task { @MainActor in
        await runWorkspaceDeletionFocusSuites()
        print("Workspace deletion native focus: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--ai-cue-native-focus") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    Task { @MainActor in
        await runAICueDescriptionFocusSuites()
        print("AI cue native focus: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--sound-editor-ai-lifecycle") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSoundEditorAILifecycleSuites()
        print("Sound editor AI lifecycle: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--settings-native-states") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSettingsNativeStatesSuites()
        print("Settings native states: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--event-animation")
    || CommandLine.arguments.contains("--event-animation-layout")
{
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runEventAnimationIntegrationSuites()
        print("Event animation: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--question-intent") {
    runQuestionIntentPresentationSuites()
    runCodexDevelopmentNoticeSuites()
    runCodexQuestionObservationSuites()
    print("Question intent: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--question-integration-contract") {
    runLocalizationSuites()
    runHostIntegrationPresentationSuites()
    runHostSourceRowLocalizationSuites()
    runIntegrationDestinationPresentationSuites()
    runWorkBuddyVisualStateBaselineSuites()
    await runHostIntegrationManagerBridgeSuites()
    print("Question integration: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--review-repairs") {
    await runReviewRepairSuites()
    runNativePrototypeMigrationSuites()
    runEventBannerActionSuites()
    await runSessionNavigationSuites()
    runHostSessionNavigationSuites()
    runTmuxNavigationSuites()
    await runIDENavigationSocketSuites()
    await runNavigationReviewRegressionSuites()
    await runSettingsPresentationLifecycleSuites()
    print("Review repairs: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--view-wiring") {
    runViewWiringSuites()
    print("View wiring: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--focus-scope-review") {
    runFocusRequestCoordinatorSuites()
    runPanelSettingsChoreographySuites()
    runSoundScopeSelectionSuites()
    runEventSettingsWindowSelectionSuites()
    runWorkspaceDeletionPresentationSuites()
    runSettingsNavigationSuites()
    runIntegrationDestinationPresentationSuites()
    await runIntegrationDestinationModelSuites()
    runSoundPacksWindowAccessibilitySuites()
    await runSettingsPresentationLifecycleSuites()
    await runSoundPacksEditorViewSuites()
    print("Focus and scope review: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--event-attention") {
    runQuestionIntentPresentationSuites()
    runCodexDevelopmentNoticeSuites()
    runCodexQuestionObservationSuites()
    runNativePrototypeMigrationSuites()
    runEventNoticeModelSuites()
    runEventBannerActionSuites()
    runEventNoticeFocusSuites()
    await runSessionNavigationSuites()
    runHostSessionNavigationSuites()
    runTmuxNavigationSuites()
    await runIDENavigationSocketSuites()
    await runNavigationReviewRegressionSuites()
    await runEventAttentionStressSuites()
    // Native AppKit event delivery stays terminal: on newer macOS versions, yielding back to
    // Swift's async-main drain queue after synthetic window tracking can end the harness early.
    runEventNoticePresentationSuites()
    runEventBannerLayoutSuites()
    print("Event attention: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--panel-settings-handback") {
    await runPanelSettingsHandbackSuites()
    runPanelSettingsChoreographySuites()
    await runStatusItemWindowOrderGuardSuites()
    print("Panel settings handback: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--ai-cue-assets") {
    await runAICueAssetFetchSuites()
    print("AI cue assets: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--user-sound-pack-deletion") {
    runUserSoundPackDeletionSuites()
    print("User sound pack deletion: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--sound-window-accessibility") {
    runSoundPacksWindowAccessibilitySuites()
    print("Sound window accessibility: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--sound-editor-import-results") {
    await runSoundPacksEditorAsyncOperationSuites()
    print("Sound editor import results: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--sound-editor-interface") {
    await runSoundPacksEditorInterfaceSuites()
    print("Sound editor interface: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--sound-editor-focus") {
    await runSoundPacksEditorViewSuites()
    print("Sound editor focus: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--sound-editor-detail-identity") {
    await runSoundPacksSettingsDetailIdentityRegressions()
    print("Sound editor detail identity: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--event-settings-retry") {
    runEventSettingsWindowSelectionSuites()
    print("Event settings retry: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--workspace-sounds") {
    runLocalizationSuites()
    runPanelFocusOrderSuites()
    await runPanelPresentationSuites()
    runPanelConfigControllerSuites()
    runWorkspaceSoundPresentationSuites()
    runSoundScopeSelectionSuites()
    runSystemSoundPresentationSuites()
    await runPackSoundSourceSuites()
    runSoundPacksEditorOwnerSuites()
    runSurfaceSoundIssueLifecycleSuites()
    runSettingsNavigationSuites()
    runAICuePackScopedSuites()
    await runAICuePackScopedAsyncSuites()
    print("Workspace sounds: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--system-sounds") {
    runLocalizationSuites()
    runSystemSoundPresentationSuites()
    await runPackSoundSourceSuites()
    await runHostIntegrationManagerBridgeSuites()
    print("System sounds: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--settings-lifecycle") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        runSettingsNavigationSuites()
        await runSettingsPresentationLifecycleSuites()
        print("Settings lifecycle: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--ai-cue-generation") {
    await runAICueGenerationViewModelSuites()
    await runAICueRuntimeSuites()
    runAICueDescriptionSuites()
    print("AI cue generation: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--senseaudio-isolation") {
    await runSenseAudioIsolationSuites()
    print("SenseAudio isolation: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--ai-cue-local-credentials") {
    await runAICueLocalCredentialSuites()
    print("AI cue local credentials: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--ai-cue-pack-scoped") {
    runAICuePackScopedSuites()
    await runAICuePackScopedAsyncSuites()
    print("AI cue pack scoped: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--settings-product-images") {
    runSettingsProductImagesSuites()
    print("Settings product images: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--settings-menu-layout") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSettingsMenuLayoutSuites()
        print("Settings menu layout: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--settings-sounds-layout") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        runSettingsNativeMigrationSuites()
        await runSettingsSoundsLayoutSuites()
        print("Settings sounds layout: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--ai-cue-provider-contracts") {
    runAICueProviderContractsSuites()
    print("AI cue provider contracts: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--senseaudio-provider") {
    await runSenseAudioAICueProviderSuites()
    print("SenseAudio provider: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--panel-announcement") {
    await runPanelAnnouncementSuites()
    print("Panel announcement: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--release-layout") {
    runReleaseLayoutSuites()
    print("Release layout: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--surface-sound-issue") {
    runSurfaceSoundIssueLifecycleSuites()
    print("Surface sound issue: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--panel-error-copy") {
    runPanelErrorCopySuites()
    runPanelFocusOrderSuites()
    print("Panel error copy: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--settings-review-repairs") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSettingsNavigationHistorySuites()
        await runSettingsNativeReadingSuites()
        await runSettingsNativeControlsSuites()
        print("Settings review repairs: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--settings-native-alignment") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runSettingsNavigationHistorySuites()
        await runSettingsNativeShellSuites()
        await runSettingsNativeControlsSuites()
        print("Settings native alignment: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

if CommandLine.arguments.contains("--settings-native-regressions") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        runWorkspaceDeletionPresentationSuites()
        runEventSettingsWindowSelectionSuites()
        await runSettingsRootInteractionSuites()
        await runSoundEditorAILifecycleSuites()
        await runSoundPacksSettingsDetailIdentityRegressions()
        await runSettingsNotificationNavigationSuites()
        print("Settings native regressions: \(totalChecks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
    exit(1)
}

let fullHarnessApplication = NSApplication.shared
fullHarnessApplication.setActivationPolicy(.accessory)
Task { @MainActor in
await runReviewRepairSuites()
await runEventAnimationIntegrationSuites()
runOnboardingStateSuites()
runLocalizationSuites()
runAboutInformationSuites()
runLoginItemManagementSuites()
runOnboardingCopySuites()
runOnboardingDetectorSuites()
await runOnboardingViewModelSuites()
await runOnboardingViewModelDetailSuites()
await runOnboardingFailureLifecycleSuites()
await runSetupNoticeLifecycleSuites()
await runPanelAnnouncementLifecycleSuites()
runOnboardingActionsSuites()
runOnboardingActionsFixSuites()
runSetupNoticeSuites()
await runPanelAnnouncementSuites()
runLocalPreRCSuites()
runReleaseLayoutSuites()
runReleaseCandidateArtifactSuites()
runReleaseSignatureSuites()
runSourceScannerSuites()
runViewWiringSuites()
runHitTargetSuites()
runChatAXTracerWiringSuites()
await runChatAXTracerSuites()
runAudioFormatSniffSuites()
runAICueDomainSuites()
runAICueProviderContractsSuites()
await runAICueRuntimeSuites()
await runAICueHTTPTransportSuites()
await runAICueAssetFetchSuites()
await runAICueSSETransportSuites()
runAICuePayloadDecodingSuites()
await runAICueCredentialSuites()
await runAICueLocalCredentialSuites()
await runAICueElevenLabsProviderSuites()
await runAICueMiniMaxProviderSuites()
await runQwenAICueProviderSuites()
await runSenseAudioAICueProviderSuites()
await runAICueCandidateSetSuites()
await runAICueGenerationEngineSuites()
await runAICueGenerationDispatcherSuites()
await runAICueAdoptionSuites()
await runAICueGenerationViewModelSuites()
runAICuePackScopedSuites()
await runAICuePackScopedAsyncSuites()
await runSenseAudioIsolationSuites()
await runSoundEditorAILifecycleSuites()
runAudioImportSuites()
runAudioImportBatchSuites()
await runAudioImportViewModelSuites()
runCoverageStateSuites()
await runManifestBindingSuites()
runPackGallerySuites()
runPackAudioInventorySuites()
runPackForkSuites()
runPackRestoreSuites()
runUserSoundPackDeletionSuites()
runSoundPacksEditorOwnerSuites()
await runSoundPacksEditorInterfaceSuites()
await runSoundPacksEditorMutationSuites()
await runSoundPacksEditorMutationImpactGapRedSuites()
await runSoundPacksEditorNativeTargetSuites()
await runSoundPacksEditorAsyncOperationSuites()
await runSoundPackImportBindTransactionSuites()
await runSoundPacksEditorGapRedSuites()
await runSoundPacksEditorAnnouncementGapRedSuites()
await runSoundPacksEditorNativeEffectsSuites()
await runSoundPacksEditorViewSuites()
runEventMuteControllerSuites()
runMasterVolumeControllerSuites()
runFocusRequestCoordinatorSuites()
runPanelFocusOrderSuites()
runNativePrototypeMigrationSuites()
runEventNoticeModelSuites()
runEventBannerActionSuites()
runEventNoticeFocusSuites()
await runSessionNavigationSuites()
runHostSessionNavigationSuites()
runTmuxNavigationSuites()
await runIDENavigationSocketSuites()
await runNavigationReviewRegressionSuites()
await runEventAttentionStressSuites()
runPanelSoundScopeInteractionSuites()
await runPanelPresentationSuites()
runEventSettingsWindowSelectionSuites()
runWorkspaceDeletionPresentationSuites()
runContrastSuites()
runContrastHexParsingSuites()
runPanelTypeSizeSuites()
runProductUIModelsSuites()
runPanelAccessibilitySuites()
runHostIntegrationPresentationSuites()
runHostSourceRowLocalizationSuites()
runIntegrationDestinationPresentationSuites()
await runIntegrationDestinationModelSuites()
runWorkBuddyVisualStateBaselineSuites()
runWorkBuddyKeyboardAccessibilitySuites()
await runHostIntegrationManagerBridgeSuites()
runIntegrationDestinationWiringSuites()
runRetainedWindowHandbackTrackerSuites()
await runPanelSettingsHandbackSuites()
runPanelSettingsChoreographySuites()
await runStatusItemWindowOrderGuardSuites()
runPanelConfigSuites()
runPanelRefreshRouteSuites()
await runSoundPacksRefreshSuites()
await runSoundPackLibrarySuites()
await runSoundPackLibraryMutationTransactionSuites()
runSoundPacksWindowAccessibilitySuites()
runSoundPacksEditorAccessibilityPostingSuites()
runSoundPacksWindowStarredPacksSuites()
runPanelConfigControllerSuites()
runWorkspaceSoundPresentationSuites()
runSoundScopeSelectionSuites()
runSystemSoundPresentationSuites()
await runPackSoundSourceSuites()
runPanelConfigFailureLifecycleSuites()
runSurfaceSoundIssueLifecycleSuites()
runPanelFocusCoordinatorSuites()
await runSettingsPreferencesSuites()
runDynamicQuietPolicySuites()
await runActivityDiagnosticsSuites()
runGlobalShortcutsSuites()
runSettingsNavigationSuites()
await runSettingsPresentationLifecycleSuites()
runSettingsPresentationTargetSuites()
runSettingsPresentationSliceSuites()
    await runSettingsRootInteractionSuites()
runSettingsProductImagesSuites()
    await runSettingsSoundsLayoutSuites()
runSettingsNativeMigrationSuites()
runPreviewFixturesSuites()
runMultiProviderPrototypeContractSuites()
runVolumeDragSessionSuites()
runPanelWriteFailuresSuites()
runPanelErrorCopySuites()
runPanelPresentationMountSuites()
runActivityOverviewSuites()
runAICueDescriptionSuites()
// Keep the native AppKit suite after every async suite; see the targeted ordering above.
runEventNoticePresentationSuites()
runEventBannerLayoutSuites()
runQuestionIntentPresentationSuites()
runCodexDevelopmentNoticeSuites()
runCodexQuestionObservationSuites()

    await runSettingsNavigationHistorySuites()
    await runSettingsNativeShellSuites()
    await runSettingsNativeControlsSuites()
    await runSettingsNotificationNavigationSuites()

    // MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
}
fullHarnessApplication.run()
exit(1)
