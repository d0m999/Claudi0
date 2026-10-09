import Combine
import Foundation

public enum AppUpdateUnavailableReason: Equatable, Sendable {
    case developmentBuild
    case moveToApplications
    case configuration
}

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(String)
    case upToDate
    case failed
    case unavailable(AppUpdateUnavailableReason)
}

/// One app-lifetime projection. Sparkle owns scheduling, preferences, downloads and installation.
@MainActor
public final class AppUpdateModel: ObservableObject {
    @Published public private(set) var state: AppUpdateState
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false
    public let isPublicPreview: Bool
    private var check: (@MainActor () -> Void)?
    private var setAutomaticChecks: (@MainActor (Bool) -> Void)?

    public init(
        state: AppUpdateState = .unavailable(.developmentBuild), isPublicPreview: Bool = false
    ) {
        self.state = state
        self.isPublicPreview = isPublicPreview
    }

    package func connect(
        check: @escaping @MainActor () -> Void,
        setAutomaticChecks: @escaping @MainActor (Bool) -> Void
    ) {
        self.check = check
        self.setAutomaticChecks = setAutomaticChecks
    }

    package func project(
        state: AppUpdateState, canCheck: Bool, automaticChecks: Bool
    ) {
        self.state = state
        if case .unavailable = state {
            canCheckForUpdates = false
        } else {
            canCheckForUpdates = canCheck
        }
        automaticallyChecksForUpdates = automaticChecks
    }

    public func checkForUpdates() {
        guard canCheckForUpdates, state != .checking, let check else { return }
        if case .unavailable = state { return }
        canCheckForUpdates = false
        state = .checking
        check()
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let setAutomaticChecks else { return }
        if case .unavailable = state { return }
        setAutomaticChecks(enabled)
    }
}

/// Only an installed app on a writable volume may start a session. Sparkle owns permission prompts.
package func appUpdateInstallationAllowsUpdates(
    bundleURL: URL, applicationsDirectories: [URL], volumeIsReadOnly: Bool?
) -> Bool {
    let path = bundleURL.standardizedFileURL.path
    guard bundleURL.pathExtension == "app", volumeIsReadOnly == false,
        !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/")
    else { return false }
    return applicationsDirectories.contains {
        let root = $0.standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }
}
