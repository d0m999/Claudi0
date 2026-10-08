import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

@MainActor
private final class ReviewFindingPlayback: SoundPacksEditorNativeEffectsAdapter {
    var startsPlayback = false
    private(set) var attempts = 0
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func playAudio(
        fileURL: URL, volume: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        attempts += 1
        return startsPlayback
    }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}

private actor ReviewFindingCredentials: AICueCredentialManaging {
    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }
    func save(_ credential: SensitiveCredentialInput, for profileID: AICueProviderProfileID)
        async throws -> AICueCredentialStatus
    {
        await status(for: profileID)
    }
    func delete(for profileID: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {}
}

private actor ReviewFindingGenerator: AICueGenerating {
    private(set) var requests = 0
    func generate(
        description: String, locale: String, providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        requests += 1
        throw AICueGenerationError.provider(.serviceUnavailable)
    }
    func discard(generationID: UUID) {}
    func discardAll() {}
}

@MainActor
func runReviewFindingRepairSuites() async {
    await suite("Review findings: mounted group preview retains the failure reason") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            await withTempDirectory { root in
                let packs = root.appendingPathComponent("packs")
                let configFile = root.appendingPathComponent("config.json")
                writeFixture(
                    #"{"id":"pack-a","events":{"stop":"stop.mp3","task_start":"start.mp3"}}"#,
                    to: packs.appendingPathComponent("pack-a/manifest.json"))
                writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
                writeFixture("audio", to: packs.appendingPathComponent("pack-a/start.mp3"))
                let config = ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.7)
                try! JSONEncoder().encode(config).write(to: configFile)
                let model = PanelConfigController(
                    previewConfigState: .operational(config),
                    eventRows: [
                        EventRow(
                            event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true),
                        EventRow(
                            event: .taskStart, coverage: .present(fileName: "start.mp3"),
                            enabled: true),
                    ],
                    environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                    previewConfigFile: configFile)
                let playback = ReviewFindingPlayback()
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language, route: .events(scope: .global, event: .stop),
                    eventSettingsModel: model,
                    nativeEffects: SoundPacksEditorNativeEffectsDispatcher(adapter: playback))
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 1240, height: 820))
                defer { probe.close() }
                await probe.settle()
                expect(model.libraryPresentationState.hasUsableSnapshot, "valid library snapshot")
                expect(
                    probe.menuIsEnabled(identifier: "workspace.event.task_start.preview") == true,
                    "a second playable event row is mounted")
                expect(probe.pressControl("workspace.event.stop.preview"), "mounted preview action")
                await probe.settle()
                expect(playback.attempts == 1, "the real preview path reaches the refusing player")
                expect(
                    fixture.eventSettingsSelection.previewFailure?.reason == .playbackFailed,
                    "the selection retains the playback failure")
                let failureID = "workspace.event.preview-failure.stop"
                let reason = localizedEventPreviewAttemptFailure(
                    .playbackFailed, language: language)
                let visibleReason =
                    probe.controlLabel(failureID)
                    ?? probe.menuAccessibilityValue(identifier: failureID)
                expect(
                    visibleReason?.contains(reason) == true,
                    "\(language): the production event row visibly explains failure and recovery")
                expect(
                    probe.menuAccessibilityElement(
                        identifier: "workspace.event.preview-failure.task_start")
                        == nil,
                    "failure stays attached to the attempted event")
                playback.startsPlayback = true
                expect(
                    probe.pressControl("workspace.event.stop.preview"),
                    "explicit retry remains available")
                await probe.settle()
                expect(playback.attempts == 2, "retry starts the player")
                expect(
                    fixture.eventSettingsSelection.previewFailure == nil
                        && probe.menuAccessibilityElement(identifier: failureID) == nil,
                    "successful retry removes the old visible failure")
            }
        }
    }

    await suite("Review findings: the production generate button accepts its full visible area") {
        let points: [(String, CGFloat, CGFloat)] = [
            ("center", 62, 17), ("left", 2, 17), ("right", 122, 17),
            ("bottom", 62, 2), ("top", 62, 32), ("outside", -2, 17),
        ]
        for language in [ClaudioAppLanguage.english, .zhHans] {
            for (name, x, y) in points {
                let generator = ReviewFindingGenerator()
                let defaultsName = "com.claudio.review-findings.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: defaultsName)!
                defer { defaults.removePersistentDomain(forName: defaultsName) }
                let model = AICueGenerationViewModel(
                    credentialManager: ReviewFindingCredentials(), generator: generator,
                    providerProfileID: .elevenLabsGlobal,
                    providerPreferences: AICueProviderPreferences(defaults: defaults))
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language,
                    route: .sounds(
                        .editEvent(surface: nil, packID: "settings-fixture-pack", event: .stop)),
                    aiCueViewModel: model)
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640))
                await probe.settle()
                expect(probe.chooseSource(event: .stop, index: 0), "open the production AI form")
                model.updateDescription("short bell")
                await probe.settle()
                expect(
                    probe.menuIsEnabled(identifier: "settings.sounds.ai.generate") == true,
                    "generation is available before the click")
                expect(
                    clickReviewGenerateButton(probe, x: x, y: y),
                    "\(language) \(name): deliver mouse input to the mounted production button")
                await probe.settle()
                let requests = await generator.requests
                expect(
                    requests == (name == "outside" ? 0 : 1),
                    "\(language) \(name): the 124×34pt visible button owns the hit area, requests=\(requests)"
                )
                probe.close()
            }
        }
    }
}

@MainActor
private func clickReviewGenerateButton(
    _ probe: SettingsSoundsNativeLayoutProbe, x: CGFloat, y: CGFloat
) -> Bool {
    guard let window = probe.sheetWindow,
        let surface = probe.menuAccessibilityElement(identifier: "settings.sounds.ai.task-surface"),
        let frame = surface.accessibilityFrame?(), frame.width >= 124,
        abs(frame.height - 34) < 1
    else { return false }
    let point = window.convertPoint(fromScreen: NSPoint(x: frame.minX + x, y: frame.minY + y))
    func event(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
    guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
    // Native button tracking can synchronously consume mouse-up from the application queue.
    NSApplication.shared.postEvent(up, atStart: true)
    window.sendEvent(down)
    return true
}
