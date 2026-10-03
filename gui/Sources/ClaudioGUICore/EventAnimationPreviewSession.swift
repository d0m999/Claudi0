import ClaudioCore
import Combine
import Foundation

/// Independent visual demonstration owned by SettingsPresentationSession. It has no notice,
/// sound, host, or navigation side effects.
@MainActor
public final class EventAnimationPreviewSession: ObservableObject {
    @Published public private(set) var event: Event = .notification
    @Published public private(set) var isActive = false
    @Published public private(set) var reading: EventNoticeReadingTime
    public private(set) var replayRevision: UInt64 = 0
    private let uptime: @MainActor () -> TimeInterval
    private let finishDelay: @Sendable () async throws -> Void
    private var finish: Task<Void, Never>?

    public convenience init(
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(uptime: uptime, finishDelay: { try await Task.sleep(nanoseconds: 4_000_000_000) })
    }

    package init(
        uptime: @escaping @MainActor () -> TimeInterval,
        finishDelay: @escaping @Sendable () async throws -> Void
    ) {
        self.uptime = uptime
        self.finishDelay = finishDelay
        reading = EventNoticeReadingTime(
            sampledUptime: uptime(), remaining: 4, isPaused: true, budget: 4)
    }

    public var presentationUptime: TimeInterval { uptime() }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        replay()
    }

    public func select(_ event: Event) {
        self.event = event
        replay()
    }

    public func replay() {
        guard isActive else { return }
        finish?.cancel()
        replayRevision &+= 1
        reading = EventNoticeReadingTime(
            sampledUptime: uptime(), remaining: 4, isPaused: false, budget: 4)
        let revision = replayRevision
        let delay = finishDelay
        finish = Task { @MainActor [weak self] in
            do { try await delay() } catch { return }
            guard !Task.isCancelled, let self, self.isActive, self.replayRevision == revision
            else { return }
            self.reading = EventNoticeReadingTime(
                sampledUptime: self.uptime(), remaining: 0, isPaused: true, budget: 4)
            self.finish = nil
        }
    }

    public func deactivate() {
        finish?.cancel()
        finish = nil
        let remaining = reading.fraction(at: uptime()) * reading.budget
        reading = EventNoticeReadingTime(
            sampledUptime: uptime(), remaining: remaining, isPaused: true, budget: 4)
        isActive = false
    }
}
