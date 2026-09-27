import CryptoKit
import Darwin
import Foundation

public enum HostQuestionConsumption: Sendable, Equatable {
    case consumed
    case duplicate
    case unavailable
}

/// A bounded, private ledger of consumed question identities. Only SHA256 digests and timestamps
/// are persisted. Consumption precedes all sound and notice attempts, including muted outcomes.
/// The reservation lock is released before playback; it never shares the lifecycle playback lock.
public struct HostQuestionDeduplicationStore: Sendable {
    public static let maximumEntries = 256
    public static let retention: TimeInterval = 30 * 60
    public let stateFile: URL
    public let lockFile: URL

    public init(directory: URL, lockFile: URL) {
        stateFile = directory.appendingPathComponent("consumed.json")
        self.lockFile = lockFile
    }

    public func consume(
        host: HostID,
        installationID: UUID,
        payload: HostQuestionHookPayload,
        now: Date,
        isCurrent: @Sendable () -> Bool
    ) -> HostQuestionConsumption {
        guard now.timeIntervalSince1970.isFinite else { return .unavailable }
        let result = withNonBlockingLock(path: lockFile.path) { () -> HostQuestionConsumption in
            let installationKey = Self.digest([host.rawValue, installationID.uuidString])
            guard isCurrent(), var entries = readEntries(installationKey: installationKey) else {
                return .unavailable
            }
            let timestamp = now.timeIntervalSince1970
            entries = entries.filter {
                timestamp - $0.value < Self.retention
            }
            let key = Self.key(host: host, installationID: installationID, payload: payload)
            if entries[key] != nil { return .duplicate }
            // Retain existing identities when full; evicting a live request would allow its
            // duplicate callback to replay. Expired records are removed on the next valid call.
            guard entries.count < Self.maximumEntries, isCurrent() else { return .unavailable }
            entries[key] = timestamp
            let ledger = Ledger(schema: 1, installationKey: installationKey, entries: entries)
            guard let data = try? JSONEncoder().encode(ledger) else {
                return .unavailable
            }
            do {
                try writePrivateAtomic(data, to: stateFile)
                return .consumed
            } catch {
                return .unavailable
            }
        }
        switch result {
        case .ran(let outcome): return outcome
        case .skipped, .failed: return .unavailable
        }
    }

    private struct Ledger: Codable {
        let schema: Int
        let installationKey: String
        let entries: [String: TimeInterval]
    }

    private func readEntries(installationKey: String) -> [String: TimeInterval]? {
        var status = stat()
        let inspected = stateFile.withUnsafeFileSystemRepresentation { pointer -> (Bool, Int32) in
            guard let pointer else { return (false, EINVAL) }
            let exists = Darwin.lstat(pointer, &status) == 0
            return (exists, errno)
        }
        if !inspected.0 { return inspected.1 == ENOENT ? [:] : nil }
        guard
            case .success(let data) = readRegularFileBounded(
                at: stateFile, maxBytes: 32 * 1024, followSymlink: false),
            let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
            ledger.schema == 1, Self.isDigest(ledger.installationKey),
            ledger.entries.count <= Self.maximumEntries,
            ledger.entries.allSatisfy({ key, timestamp in
                Self.isDigest(key) && timestamp.isFinite
            })
        else { return nil }
        // Authorization above has established the active installation. Its new namespace must
        // not inherit a full quota from a disconnected generation.
        return ledger.installationKey == installationKey ? ledger.entries : [:]
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func key(
        host: HostID, installationID: UUID, payload: HostQuestionHookPayload
    ) -> String {
        // Length prefixes avoid aliases between adjacent identity fields. UTF-8 bytes, rather
        // than Swift canonical string equality, distinguish the host's opaque identifiers.
        digest([host.rawValue, installationID.uuidString, payload.sessionID, payload.requestID])
    }

    private static func digest(_ values: [String]) -> String {
        var bytes = Data()
        for value in values {
            let encoded = Data(value.utf8)
            var count = UInt64(encoded.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(encoded)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
