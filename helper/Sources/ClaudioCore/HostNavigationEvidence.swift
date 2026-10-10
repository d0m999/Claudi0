import Darwin
import Foundation

/// Bounded source facts, never executable instructions. Optional evidence cannot invalidate audio
/// or the event. OS identity and host-specific binding are verified again by the GUI.
public struct HostNavigationEvidence: Codable, Sendable, Equatable, Hashable {
    public let process: HostProcessIdentity
    public let terminalProcess: HostProcessIdentity?
    public let tty: String?
    public let itermSessionID: String?
    public let tmux: TmuxNavigationEvidence?
    public let codexThreadID: String?

    public init(
        process: HostProcessIdentity, terminalProcess: HostProcessIdentity? = nil,
        tty: String? = nil, itermSessionID: String? = nil,
        tmux: TmuxNavigationEvidence? = nil, codexThreadID: String? = nil
    ) {
        self.process = process
        self.terminalProcess = terminalProcess
        self.tty = tty
        self.itermSessionID = itermSessionID
        self.tmux = tmux
        self.codexThreadID = codexThreadID
    }

    public var isValid: Bool {
        process.isValid && (terminalProcess?.isValid ?? true) && (tty.map(Self.validTTY) ?? true)
            && (itermSessionID.map { Self.validToken($0, maximum: 128) } ?? true)
            && (tmux?.isValid ?? true)
            && (codexThreadID.map { UUID(uuidString: $0) != nil } ?? true)
    }

    public static func validToken(_ value: String, maximum: Int = 128) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 95, 58, 46].contains($0)
            }
    }

    public static func validTTY(_ value: String) -> Bool {
        value.hasPrefix("/dev/ttys") && value.utf8.count <= 64
            && !value.dropFirst(9).isEmpty
            && value.dropFirst(9).utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func controllingTTY(_ pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
            size == MemoryLayout<kinfo_proc>.size, info.kp_eproc.e_tdev != -1,
            let name = devname(info.kp_eproc.e_tdev, S_IFCHR)
        else { return nil }
        let path = "/dev/" + String(cString: name)
        return validTTY(path) ? path : nil
    }

    public static func capture(
        ancestors: [HostProcessIdentity],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userID: UInt32 = getuid(),
        readProcess: (Int32) -> HostProcessSnapshot? = HostProcessAncestry.read,
        readTTY: (Int32) -> String? = controllingTTY
    )
        -> Self?
    {
        // SSH and container/remote environments are outside the local navigation contract.
        guard environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil,
            let process = ancestors.first
        else { return nil }
        var tmux: TmuxNavigationEvidence?
        if let raw = environment["TMUX"], raw.utf8.count <= 512,
            let pane = environment["TMUX_PANE"]
        {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 3, let pid = Int32(parts[1]),
                let server = readProcess(pid),
                server.userID == userID
            {
                let value = TmuxNavigationEvidence(
                    socketPath: String(parts[0]),
                    server: server.identity, paneID: pane)
                if value.isValid { tmux = value }
            }
        }
        let value = Self(
            process: process, tty: readTTY(process.pid),
            itermSessionID: environment["ITERM_SESSION_ID"], tmux: tmux,
            codexThreadID: environment["CODEX_THREAD_ID"])
        // Invalid optional fields reduce only their individual capability.
        let terminalProcess = value.tty.flatMap { tty in
            ancestors.reversed().first { identity in
                guard let process = readProcess(identity.pid), process.identity == identity,
                    process.kind == .ordinary, process.isOwned(by: userID)
                else { return false }
                return readTTY(identity.pid) == tty
            }
        }
        return Self(
            process: process, terminalProcess: terminalProcess, tty: value.tty,
            itermSessionID: value.itermSessionID.flatMap { validToken($0) ? $0 : nil }, tmux: tmux,
            codexThreadID: value.codexThreadID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil })
    }
}

public struct TmuxNavigationEvidence: Codable, Sendable, Equatable, Hashable {
    public let socketPath: String
    public let server: HostProcessIdentity
    public let paneID: String

    public init(socketPath: String, server: HostProcessIdentity, paneID: String) {
        self.socketPath = socketPath; self.server = server; self.paneID = paneID
    }
    public var isValid: Bool {
        socketPath.hasPrefix("/") && socketPath.utf8.count <= 512
            && !HostEventSource.containsUnsafeScalar(socketPath)
            && server.isValid && paneID.first == "%" && paneID.count > 1 && paneID.count <= 20
            && paneID.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
}
