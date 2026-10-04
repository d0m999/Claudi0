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
    private let navigationIngress: EventNoticeNavigationIngress
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
        navigationIngress = EventNoticeNavigationIngress(model: model)
        health = EventNoticeHealthStore()
        receiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory)
        ingress = EventNoticeIngress { [weak self] notices in
            self?.navigationIngress.acceptNotices(notices) ?? notices.count
        }
        startReceiver()
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
        navigationIngress.clear()
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
