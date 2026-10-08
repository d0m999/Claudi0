import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

/// Retains the active `NSSound`; a local value would deallocate immediately and cut playback off.
@MainActor
public final class NSSoundAudioPreviewPlayer: NSObject, AudioPreviewPlaying, NSSoundDelegate {
    private var currentSound: NSSound?

    private var completion: (@MainActor @Sendable (Bool) -> Void)?

    public override init() { super.init() }

    @discardableResult
    public func play(fileAt url: URL, volume: Float) -> Bool {
        playWithDuration(fileAt: url, volume: volume) != nil
    }

    @discardableResult
    public func playWithDuration(fileAt url: URL, volume: Float) -> TimeInterval? {
        stop()
        // A fresh instance per play prevents a cached named sound's late delegate callback from
        // being mistaken for the current playback, including immediate replay of the same file.
        let sound = NSSound(contentsOf: url, byReference: true)
        guard let sound else { return nil }
        sound.volume = volume
        currentSound = sound
        sound.delegate = self
        guard sound.play() else {
            currentSound = nil
            return nil
        }
        return sound.duration
    }

    public func play(
        fileAt url: URL, volume: Float,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        guard playWithDuration(fileAt: url, volume: volume) != nil else { return false }
        completion = onCompletion
        return true
    }

    public func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard sound === currentSound else { return }
        let callback = completion
        completion = nil
        currentSound = nil
        callback?(flag)
    }

    public func stop() {
        completion = nil
        currentSound?.delegate = nil
        currentSound?.stop()
        currentSound = nil
    }
}
