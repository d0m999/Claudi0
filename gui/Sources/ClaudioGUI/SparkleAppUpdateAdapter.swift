import AppKit
import ClaudioGUICore
import Sparkle

/// The executable alone imports Sparkle. This retained adapter never creates a second scheduler.
@MainActor
final class SparkleAppUpdateAdapter: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    let model: AppUpdateModel
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var projectedState: AppUpdateState = .idle

    init(bundle: Bundle) {
        let preview = bundle.object(forInfoDictionaryKey: "ClaudioPublicPreview") as? Bool == true
        model = AppUpdateModel(isPublicPreview: preview)
        super.init()
        guard bundle.bundleURL.pathExtension == "app" else { return }
        let appURL = bundle.bundleURL.resolvingSymlinksInPath()
        let volumes = try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        let roots =
            [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        guard
            appUpdateInstallationAllowsUpdates(
                bundleURL: appURL, applicationsDirectories: roots,
                volumeIsReadOnly: volumes?.volumeIsReadOnly)
        else {
            model.project(
                state: .unavailable(.moveToApplications), canCheck: false, automaticChecks: false)
            return
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            URL(string: feed)?.scheme == "https",
            let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: key)?.count == 32
        else {
            model.project(
                state: .unavailable(.configuration), canCheck: false, automaticChecks: false)
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        model.connect(
            check: { [weak self] in self?.controller?.checkForUpdates(nil) },
            setAutomaticChecks: { [weak self] enabled in
                self?.controller?.updater.automaticallyChecksForUpdates = enabled
            })
    }

    func start() {
        guard let controller else { return }
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] _, _ in MainActor.assumeIsolated { self?.project() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
                [weak self] _, _ in MainActor.assumeIsolated { self?.project() }
            },
        ]
        do { try controller.updater.start() } catch {
            projectedState = .unavailable(.configuration)
        }
        project()
    }

    private func project() {
        guard let updater = controller?.updater else { return }
        model.project(
            state: projectedState, canCheck: updater.canCheckForUpdates,
            automaticChecks: updater.automaticallyChecksForUpdates)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        projectedState = .available(update.displayVersionString)
        project()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        projectedState = .available(item.displayVersionString)
        project()
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        if let error {
            projectedState =
                (error as NSError).domain == SUSparkleErrorDomain
                    && (error as NSError).code == SUError.noUpdateError.rawValue
                ? .upToDate : .failed
        } else if case .available = projectedState {
            // Keep the passive reminder until the user attends to or skips this update.
        } else {
            projectedState = .idle
        }
        project()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        projectedState = .idle
        project()
    }

    func standardUserDriverWillFinishUpdateSession() { project() }
}
