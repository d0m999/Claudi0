import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import Foundation

/// App-lifetime composition owner for the model, bounded ingress, and GUI-owned receiver.
/// Health is reported as fixed redacted codes only; a failed receiver never fabricates
/// delivery state and never disturbs the existing audio/receipt path.
@MainActor
final class EventNoticeRuntime {
    let model: EventNoticeModel
    let health: EventNoticeHealthStore
    let navigationAdapter = HostSessionNavigationAdapter()
    private var navigationIngressTasks: [UUID: Task<Void, Never>] = [:]
    private var receiver: EventNoticeReceiver?
    private var ingress: EventNoticeIngress!
    private let receiptStore: HostHookReceiptStore
    #if DEBUG
    private let developmentTarget = CodexRolloutObservationTarget.developmentEnvironment(
        ProcessInfo.processInfo.environment)
    private var developmentObserver: CodexQuestionObservationSession?
    #endif

    init() {
        let model = EventNoticeModel(
            receiverEpoch: UUID(), resolveSourceApplication: SourceApplicationAdapter.resolve)
        self.model = model
        health = EventNoticeHealthStore()
        receiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory)
        ingress = EventNoticeIngress { [weak self] notices in
            self?.acceptNotices(notices) ?? notices.count
        }
        startReceiver()
    }

    private func acceptNotices(_ notices: [HostEventNotice]) -> Int {
        guard navigationIngressTasks.count < 4 else { return model.acceptBatch(notices).count }
        let id = UUID(), epoch = model.receiverEpoch
        let preparationDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        navigationIngressTasks[id] = Task { @MainActor [weak self] in
            for notice in notices {
                guard !Task.isCancelled, let self, self.model.receiverEpoch == epoch,
                    self.model.canReceive
                else { break }
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
                _ = self.model.accept(prepared)
            }
            self?.navigationIngressTasks.removeValue(forKey: id)
        }
        return notices.count
    }

    func startReceiver() {
        guard receiver == nil, model.canReceive else { return }
        #if DEBUG
        if developmentObserver == nil, let target = developmentTarget {
            let observer = CodexQuestionObservationSession(target: target) {
                [weak model] observation in
                model?.acceptDevelopmentObservation(observation) ?? .ignoredDisabled
            }
            model.setDevelopmentObservationRun(observer.runID)
            developmentObserver = observer
            observer.start()
        }
        #endif
        do {
            let receiptStore = self.receiptStore
            let receiver = try EventNoticeReceiver(
                epoch: model.receiverEpoch,
                currentInstallationID: { host in
                    receiptStore.currentInstallationID(host: host)
                }
            ) { [weak ingress] notice in
                ingress?.enqueue(notice)
            }
            navigationAdapter.ide.start()
            receiver.start()
            self.receiver = receiver
            health.reportReady()
        } catch let error as EventNoticeReceiverError {
            // Best effort: no receiver means hooks retain their original playback/receipt/exit
            // contract and the GUI remains usable without fabricating delivery health.
            health.reportUnavailable(code: error.diagnosticCode)
        } catch {
            // Unknown failure kinds get the honest unknown code, never a guessed one.
            health.reportUnavailable(code: "unknown")
        }
    }

    func stopReceiver() {
        for task in navigationIngressTasks.values { task.cancel() }
        navigationIngressTasks.removeAll()
        navigationAdapter.ide.stop()
        #if DEBUG
        developmentObserver?.stop()
        developmentObserver = nil
        model.setDevelopmentObservationRun(nil)
        #endif
        receiver?.stop()
        receiver = nil
        ingress.clear()
    }

    func setEnabled(_ enabled: Bool) {
        guard model.isEnabled != enabled else { return }
        stopReceiver()
        model.setEnabled(enabled)
        if enabled {
            startReceiver()
        } else {
            health.reportDisabled()
        }
    }

    /// Sleep and screen lock share one privacy boundary: hide immediately, clear source memory,
    /// and invalidate the epoch so a locked screen never replays private notices on return.
    func suspendForSystemPrivacy(_ reason: EventNoticePrivacyReason) {
        stopReceiver()
        model.setSystemPrivacy(reason, active: true)
        health.reportDisabled()
    }

    func resumeAfterSystemPrivacy(_ reason: EventNoticePrivacyReason) {
        model.setSystemPrivacy(reason, active: false)
        startReceiver()
    }

    func stopForTermination() {
        stopReceiver()
        model.clearForPrivacy()
    }
}
