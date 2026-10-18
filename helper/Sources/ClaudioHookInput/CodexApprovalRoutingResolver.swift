import ClaudioCore
import Darwin
import Foundation

public enum CodexApprovalRoutingResolver {
    private static let chunkBytes = 64 << 10
    private static let maximumRecordBytes = 1 << 20
    private static let maximumScanBytes = 8 << 20

    public static func resolve(
        _ data: Data?, sessionsDirectory: URL = ClaudioPaths.codexSessionsDirectory
    ) -> CodexApprovalRouting {
        guard let data, data.count <= 64 << 10,
            HostEventSourceParser.duplicateTopLevelKeys(data).isEmpty,
            let input = try? JSONDecoder().decode(HookInput.self, from: data),
            input.hookEventName == "PermissionRequest", input.permissionMode == "default",
            UUID(uuidString: input.sessionID) != nil,
            let threadID = UUID(uuidString: input.agentID ?? input.sessionID),
            let turnID = UUID(uuidString: input.turnID),
            input.transcriptPath.hasPrefix("/"), !input.transcriptPath.utf8.contains(0)
        else { return .unavailable }

        let file = URL(fileURLWithPath: input.transcriptPath).standardizedFileURL
        let root = sessionsDirectory.standardizedFileURL
        let prefix = root.path + "/"
        guard file.path.hasPrefix(prefix), file.pathExtension == "jsonl",
            file.lastPathComponent.lowercased().hasSuffix(
                "-\(threadID.uuidString.lowercased()).jsonl")
        else { return .unavailable }

        // Pin every component below the configured sessions root. Never follow a transcript
        // symlink or accept a FIFO/device, and never search other conversations for a match.
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return .unavailable }
        defer { close(parent) }
        let components = file.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return .unavailable }
            close(parent)
            parent = child
        }
        guard let name = components.last else { return .unavailable }
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(), before.st_nlink == 1, before.st_size > 0,
            let head = read(fd, at: 0, count: min(chunkBytes, Int(before.st_size))),
            let newline = head.firstIndex(of: 10),
            let metadata = decode(head[..<newline]),
            case .session(let actualThreadID) = metadata, actualThreadID == threadID
        else { return .unavailable }

        let result = scan(fd, size: before.st_size, threadID: threadID, turnID: turnID)
        var after = stat()
        var entry = stat()
        guard fstat(fd, &after) == 0,
            fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
            entry.st_dev == before.st_dev, entry.st_ino == before.st_ino,
            after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { return .unavailable }
        return result
    }

    private static func scan(_ fd: Int32, size: off_t, threadID: UUID, turnID: UUID)
        -> CodexApprovalRouting
    {
        var cursor = size
        var scanned = 0
        var pending = Data()
        var laterSettings: CodexApprovalRouting?
        while cursor > 0, scanned < maximumScanBytes {
            let count = min(chunkBytes, Int(cursor), maximumScanBytes - scanned)
            cursor -= off_t(count)
            guard var bytes = read(fd, at: cursor, count: count) else { return .unavailable }
            bytes.append(pending)
            var end = bytes.endIndex
            if scanned == 0 {
                // A partially written last record must not expose a stale earlier policy.
                guard bytes.last == 10 else { return .unavailable }
                end -= 1
            }
            scanned += count
            while let separator = bytes[..<end].lastIndex(of: 10) {
                let line = bytes[(separator + 1)..<end]
                guard let record = decode(line) else { return .unavailable }
                switch record {
                case .turn(let actualTurnID, let routing):
                    // The newest turn is authoritative, including inherited/forked rollouts.
                    guard actualTurnID == turnID else { return .unavailable }
                    guard laterSettings == nil || laterSettings == routing else {
                        return .unavailable
                    }
                    return routing
                case .settings(let actualThreadID, let routing):
                    guard actualThreadID == threadID else { return .unavailable }
                    if laterSettings == nil { laterSettings = routing }
                case .session:
                    return .unavailable
                case .other:
                    break
                }
                end = separator
            }
            guard end <= maximumRecordBytes else { return .unavailable }
            pending = Data(bytes[..<end])
        }
        return .unavailable
    }

    private static func read(_ fd: Int32, at offset: off_t, count: Int) -> Data? {
        var bytes = Data(count: count)
        let received = bytes.withUnsafeMutableBytes { buffer in
            var result = pread(fd, buffer.baseAddress, count, offset)
            while result < 0 && errno == EINTR {
                result = pread(fd, buffer.baseAddress, count, offset)
            }
            return result
        }
        return received == count ? bytes : nil
    }

    private static func decode(_ data: Data) -> Record? {
        guard !data.isEmpty, data.count <= maximumRecordBytes else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private struct HookInput: Decodable {
        let hookEventName: String
        let permissionMode: String
        let sessionID: String
        let agentID: String?
        let turnID: String
        let transcriptPath: String

        private enum CodingKeys: String, CodingKey {
            case hookEventName = "hook_event_name"
            case permissionMode = "permission_mode"
            case sessionID = "session_id"
            case agentID = "agent_id"
            case turnID = "turn_id"
            case transcriptPath = "transcript_path"
        }
    }

    /// Decode only host routing metadata. Message text, commands and tool results are ignored.
    private enum Record: Decodable {
        case session(UUID)
        case turn(UUID?, CodexApprovalRouting)
        case settings(UUID?, CodexApprovalRouting)
        case other

        private enum Key: String, CodingKey {
            case type, payload, id
            case turnID = "turn_id"
            case threadID = "thread_id"
            case approvalsReviewer = "approvals_reviewer"
            case threadSettings = "thread_settings"
        }

        init(from decoder: any Decoder) throws {
            let record = try decoder.container(keyedBy: Key.self)
            switch try record.decode(String.self, forKey: .type) {
            case "session_meta":
                let payload = try record.nestedContainer(keyedBy: Key.self, forKey: .payload)
                self = .session(try payload.decode(UUID.self, forKey: .id))
            case "turn_context":
                let payload = try record.nestedContainer(keyedBy: Key.self, forKey: .payload)
                self = .turn(
                    try payload.decodeIfPresent(UUID.self, forKey: .turnID),
                    Self.routing(
                        try payload.decodeIfPresent(String.self, forKey: .approvalsReviewer)))
            case "event_msg":
                let payload = try record.nestedContainer(keyedBy: Key.self, forKey: .payload)
                guard
                    try payload.decodeIfPresent(String.self, forKey: .type)
                        == "thread_settings_applied"
                else { self = .other; return }
                let settings = try payload.nestedContainer(
                    keyedBy: Key.self, forKey: .threadSettings)
                self = .settings(
                    try payload.decodeIfPresent(UUID.self, forKey: .threadID),
                    Self.routing(
                        try settings.decodeIfPresent(String.self, forKey: .approvalsReviewer)))
            default:
                self = .other
            }
        }

        private static func routing(_ reviewer: String?) -> CodexApprovalRouting {
            switch reviewer {
            case "user": .user
            case "auto_review": .automatic
            default: .unavailable
            }
        }
    }
}
