import Foundation

/// Monotonic sample from the model, not a second timer. Rendering never changes a deadline.
public struct EventNoticeReadingTime: Sendable, Equatable {
    public let sampledUptime: TimeInterval
    public let remaining: TimeInterval
    public let isPaused: Bool
    public let budget: TimeInterval

    public init(
        sampledUptime: TimeInterval, remaining: TimeInterval, isPaused: Bool, budget: TimeInterval
    ) {
        self.sampledUptime = sampledUptime
        self.remaining = remaining
        self.isPaused = isPaused
        self.budget = budget
    }

    public func fraction(at uptime: TimeInterval) -> Double {
        guard budget > 0, uptime.isFinite else { return 0 }
        let elapsed = isPaused ? 0 : max(0, uptime - sampledUptime)
        return min(1, max(0, (remaining - elapsed) / budget))
    }
}
