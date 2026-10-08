import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

@MainActor
private final class ManualCompletionPlayer: AudioPreviewPlaying {
    var succeeds = true
    var completesSynchronously = false
    var stops = 0
    var gains: [Float] = []
    var completions: [@MainActor @Sendable (Bool) -> Void] = []
    func play(fileAt url: URL, volume: Float) -> Bool { succeeds }
    func play(
        fileAt url: URL, volume: Float,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        gains.append(volume)
        completions.append(onCompletion)
        if completesSynchronously { onCompletion(true) }
        return succeeds
    }
    func stop() { stops += 1 }
}

@MainActor
private final class ManualPreviewEffectsAdapter: SoundPacksEditorNativeEffectsAdapter {
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func playAudio(
        fileURL: URL, volume: Double,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool { false }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}

@MainActor
func runManualAudioPreviewSessionSuites() {
    suite("Manual preview: cross-surface claims, completion and old lifecycle isolation") {
        let player = ManualCompletionPlayer()
        let session = ManualAudioPreviewSession(player: player)
        let sounds = ManualPreviewOrigin(.settings), panel = ManualPreviewOrigin(.panel)
        let url = URL(fileURLWithPath: "/fixture/manual.wav")
        let a = session.prepare(origin: sounds, target: "candidate.one")!
        expect(session.playing == nil, "preparing does not pretend playback started")
        expect(session.start(a, fileURL: url, volume: 1), "A starts")
        let b = session.prepare(origin: panel, target: "pack.stop")!
        expect(
            player.stops == 1 && !session.isCurrent(a), "B intent stops A and invalidates its claim"
        )
        expect(session.start(b, fileURL: url, volume: 0.4), "B starts at the group gain")
        expect(
            !session.start(b, fileURL: url, volume: 0.4),
            "a request cannot start twice or reuse completion identity")
        player.completions[0](false)
        session.stop(origin: sounds)
        expect(
            session.playing == b && session.failedOrigin == nil,
            "old completion and close cannot stop B")
        expect(
            !session.start(a, fileURL: url, volume: 1), "late preparation cannot reclaim playback")
        player.completions[1](true)
        expect(session.playing == nil && session.request == nil, "real completion clears playback")
        let c = session.prepare(origin: panel, target: "pack.stop")!
        _ = session.start(c, fileURL: url, volume: 0.4)
        expect(
            session.prepare(origin: panel, target: "pack.stop") == nil, "same target toggles stop")
        expect(player.stops == 2 && session.playing == nil, "toggle stops exactly once")
        session.stop(origin: panel)
        expect(player.stops == 2, "duplicate native/view close is inert")
        expect(player.gains == [1, 0.4, 0.4], "surface gain is preserved")
    }
    suite("Manual preview: failed starts, synchronous completion and pending cancellation") {
        let player = ManualCompletionPlayer()
        let session = ManualAudioPreviewSession(player: player)
        let origin = ManualPreviewOrigin(.settings), url = URL(fileURLWithPath: "/fixture/a.wav")
        player.succeeds = false
        let a = session.prepare(origin: origin, target: "a")!
        expect(!session.start(a, fileURL: url, volume: 1), "failed start is not playing")
        expect(
            session.failedOrigin == origin && session.playing == nil, "failure is scoped to origin")
        session.stop(origin: origin)
        expect(session.failedOrigin == nil, "closing clears its own failure")
        player.succeeds = true; player.completesSynchronously = true
        let b = session.prepare(origin: origin, target: "b")!
        _ = session.start(b, fileURL: url, volume: 1)
        expect(session.playing == nil, "synchronous end cannot reopen a stop capsule")
        let pending = session.prepare(origin: origin, target: "record")!
        session.stop(origin: origin)
        expect(!session.isCurrent(pending), "closing invalidates pending async history work")
    }
    suite("Manual preview sequence: gaps and late steps cannot steal playback") {
        let player = ManualCompletionPlayer()
        let session = ManualAudioPreviewSession(player: player)
        let group = ManualPreviewOrigin(.settings), panel = ManualPreviewOrigin(.panel)
        let url = URL(fileURLWithPath: "/fixture/group.wav")
        let run = session.beginSequence(origin: group)!
        expect(
            session.playStep(run, target: "stop", fileURL: url, volume: 0.2), "first step starts")
        player.completions[0](true)
        expect(
            session.sequence == run && session.playing == nil,
            "gap retains sequence stop eligibility")
        let next = session.prepare(origin: panel, target: "panel.sound")!
        _ = session.start(next, fileURL: url, volume: 0.7)
        expect(
            !session.playStep(run, target: "next", fileURL: url, volume: 0.2),
            "old gap cannot resume")
        session.endSequence(run)
        expect(session.playing == next, "old completion cannot clear new target")
        let fresh = session.beginSequence(origin: group)!
        _ = session.playStep(fresh, target: "first", fileURL: url, volume: 0.3)
        session.stop(origin: group)
        expect(!session.isCurrent(fresh), "stop invalidates whole sequence")
        let final = session.beginSequence(origin: group)!
        _ = session.playStep(final, target: "final", fileURL: url, volume: 0.8)
        session.endSequence(final)
        expect(session.playing != nil, "scheduler end is not fake audio completion")
        expect(session.activeSequence == final, "final audio retains sequence stop eligibility")
        expect(
            session.beginSequence(origin: group) == nil,
            "batch button stops final audio after scheduler end")
        player.completions.last?(true)
        expect(
            session.playing == nil && session.activeSequence == nil,
            "late final callback cannot restore sequence")
    }
    suite("Manual preview: reopened source and explicit sequence-gap stop") {
        let player = ManualCompletionPlayer()
        let session = ManualAudioPreviewSession(player: player)
        let old = ManualPreviewOrigin(.settings), reopened = ManualPreviewOrigin(.settings)
        let url = URL(fileURLWithPath: "/fixture/reopened.wav")
        let stale = session.prepare(origin: old, target: "same-target")!
        let current = session.prepare(origin: reopened, target: "same-target")!
        _ = session.start(current, fileURL: url, volume: 1)
        session.stop(origin: old)
        expect(
            session.playing == current && !session.isCurrent(stale),
            "old visible lifetime cannot close reopened preview")
        let run = session.beginSequence(origin: reopened)!
        _ = session.playStep(run, target: "gap", fileURL: url, volume: 0.5)
        player.completions.last?(true)
        expect(
            session.beginSequence(origin: reopened) == nil,
            "batch click during gap stops rather than creates a new run")
        expect(
            !session.isCurrent(run) && session.activeSequence == nil,
            "gap cancellation permanently invalidates subsequent steps")
    }
    suite("Manual preview: retained Settings lifecycle preserves non-key playback") {
        let player = ManualCompletionPlayer()
        let preview = ManualAudioPreviewSession(player: player)
        let effects = SoundPacksEditorNativeEffectsDispatcher(
            adapter: ManualPreviewEffectsAdapter(), previewSession: preview)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), nativeEffects: effects)
        let origin = ManualPreviewOrigin(.settings), panel = ManualPreviewOrigin(.panel)
        let url = URL(fileURLWithPath: "/fixture/lifecycle.wav")
        let a = preview.prepare(origin: origin, target: "window")!
        _ = preview.start(a, fileURL: url, volume: 1)
        _ = fixture.session.send(.windowPhaseChanged(.key))
        _ = fixture.session.send(.windowPhaseChanged(.visibleNonKey))
        expect(preview.playing == a, "losing key does not mean leaving the page")
        _ = fixture.session.send(.windowPhaseChanged(.key))
        expect(preview.playing == a, "regaining key does not stop current preview")
        _ = fixture.session.send(.windowPhaseChanged(.hidden))
        expect(preview.playing == nil && player.stops == 1, "explicit hiding stops immediately")
        let b = preview.prepare(origin: panel, target: "panel")!
        _ = preview.start(b, fileURL: url, volume: 0.5)
        _ = fixture.session.send(.route(.destination(.general)))
        expect(
            preview.playing == b, "settings destination exit cannot stop the panel's newer claim")
        _ = fixture.session.send(.route(.destination(.eventsAndSounds)))
        let c = preview.prepare(origin: origin, target: "closed")!
        _ = preview.start(c, fileURL: url, volume: 1)
        _ = fixture.session.send(.windowWillClose)
        expect(preview.playing == nil, "retained native close clears actual playback")
    }
    suite("AI task surface: real phases and detached results") {
        let id = UUID()
        expect(
            AICueTaskPresentation(
                state: .generating(id), hasVisibleResults: false, hasFailure: false,
                isCurrentContext: false
            ).isDetachedTask,
            "reopened composer labels a previous task without acquiring adoption authority")
        expect(
            !AICueTaskPresentation(
                state: .saved(id), hasVisibleResults: false, hasFailure: false,
                isCurrentContext: false
            ).isExpanded, "detached completion does not create current-target candidates")
        expect(
            AICueTaskPresentation(state: .idle, hasVisibleResults: false, hasFailure: true)
                .showsLocalFailure, "local validation failure remains readable in expanded card")
        expect(
            AICueTaskPresentation(
                state: .generating(id), hasVisibleResults: false, hasFailure: false
            ).kind == .generating, "generating is projected")
        expect(
            AICueTaskPresentation(state: .saving(id), hasVisibleResults: false, hasFailure: false)
                .kind == .saving, "saving is not collapsed into generating")
        expect(
            AICueTaskPresentation(state: .saved(id), hasVisibleResults: true, hasFailure: false)
                .kind == .results, "current candidates expand results")
        expect(
            !AICueTaskPresentation(state: .saved(id), hasVisibleResults: false, hasFailure: false)
                .isExpanded, "reopened composer cannot inherit old candidates")
        expect(
            AICueTaskPresentation(
                state: .pending(id, .busy), hasVisibleResults: false, hasFailure: false
            ).kind == .pending, "pending preserves recovery surface")
        expect(
            !AICueTaskPresentation(state: .idle, hasVisibleResults: false, hasFailure: false)
                .isExpanded, "cancel returns ready")
    }
}
