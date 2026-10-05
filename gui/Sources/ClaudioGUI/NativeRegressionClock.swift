#if DEBUG && CLAUDIO_UI_REGRESSION
import ClaudioGUICore
import Foundation

/// The default manual clock keeps fixed fixture scenarios deterministic. Live fixtures use the
/// production scheduler and monotonic clock directly, without advancing a second timer.
final class NativeRegressionClock: @unchecked Sendable {
    private struct Item {
        let id: UUID
        let deadline: TimeInterval
        let callback: @MainActor () -> Void
    }
    private let lock = NSLock()
    private var items: [Item] = []
    let isLive: Bool
    @MainActor private var manualTime = ProcessInfo.processInfo.systemUptime

    init(live: Bool = false) { isLive = live }

    @MainActor var time: TimeInterval {
        isLive ? ProcessInfo.processInfo.systemUptime : manualTime
    }

    @MainActor func scheduler() -> EventNoticeScheduler {
        if isLive { return .live }
        return EventNoticeScheduler { [weak self] delay, callback in
            guard let self else { return EventNoticeCancellation {} }
            let item = Item(id: UUID(), deadline: self.time + delay, callback: callback)
            self.lock.lock(); self.items.append(item); self.lock.unlock()
            return EventNoticeCancellation { [weak self] in self?.remove(item.id) }
        }
    }
    @MainActor func advance(_ seconds: TimeInterval) {
        guard !isLive else { return }
        let target = manualTime + seconds
        while let item = take(until: target) { manualTime = item.deadline; item.callback() }
        manualTime = target
    }
    private func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == id }
    }
    private func take(until deadline: TimeInterval) -> Item? {
        lock.lock(); defer { lock.unlock() }
        guard
            let item = items.filter({ $0.deadline <= deadline }).min(by: {
                $0.deadline < $1.deadline
            })
        else { return nil }
        items.removeAll { $0.id == item.id }
        return item
    }
}
#endif
