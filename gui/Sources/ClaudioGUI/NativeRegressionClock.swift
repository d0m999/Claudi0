#if DEBUG && CLAUDIO_UI_REGRESSION
import ClaudioGUICore
import Foundation

/// Advancing this clock affects only the fixture model and navigation timeout.
final class NativeRegressionClock: @unchecked Sendable {
    private struct Item {
        let id: UUID
        let deadline: TimeInterval
        let callback: @MainActor () -> Void
    }
    private let lock = NSLock()
    private var items: [Item] = []
    @MainActor var time = ProcessInfo.processInfo.systemUptime

    @MainActor func scheduler() -> EventNoticeScheduler {
        EventNoticeScheduler { [weak self] delay, callback in
            guard let self else { return EventNoticeCancellation {} }
            let item = Item(id: UUID(), deadline: self.time + delay, callback: callback)
            self.lock.lock(); self.items.append(item); self.lock.unlock()
            return EventNoticeCancellation { [weak self] in self?.remove(item.id) }
        }
    }
    @MainActor func advance(_ seconds: TimeInterval) {
        let target = time + seconds
        while let item = take(until: target) { time = item.deadline; item.callback() }
        time = target
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
