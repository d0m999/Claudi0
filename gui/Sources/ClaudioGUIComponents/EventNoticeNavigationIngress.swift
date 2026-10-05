import ClaudioCore
import ClaudioGUICore
import Foundation

/// Bounded navigation preparation owned by EventNoticeRuntime; the model remains the sole reducer.
@MainActor
package final class EventNoticeNavigationIngress {
    private let model: EventNoticeModel
    private var tasks: [UUID: Task<Void, Never>] = [:]
    package var pendingBatchCount: Int { tasks.count }
    package init(model: EventNoticeModel) { self.model = model }

    package func acceptNotices(_ notices: [HostEventNotice]) -> Int {
        guard tasks.count < 4 else { return model.acceptBatch(notices).count }
        let id = UUID(), epoch = model.receiverEpoch
        let preparationDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        tasks[id] = Task { @MainActor [weak self] in
            var preparedNotices: [HostEventNotice] = []
            for notice in notices.prefix(32) {
                guard !Task.isCancelled, let self, self.model.receiverEpoch == epoch,
                    self.model.canReceive
                else { break }
                guard self.model.isNoticeAuthorized(notice) else { continue }
                var prepared = notice
                if let evidence = notice.navigationEvidence, let tmux = evidence.tmux,
                    let pane = await TmuxNavigationAdapter.pane(
                        tmux,
                        deadline: preparationDeadline),
                    pane.last == evidence.tty,
                    let client = await TmuxNavigationAdapter.client(
                        tmux,
                        deadline: preparationDeadline)
                {
                    let ancestors = HostProcessAncestry.capture(startingAt: client.pid)
                    prepared = notice.replacingNavigationEvidence(
                        HostNavigationEvidence(
                            process: client.process, tty: client.tty, tmux: tmux),
                        ancestors: ancestors)
                }
                guard !Task.isCancelled, self.model.receiverEpoch == epoch, self.model.canReceive
                else { break }
                guard self.model.isNoticeAuthorized(prepared) else { continue }
                preparedNotices.append(prepared)
            }
            while !preparedNotices.isEmpty {
                guard !Task.isCancelled, let self, self.model.receiverEpoch == epoch,
                    self.model.canReceive
                else { break }
                let consumed = self.model.acceptBatch(preparedNotices).count
                preparedNotices.removeFirst(consumed)
                if !preparedNotices.isEmpty { await Task.yield() }
            }
            self?.tasks.removeValue(forKey: id)
        }
        return min(notices.count, 32)
    }

    package func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
