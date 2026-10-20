import CoreServices
import Foundation

public enum HostDiscoveryState: Codable, Sendable, Equatable {
    case notInstalled
    case installed
    case blocked(reason: String)

    public var availability: HostAvailability {
        switch self {
        case .installed: .available
        case .notInstalled: .notInstalled
        case .blocked(let reason): .unavailable(reason: reason)
        }
    }
}

/// One live CLI observation, shared only within the inspection that requested it.
/// Discovery and activation scope have different validation rules: neither implies the other.
public struct HostDiscoveryObservation: Sendable, Equatable {
    public let availability: HostAvailability
    public let scopeFingerprint: String?

    public init(availability: HostAvailability, scopeFingerprint: String?) {
        self.availability = availability
        self.scopeFingerprint = scopeFingerprint
    }
}

public enum HostDiscovery {
    public static func workBuddyApplicationURL() -> URL? {
        let registered =
            LSCopyApplicationURLsForBundleIdentifier("com.tencent.workbuddy.mac" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        let candidates =
            [
                URL(fileURLWithPath: "/Applications/WorkBuddy.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Applications/WorkBuddy.app"),
            ]
            + registered
        return candidates.first {
            Bundle(url: $0)?.bundleIdentifier == "com.tencent.workbuddy.mac"
        }
    }

    public static func detect(
        _ host: HostID, locator: HostExecutableLocator = .standard(),
        runner: (any CommandRunning)? = nil,
        workBuddyURL: URL? = nil
    ) -> HostDiscoveryState {
        if host == .workBuddy {
            guard let workBuddyURL = workBuddyURL ?? workBuddyApplicationURL() else {
                return .notInstalled
            }
            guard FileManager.default.fileExists(atPath: workBuddyURL.path) else {
                return .notInstalled
            }
            guard let bundle = Bundle(url: workBuddyURL),
                bundle.bundleIdentifier == "com.tencent.workbuddy.mac",
                let executable = bundle.executableURL,
                FileManager.default.isExecutableFile(atPath: executable.path),
                let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String,
                SemanticVersion(parsing: version) != nil
            else { return .blocked(reason: "无法验证 WorkBuddy 应用身份") }
            return .installed
        }
        switch observeCLI(host, locator: locator, runner: runner).availability {
        case .available: return .installed
        case .notInstalled: return .notInstalled
        case .unavailable(let reason): return .blocked(reason: reason)
        }
    }

    /// Captures one forced, uncached version probe. Call again for each new inspection;
    /// a failed probe is not retried here. Only Claude Code and Codex participate;
    /// other hosts return `.notInstalled` without probing.
    public static func observeCLI(
        _ host: HostID, locator: HostExecutableLocator = .standard(),
        runner: (any CommandRunning)? = nil
    ) -> HostDiscoveryObservation {
        let command: String
        switch host {
        case .claudeCode: command = "claude"
        case .codex: command = "codex"
        default: return .init(availability: .notInstalled, scopeFingerprint: nil)
        }
        guard locator.executablePath(command: command) != nil else {
            return .init(availability: .notInstalled, scopeFingerprint: nil)
        }
        let blockedReason = "无法验证来源版本；请检查安装"
        guard
            let version = HostActivationScope.discoveredVersion(
                for: host,
                executableLocator: locator, commandRunner: runner)
        else {
            return .init(
                availability: .unavailable(reason: blockedReason), scopeFingerprint: nil)
        }
        // Preserve the existing protocol compatibility policy; the historical verified Claude
        // lower bound is diagnostic evidence, not a newly invented hard version requirement.
        let hasVersion = version.split(whereSeparator: \.isWhitespace).contains {
            SemanticVersion(parsing: String($0)) != nil && $0.contains(".")
        }
        return .init(
            availability: hasVersion ? .available : .unavailable(reason: blockedReason),
            scopeFingerprint: HostActivationScope.fingerprint(for: host, discoveredVersion: version)
        )
    }
}
