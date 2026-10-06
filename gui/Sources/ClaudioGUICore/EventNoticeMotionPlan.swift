import Foundation

/// Presentation and reading use the same monotonic schedule. A nil start holds the first frame
/// until the next presentation commit; repainting never creates another entrance.
public struct EventNoticeMotionPlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case entrance, relocation, exit, queueRow }

    public static let entranceDuration: TimeInterval = 0.18
    public static let spineDuration: TimeInterval = 0.26
    public static let relocationDuration: TimeInterval = 0.26
    public static let entranceStep: TimeInterval = 0.09
    public static let relocationStep: TimeInterval = 0.045
    public static let queueStep: TimeInterval = 0.055

    public let kind: Kind
    public let startedAt: TimeInterval?
    public let delay: TimeInterval
    public let fromY: Double
    public let fromOpacity: Double

    public init(
        kind: Kind, startedAt: TimeInterval?, index: Int = 0, fromY: Double = 0,
        fromOpacity: Double = 1
    ) {
        self.kind = kind
        self.startedAt = startedAt
        switch kind {
        case .entrance: delay = Double(max(0, index)) * Self.entranceStep
        case .relocation: delay = Double(max(1, index)) * Self.relocationStep
        case .exit: delay = 0
        case .queueRow: delay = Double(max(0, index)) * Self.queueStep
        }
        self.fromY = fromY
        self.fromOpacity = fromOpacity
    }

    public var duration: TimeInterval {
        kind == .relocation ? Self.relocationDuration : Self.entranceDuration
    }
    public var completesAt: TimeInterval? { startedAt.map { $0 + delay + duration } }

    public func progress(at uptime: TimeInterval, reducedMotion: Bool, spine: Bool = false)
        -> Double
    {
        if reducedMotion { return 1 }
        guard let startedAt else { return 0 }
        let duration = spine ? Self.spineDuration : duration
        return min(1, max(0, (uptime - startedAt - delay) / duration))
    }

    public func offsetY(at uptime: TimeInterval, reducedMotion: Bool) -> Double {
        guard !reducedMotion else { return 0 }
        let progress = eased(progress(at: uptime, reducedMotion: false))
        switch kind {
        case .entrance: return -8 * (1 - progress)
        case .relocation: return fromY * (1 - progress)
        case .exit: return fromY - 6 * progress
        case .queueRow: return -5 * (1 - progress)
        }
    }

    public func opacity(at uptime: TimeInterval, reducedMotion: Bool) -> Double {
        guard !reducedMotion else { return 1 }
        let progress = progress(at: uptime, reducedMotion: false)
        switch kind {
        case .entrance, .queueRow: return progress
        case .exit: return fromOpacity * (1 - progress)
        case .relocation: return 1
        }
    }

    public func spineScale(at uptime: TimeInterval, reducedMotion: Bool) -> Double {
        0.3 + 0.7 * eased(progress(at: uptime, reducedMotion: reducedMotion, spine: true))
    }

    private func eased(_ progress: Double) -> Double { 1 - pow(1 - progress, 3) }
}
