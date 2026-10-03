import ClaudioCore
import Foundation

/// The source manifest is decoded without translating or duplicating its timing arrays.
public struct EventAnimationManifest: Decodable, Sendable {
    public let frameWidth: Int
    public let frameHeight: Int
    public let columns: Int
    public let rows: Int
    public let animations: [String: EventAnimationTimeline]

    public func validate() throws {
        guard frameWidth == 64, frameHeight == 64, columns == 16, rows == 7,
            Set(animations.keys) == Set(["idle", "preview"] + Event.allCases.map(\.manifestKey)),
            Set(animations.values.map(\.row)) == Set(0..<rows)
        else { throw EventAnimationResourceFailure.invalidManifest }
        for animation in animations.values { try animation.validate() }
    }
}

public enum EventAnimationResourceFailure: String, Error, Sendable, Equatable {
    case unavailable, invalidManifest, checksumMismatch, invalidAtlas
}

public struct EventAnimationFrame: Sendable, Equatable {
    public let index: Int
    /// nil means a held/static frame: the view must stop scheduling.
    public let nextBoundaryMs: Double?
}

public struct EventAnimationTimeline: Decodable, Sendable {
    public let row: Int
    public let frames: Int
    public let durationsMs: [Int]
    public let reducedMotionFrame: Int
    public let playback: String
    public let loopStartFrame: Int?
    public let loopEndFrame: Int?

    public var durationMs: Int { durationsMs.reduce(0, +) }

    public func validate() throws {
        guard (0..<7).contains(row), frames == 16, durationsMs.count == frames,
            durationsMs.allSatisfy({ (1..<65_536).contains($0) }),
            (0..<frames).contains(reducedMotionFrame), ["once", "loop"].contains(playback)
        else { throw EventAnimationResourceFailure.invalidManifest }
        if playback == "loop" {
            guard let start = loopStartFrame, let end = loopEndFrame,
                (0..<frames).contains(start), start <= end, end == frames - 1
            else { throw EventAnimationResourceFailure.invalidManifest }
        } else if loopStartFrame != nil || loopEndFrame != nil {
            throw EventAnimationResourceFailure.invalidManifest
        }
    }

    /// Matches HTML frameAtElapsed with manualLoop=false, including the partial-loop intro.
    public func frame(at elapsedMs: Double, staticExpression: Bool = false) -> EventAnimationFrame {
        if staticExpression {
            return EventAnimationFrame(index: reducedMotionFrame, nextBoundaryMs: nil)
        }
        guard elapsedMs.isFinite else {
            return EventAnimationFrame(index: reducedMotionFrame, nextBoundaryMs: nil)
        }
        let elapsed = max(0, elapsedMs)
        let total = Double(durationMs)
        if playback != "loop", elapsed >= total {
            return EventAnimationFrame(index: frames - 1, nextBoundaryMs: nil)
        }
        var position = elapsed
        if playback == "loop", elapsed >= total {
            let prefix = Double(durationsMs.prefix(loopStartFrame ?? 0).reduce(0, +))
            let period = total - prefix
            position = prefix + (elapsed - total).truncatingRemainder(dividingBy: period)
        }
        var boundary = 0.0
        for (index, duration) in durationsMs.enumerated() {
            boundary += Double(duration)
            if position < boundary {
                return EventAnimationFrame(
                    index: index, nextBoundaryMs: elapsed + boundary - position)
            }
        }
        return EventAnimationFrame(index: frames - 1, nextBoundaryMs: nil)
    }

    public static func action(for event: Event, kind: EventNoticeKind) -> String {
        if event == .notification, kind != .permission, kind != .needsInput { return "idle" }
        return event.manifestKey
    }
}

extension EventNoticeReadingTime {
    public func animationElapsedMs(at uptime: TimeInterval) -> Double {
        (1 - fraction(at: uptime)) * max(0, budget) * 1_000
    }
}
