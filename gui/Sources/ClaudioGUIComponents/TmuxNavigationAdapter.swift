import ClaudioCore
import ClaudioGUICore
import Darwin
import Foundation

public struct TmuxClientIdentity: Sendable, Equatable {
    public let process: HostProcessIdentity
    public let tty: String
    public let sessionID: String
    public var pid: Int32 { process.pid }
}

public enum TmuxNavigationAdapter {
    private static var executable: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    private static func live(_ evidence: TmuxNavigationEvidence) -> Bool {
        var status = stat()
        return evidence.isValid
            && HostProcessAncestry.read(evidence.server.pid)?.identity == evidence.server
            && HostProcessAncestry.read(evidence.server.pid)?.userID == getuid()
            && lstat(evidence.socketPath, &status) == 0 && status.st_uid == getuid()
            && status.st_mode & S_IFMT == S_IFSOCK
            && connectedServerMatches(evidence)
    }
    /// Socket ownership and a live old PID do not prove which server owns the connection.
    private static func connectedServerMatches(_ evidence: TmuxNavigationEvidence) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        // A full/backlogged socket must fail closed instead of blocking the GUI actor.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_un()
        let bytes = evidence.socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard connected == 0,
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
            pid == evidence.server.pid,
            let peer = HostProcessAncestry.read(pid), peer.userID == getuid()
        else { return false }
        return peer.identity == evidence.server
    }

    private static func query(
        _ evidence: TmuxNavigationEvidence, _ arguments: [String],
        deadline: TimeInterval
    ) async -> String? {
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
            live(evidence), let executable,
            arguments.allSatisfy({ !$0.contains("'") })
        else { return nil }
        // tmux evaluates this condition in the same server that executes the fixed command.
        // It closes the socket-replacement gap between the peer check and Process.run.
        let command = arguments.map { "'" + $0 + "'" }.joined(separator: " ")
        let mismatch = "claudio-server-mismatch"
        guard
            let result = await NavigationCommand.run(
                executable,
                [
                    "-S", evidence.socketPath, "if-shell", "-F",
                    "#{==:#{pid},\(evidence.server.pid)}", command,
                    "display-message -p '" + mismatch + "'",
                ],
                deadline: deadline), result != mismatch, live(evidence)
        else { return nil }
        return result
    }
    public static func client(_ evidence: TmuxNavigationEvidence, deadline: TimeInterval)
        async -> TmuxClientIdentity?
    {
        guard
            let text = await query(
                evidence,
                ["list-clients", "-F", "#{client_pid}|#{client_tty}|#{session_id}"],
                deadline: deadline)
        else { return nil }
        guard live(evidence) else { return nil }
        return parseClient(text)
    }
    public static func parseClient(
        _ text: String,
        process: (Int32) -> HostProcessSnapshot? = HostProcessAncestry.read,
        userID: UInt32 = getuid()
    ) -> TmuxClientIdentity? {
        let rows = text.split(separator: "\n")
        guard rows.count == 1 else { return nil }  // Never choose the first of multiple clients.
        let values = rows[0].split(separator: "|", omittingEmptySubsequences: false)
        guard values.count == 3, let pid = Int32(values[0]),
            let snapshot = process(pid), snapshot.userID == userID,
            snapshot.identity.pid == pid, snapshot.identity.isValid,
            HostNavigationEvidence.validTTY(String(values[1])),
            stableID(String(values[2]), prefix: "$")
        else { return nil }
        return TmuxClientIdentity(
            process: snapshot.identity, tty: String(values[1]), sessionID: String(values[2]))
    }
    private static func stableID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && value.count > 1 && value.count <= 20
            && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
    public static func pane(_ evidence: TmuxNavigationEvidence, deadline: TimeInterval) async
        -> [String]?
    {
        guard
            let text = await query(
                evidence,
                [
                    "display-message", "-p", "-t", evidence.paneID,
                    "#{session_id}|#{window_id}|#{pane_id}|#{pane_tty}",
                ],
                deadline: deadline)
        else { return nil }
        return parsePane(text, paneID: evidence.paneID)
    }
    public static func parsePane(_ text: String, paneID: String) -> [String]? {
        let values = text.components(separatedBy: "|")
        guard values.count == 4, stableID(values[0], prefix: "$"), stableID(values[1], prefix: "@"),
            values[2] == paneID, HostNavigationEvidence.validTTY(values[3])
        else { return nil }
        return values
    }
    @MainActor
    public static func select(
        _ evidence: TmuxNavigationEvidence, client expected: TmuxClientIdentity,
        deadline: TimeInterval, current: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard current(), let values = await pane(evidence, deadline: deadline), current() else {
            return false
        }
        let commands = [
            ["switch-client", "-c", expected.tty, "-t", values[0]],
            ["select-window", "-t", values[1]], ["select-pane", "-t", evidence.paneID],
        ]
        for command in commands {
            guard current(), let actual = await client(evidence, deadline: deadline),
                actual.process == expected.process, actual.tty == expected.tty, current(),
                await query(evidence, command, deadline: deadline) != nil, current()
            else { return false }
        }
        return true
    }
    public static func confirm(
        _ evidence: TmuxNavigationEvidence, client expected: TmuxClientIdentity,
        deadline: TimeInterval
    ) async -> Bool {
        guard let actual = await client(evidence, deadline: deadline),
            actual.process == expected.process, actual.tty == expected.tty,
            let value = await query(
                evidence,
                [
                    "display-message", "-p", "-t", actual.sessionID,
                    "#{pane_id}",
                ], deadline: deadline)
        else { return false }
        return value == evidence.paneID
    }
}
