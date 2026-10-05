import CoreFoundation
import Foundation

public struct HostIntegrationIntent: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let revision: UUID

    public init(enabled: Bool, revision: UUID = UUID()) {
        self.enabled = enabled
        self.revision = revision
    }
}

public enum HostIntegrationIntentError: Error, Sendable, Equatable {
    case damaged
    case transaction(ConfigFileTransactionError)
}

/// The shared config is the only durable intent owner. Absence is pending migration, never ON.
public struct HostIntegrationIntentStore: Sendable {
    public let configFile: URL
    public let lockFile: URL
    public let authorizationLockFile: URL

    public init(
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile,
        authorizationLockFile: URL? = nil
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.authorizationLockFile =
            authorizationLockFile
            ?? configFile.deletingLastPathComponent().appendingPathComponent(
                "host-authorization.lock")
    }

    public func read() -> Result<[HostSurfaceID: HostIntegrationIntent], HostIntegrationIntentError>
    {
        guard
            case .success(let bytes) = readRegularFileBounded(
                at: configFile, maxBytes: 1 << 20, followSymlink: false),
            let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        else { return .failure(.damaged) }
        return Self.decode(root)
    }

    public func intent(for surface: HostSurfaceID) -> HostIntegrationIntent? {
        try? read().get()[surface]
    }

    /// Fills only absent formal surfaces. Explicit OFF and future surface entries survive upgrades.
    public func migrate(installedSurfaces: Set<HostSurfaceID>)
        -> Result<[HostSurfaceID: HostIntegrationIntent], HostIntegrationIntentError>
    {
        mutate { root, intents in
            var section = root["host_integrations"] as? [String: Any] ?? [:]
            var entries = section["surfaces"] as? [String: Any] ?? [:]
            for surface in installedSurfaces where intents[surface] == nil {
                entries[surface.rawValue] = ["enabled": true, "revision": UUID().uuidString]
            }
            section["policy_version"] = 1
            section["surfaces"] = entries
            var next = root
            next["host_integrations"] = section
            return next
        }
    }

    public func setEnabled(surface: HostSurfaceID, enabled: Bool)
        -> Result<HostIntegrationIntent, HostIntegrationIntentError>
    {
        mutate { root, intents in
            guard intents[surface]?.enabled != enabled else { return root }
            var section = root["host_integrations"] as? [String: Any] ?? [:]
            var entries = section["surfaces"] as? [String: Any] ?? [:]
            var entry = entries[surface.rawValue] as? [String: Any] ?? [:]
            entry["enabled"] = enabled
            entry["revision"] = UUID().uuidString
            entries[surface.rawValue] = entry
            section["policy_version"] = 1
            section["surfaces"] = entries
            var next = root
            next["host_integrations"] = section
            return next
        }.flatMap { intents in
            intents[surface].map(Result.success) ?? .failure(.damaged)
        }
    }

    private func mutate(
        _ change: ([String: Any], [HostSurfaceID: HostIntegrationIntent]) -> [String: Any]
    ) -> Result<[HostSurfaceID: HostIntegrationIntent], HostIntegrationIntentError> {
        let boundary = HostPublicationContext.unconditional(lockFile: authorizationLockFile)
        defer { boundary.release() }
        return HostPublicationContext.$current.withValue(boundary) {
            let transaction = ConfigFileTransaction(
                file: configFile, lockFile: lockFile,
                backupFile: configFile.appendingPathExtension("host-integrations.bak"),
                symlinkPolicy: .reject)
            var invalid = false
            let result:
                Result<
                    ConfigFileTransactionReport<[HostSurfaceID: HostIntegrationIntent]>,
                    ConfigFileTransactionError
                > = transaction.update { root in
                    guard case .success(let intents) = Self.decode(root) else {
                        invalid = true
                        return .unchanged([HostSurfaceID: HostIntegrationIntent]())
                    }
                    let next = change(root, intents)
                    guard case .success(let projected) = Self.decode(next) else {
                        invalid = true
                        return .unchanged(intents)
                    }
                    return NSDictionary(dictionary: root).isEqual(to: next)
                        ? .unchanged(projected) : .replace(next, projected)
                }
            if invalid { return .failure(.damaged) }
            return result.map(\.value).mapError(HostIntegrationIntentError.transaction)
        }
    }

    private static func decode(_ root: [String: Any])
        -> Result<[HostSurfaceID: HostIntegrationIntent], HostIntegrationIntentError>
    {
        guard let value = root["host_integrations"] else { return .success([:]) }
        guard let section = value as? [String: Any],
            let version = section["policy_version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
            version.doubleValue == 1,
            let entries = section["surfaces"] as? [String: Any]
        else { return .failure(.damaged) }
        var result: [HostSurfaceID: HostIntegrationIntent] = [:]
        for (key, value) in entries {
            // Future surfaces remain opaque. Known surfaces must be valid, even when disabled.
            guard HostID(rawValue: key) != nil, let surface = HostSurfaceID(rawValue: key) else {
                continue
            }
            guard let entry = value as? [String: Any],
                let enabled = entry["enabled"] as? NSNumber,
                CFGetTypeID(enabled) == CFBooleanGetTypeID(),
                let revision = entry["revision"] as? String,
                let id = UUID(uuidString: revision)
            else { return .failure(.damaged) }
            result[surface] = HostIntegrationIntent(enabled: enabled.boolValue, revision: id)
        }
        return .success(result)
    }
}
