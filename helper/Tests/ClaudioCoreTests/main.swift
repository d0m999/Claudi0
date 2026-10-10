import ClaudioCore
import Foundation

// Dependency-free test harness.
//
// This machine has CommandLineTools only (no Xcode), so `swift test` cannot resolve
// XCTest (absent) or Swift Testing (bundled but not exposed to SwiftPM / no macro
// plugin). These checks therefore run as a plain executable: `swift run claudio-tests`,
// exit 0 == green. Once a full Xcode is installed, move each `suite`/`expect` block
// into a `.testTarget` as `@Test` functions with `#expect` — the assertions map 1:1.
//
// `main.swift` is the only file allowed top-level executable statements, so it stays a
// thin orchestrator: shared `expect`/`suite` primitives + calls into per-area suite
// functions defined in sibling files (`EventSuite.swift`, `FileLockSuite.swift`,
// `DoctorSuite.swift`, `PathsSuite.swift`, `PlaySuite.swift`, `LogSuite.swift`,
// `HookStatusSuite.swift`, `VolumeSuite.swift`, `UseSuite.swift`, `SetupSuite.swift`,
// `VersionCompatibilitySuite.swift`, `HookCommandMatchingSuite.swift`,
// `ClaudioVersionSuite.swift`,
// `EventEnabledSuite.swift`, `ConfigMutationSuite.swift`, `PackContentSafetySuite.swift`,
// `LockSeparationSuite.swift`, `PackSelectionSuite.swift`, `MasterVolumeSuite.swift`,
// `ConfigConcurrencySuite.swift`), matching the project's "many small files" convention.

var totalChecks = 0
var failures = 0

if CommandLine.arguments.dropFirst().first == "--zed-pty-launch" {
    let command = Array(CommandLine.arguments.dropFirst(2))
    let descriptor = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDIO_TEST_PTY_DESCRIPTOR"]
            ?? "/private/tmp/claudio-absent-test-navigation-descriptor.json")
    // Exercise the same worker-thread signal mask as the real AsyncParsableCommand.
    DispatchQueue.global().async {
        do { exit(try ZedPTYSession.run(command: command, descriptor: descriptor)) } catch {
            exit(65)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--zed-pty-bridge") {
    runZedPTYBridgeSuites()
    runZedPTYSessionSuites()
    print("Zed PTY bridge: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.dropFirst().first == "--default-lock-probe" {
    exit(runDefaultLockChildProbe())
}

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

@MainActor
func asyncSuite(_ name: String, _ body: @MainActor () async -> Void) async {
    print("• \(name)")
    await body()
}

if CommandLine.arguments.contains("--host-automation") {
    await runHostIntegrationAutomationSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--host-review-regressions") {
    await runHostIntegrationReviewRegressionSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--host-integration-checks") {
    await runHostIntegrationReviewRegressionSuites()
    await runHostIntegrationAutomationSuites()
    await runConcreteHostIntegrationAdapterSuites()
    await runWorkBuddyIntegrationAdapterSuites()
    await runHostIntegrationManagerOperationSuites()
    runDoctorSuites()
    runDualHostDoctorSuites()
    runPrivateDirectorySuites()
    runConfigFileTransactionSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--host-integration-model") {
    runHostIntegrationModelSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--hook-command-matching") {
    runHookCommandMatchingSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--additional-hosts") {
    await runAdditionalHostIntegrationSuites()
    await runAdditionalHostMigrationSuites()
    runAdditionalHostHookSuites()
    print("\(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--questions") {
    runQuestionBindingSuites()
    runHostQuestionHookSuites()
    print("Questions: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--system-sounds") {
    runSystemSoundSelectionSuites()
    runPackEventSoundSourceSuites()
    runWorkspaceSoundRulesSuites()
    runPlaySuites()
    print("System sounds: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--system-login-ancestry") {
    runHostProcessAncestrySuites()
    runHostNavigationEvidenceSuites()
    runSystemLoginAncestrySuites()
    print("System login ancestry: \(totalChecks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

runEventSuites()
runQuestionBindingSuites()
runHostQuestionHookSuites()
await runAdditionalHostIntegrationSuites()
await runAdditionalHostMigrationSuites()
runAdditionalHostHookSuites()
runHostIntegrationModelSuites()
runHostHookReceiptSuites()
runHostHookRunnerSuites()
runHostEventSourceSuites()
runHostProcessAncestrySuites()
runHostNavigationEvidenceSuites()
runSystemLoginAncestrySuites()
runZedPTYBridgeSuites()
runZedPTYSessionSuites()
runHookInputReaderSuites()
runEventNoticeTransportSuites()
runConfigFileTransactionSuites()
runAnchoredFileIOSuites()
runTerminalDisplaySuites()
runFileWriteWatchSuites()
runClaudeCodeHooksTransformSuites()
runCodexHooksTransformSuites()
runWorkBuddyHooksTransformSuites()
runWorkBuddyHookPayloadPolicySuites()
runWorkBuddyNotificationSuites()
runLegacyCodexNotifyMigrationSuites()
await runConcreteHostIntegrationAdapterSuites()
await runWorkBuddyIntegrationAdapterSuites()
await runWorkBuddyAcceptancePreflightSuites()
await runHostIntegrationManagerOperationSuites()
await runHostIntegrationAutomationSuites()
await runHostIntegrationReviewRegressionSuites()
runFileLockSuites()
runDoctorSuites()
runDualHostDoctorSuites()
runSettingsInstallerSuites()
runPrivateDirectorySuites()
runBootstrapReportSuites()
runPathsSuites()
runSourceScannerSuites()
runLockSeparationSuites()
runDefaultLockBehaviorSuites()
runAtomicWriteSuites()
runDynamicQuietStateSuites()
runPlaySuites()
runLogSuites()
runHookStatusSuites()
runVolumeSuites()
runUseSuites()
runSetupSuites()
runQuarantineSuites()
runSetupQuarantineSuites()
runVersionCompatibilitySuites()
runClaudioVersionSuites()
runHookCommandMatchingSuites()
runEventEnabledSuites()
runConfigMutationSuites()
runPackContentSafetySuites()
runPackSelectionSuites()
runMasterVolumeSuites()
runSurfaceSoundPreferencesSuites()
runWorkspaceSoundRulesSuites()
runSystemSoundSelectionSuites()
runPackEventSoundSourceSuites()
runWorkspaceDeletionSuites()
runStarredPacksSuites()
runConfigConcurrencySuites()
runLegacyInstallPipelineSuites()
runLocalActivitySummarySuites()

// MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
