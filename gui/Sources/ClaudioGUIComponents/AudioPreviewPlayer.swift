import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

/// Retains the active `NSSound`; a local value would deallocate immediately and cut playback off.
@MainActor
public final class NSSoundAudioPreviewPlayer: AudioPreviewPlaying {
    private var currentSound: NSSound?

    public init() {}

    @discardableResult
    public func play(fileAt url: URL, volume: Float) -> Bool {
        playWithDuration(fileAt: url, volume: volume) != nil
    }

    @discardableResult
    public func playWithDuration(fileAt url: URL, volume: Float) -> TimeInterval? {
        currentSound?.stop()
        currentSound = nil
        let sound: NSSound?
        if url.deletingLastPathComponent().standardizedFileURL
            == SystemSoundCatalog.systemDirectory.standardizedFileURL
        {
            sound = NSSound(named: NSSound.Name(url.deletingPathExtension().lastPathComponent))
        } else {
            sound = NSSound(contentsOf: url, byReference: true)
        }
        guard let sound else { return nil }
        sound.volume = volume
        currentSound = sound
        guard sound.play() else {
            currentSound = nil
            return nil
        }
        return sound.duration
    }

    public func stop() {
        currentSound?.stop()
        currentSound = nil
    }
}
