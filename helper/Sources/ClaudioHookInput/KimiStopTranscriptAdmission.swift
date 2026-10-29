import ClaudioCore
import CoreFoundation
import CryptoKit
import Foundation

/// Kimi's Stop payload has no main/subagent identity. Its main agent wire log does: the latest
/// `agent.turn.ended` belongs to the main agent, while a subagent Stop never creates one there.
/// This helper-only reader keeps the host-specific schema out of the GUI's size-sensitive binary.
public enum KimiStopTranscriptAdmission {
    public static let wireProtocolVersion = "1.5"
    private static let maximumWireTailBytes: UInt64 = 131_072

    public static func source(
        nativeEvent: String, data: Data?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stateRoot: URL = ClaudioPaths.integrationsDirectory.appendingPathComponent(
            "kimi-stop-transcript", isDirectory: true)
    ) -> HostEventSource? {
        guard nativeEvent == "Stop", let data, !data.isEmpty,
            data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data).isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["hook_event_name"] as? String == "Stop",
            object["client_type"] as? String == "kimi_code_cli",
            let session = identifier(object["session_id"])
        else { return nil }
        if let active = object["stop_hook_active"], !(active is Bool) { return nil }
        let cwd: String?
        if let raw = object["cwd"] {
            guard let path = raw as? String, WorkspaceDirectory.validPath(path) else {
                return nil
            }
            cwd = path
        } else {
            cwd = nil
        }
        guard
            let root = AdditionalHostPaths.configurationRoot(
                host: .kimiCode, environment: environment, homeDirectory: homeDirectory),
            let turn = latestMainTurnEnd(
                sessionID: session, kimiHome: root),
            turn.outcome == "done",
            shouldNotify(
                sessionID: session, sessionCreatedAt: turn.sessionCreatedAt,
                turnID: turn.turnID, stateRoot: stateRoot)
        else { return nil }
        let label = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let candidate = HostEventSource(
            projectLabel: label?.isEmpty == false ? label : nil,
            sessionID: session, mainSessionIsKnown: true)
        return candidate.isSemanticallyValid ? candidate : nil
    }

    private struct MainTurnEnd {
        let sessionCreatedAt: Int64
        let turnID: Int64
        let outcome: String
    }

    private static func latestMainTurnEnd(sessionID: String, kimiHome: URL) -> MainTurnEnd? {
        let sessions = kimiHome.appendingPathComponent("sessions", isDirectory: true)
        guard
            let workspaces = try? FileManager.default.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        for workspace in workspaces where isDirectoryWithoutSymlink(workspace) {
            let session = workspace.appendingPathComponent(sessionID, isDirectory: true)
            guard isDirectoryWithoutSymlink(session) else { continue }
            let wire = session.appendingPathComponent("agents/main/wire.jsonl")
            if let result = readWireTail(wire) { return result }
        }
        return nil
    }

    private static func readWireTail(_ wire: URL) -> MainTurnEnd? {
        guard
            let values = try? wire.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let handle = try? FileHandle(forReadingFrom: wire)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 4096),
            let headerText = String(data: header, encoding: .utf8),
            let metadataLine = headerText.split(separator: "\n").first,
            let metadata = object(Data(metadataLine.utf8)),
            metadata["type"] as? String == "metadata",
            metadata["protocol_version"] as? String == wireProtocolVersion,
            let createdAt = integer(metadata["created_at"]), createdAt > 0
        else { return nil }
        let offset = size > maximumWireTailBytes ? size - maximumWireTailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let tail = try? handle.readToEnd() else { return nil }
        var text = String(decoding: tail, as: UTF8.self)
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }
        var latest: (turnID: Int64, outcome: String)?
        for line in text.split(separator: "\n") {
            guard let record = object(Data(line.utf8)),
                record["type"] as? String == "agent.turn.ended",
                let turnID = integer(record["turnId"]), turnID >= 0,
                let outcome = record["outcome"] as? String
            else { continue }
            latest = (turnID, outcome)
        }
        guard let latest else { return nil }
        return MainTurnEnd(
            sessionCreatedAt: createdAt, turnID: latest.turnID, outcome: latest.outcome)
    }

    private static func shouldNotify(
        sessionID: String, sessionCreatedAt: Int64, turnID: Int64, stateRoot: URL
    ) -> Bool {
        guard (try? ensurePrivateDirectoryExists(at: stateRoot)) != nil else { return false }
        let key = SHA256.hash(data: Data(sessionID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let marker = stateRoot.appendingPathComponent("\(key).json")
        let lock = FileLock(path: stateRoot.appendingPathComponent("\(key).lock").path)
        guard case .acquired = lock.attemptLock() else { return false }
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: marker) {
            guard let previous = object(data),
                integer(previous["session_created_at"]) == sessionCreatedAt,
                let previousTurn = integer(previous["turn_id"]),
                previousTurn < turnID
            else { return false }
        }
        let document: [String: Any] = [
            "session_created_at": sessionCreatedAt,
            "turn_id": turnID,
            "protocol_version": wireProtocolVersion,
        ]
        guard
            let encoded = try? JSONSerialization.data(
                withJSONObject: document, options: [.sortedKeys])
        else { return false }
        do {
            try encoded.write(to: marker, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: marker.path)
        } catch {
            return false
        }
        return true
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
            !containsUnsafeScalar(value), !value.contains(where: \.isWhitespace)
        else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue >= 0,
            number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.int64Value
    }

    private static func containsUnsafeScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let number = scalar.value
            return number <= 0x1F || number == 0x7F || (0x80...0x9F).contains(number)
                || [
                    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                    0x2066, 0x2067, 0x2068, 0x2069,
                ].contains(Int(number))
        }
    }
}
