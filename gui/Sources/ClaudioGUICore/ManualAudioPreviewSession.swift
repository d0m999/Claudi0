import Combine
import Foundation

/// The sole manual-playback owner. It consumes already-resolved safe audio, never configuration.
@MainActor
public final class ManualAudioPreviewSession: ObservableObject {
    @Published public private(set) var request: ManualPreviewRequest?
    @Published public private(set) var playing: ManualPreviewRequest?
    @Published public private(set) var sequence: ManualPreviewRun?
    @Published public private(set) var failedOrigin: ManualPreviewOrigin?
    private let player: any AudioPreviewPlaying
    private var hasAudio = false

    public init(player: any AudioPreviewPlaying) { self.player = player }

    /// A finished scheduler may still own the final audio until its real completion.
    public var activeSequence: ManualPreviewRun? { sequence ?? playing?.run }

    public func isPlaying(_ target: String, origin: ManualPreviewOrigin) -> Bool {
        playing?.origin == origin && playing?.target == target
    }

    /// Acquiring intent invalidates even an asynchronous preparation or a sequence's gap.
    public func prepare(origin: ManualPreviewOrigin, target: String) -> ManualPreviewRequest? {
        let stopping = request?.origin == origin && request?.target == target
        invalidate()
        guard !stopping else { return nil }
        let next = ManualPreviewRequest(origin: origin, target: target)
        request = next
        return next
    }

    public func isCurrent(_ token: ManualPreviewRequest) -> Bool { request == token }
    public func isCurrent(_ run: ManualPreviewRun) -> Bool { sequence == run }

    @discardableResult
    public func start(_ token: ManualPreviewRequest, fileURL: URL, volume: Double) -> Bool {
        guard isCurrent(token), !hasAudio else { return false }
        hasAudio = true
        let started = player.play(fileAt: fileURL, volume: Float(volume)) { [weak self] success in
            guard let self, self.request == token else { return }
            self.hasAudio = false
            self.playing = nil
            self.request = nil
            if !success {
                self.failedOrigin = token.origin
                self.sequence = nil
            }
        }
        guard request == token else { return started }  // synchronous completion is legal
        if started {
            playing = token
        } else {
            hasAudio = false
            playing = nil
            request = nil
            sequence = nil
            failedOrigin = token.origin
        }
        return started
    }

    public func fail(_ token: ManualPreviewRequest) {
        guard isCurrent(token) else { return }
        invalidate()
        failedOrigin = token.origin
    }

    public func stop(origin: ManualPreviewOrigin) {
        guard request?.origin == origin || sequence?.origin == origin || failedOrigin == origin
        else { return }
        invalidate()
    }

    public func stop(category: ManualPreviewOrigin.Category) {
        if request?.origin.category == category || sequence?.origin.category == category
            || failedOrigin?.category == category
        {
            invalidate()
        }
    }

    public func beginSequence(origin: ManualPreviewOrigin) -> ManualPreviewRun? {
        let stopping = activeSequence?.origin == origin
        invalidate()
        guard !stopping else { return nil }
        let run = ManualPreviewRun(origin: origin)
        sequence = run
        return run
    }

    @discardableResult
    public func playStep(
        _ run: ManualPreviewRun, target: String, fileURL: URL, volume: Double
    ) -> Bool {
        guard isCurrent(run) else { return false }
        stopAudio()
        let token = ManualPreviewRequest(origin: run.origin, target: target, run: run)
        request = token
        return start(token, fileURL: fileURL, volume: volume)
    }

    public func endSequence(_ run: ManualPreviewRun) {
        guard isCurrent(run) else { return }
        sequence = nil  // A scheduling timer must not pretend that audio has finished.
    }

    private func stopAudio() {
        request = nil
        playing = nil
        guard hasAudio else { return }
        hasAudio = false
        player.stop()
    }

    private func invalidate() {
        stopAudio()
        sequence = nil
        failedOrigin = nil
    }
}
