import ClaudioPTYC
import Darwin
import Foundation

/// Explicit, opt-in PTY launcher. Existing running shells are never attached or read.
public enum ZedPTYSession {
    public enum SessionError: Error {
        case needsTerminal, unsupportedFocusReports, spawnFailed, ioFailed
    }

    public static func run(command: [String], descriptor: URL) throws -> Int32 {
        guard !command.isEmpty, isatty(0) == 1, isatty(1) == 1,
            let executable = executable(command[0]), let outerName = ttyname(0)
        else { throw SessionError.needsTerminal }
        let outerTTY = String(cString: outerName)
        guard HostNavigationEvidence.validTTY(outerTTY), sameTTY(1, outerTTY), sameTTY(2, outerTTY),
            HostNavigationEvidence.controllingTTY(getpid()) == outerTTY,
            tcgetpgrp(0) == getpgrp()
        else { throw SessionError.needsTerminal }
        var saved = termios(), size = winsize()
        guard tcgetattr(0, &saved) == 0, ioctl(0, TIOCGWINSZ, &size) == 0,
            claudio_pty_install_handlers() == 0
        else { throw SessionError.ioFailed }
        defer { claudio_pty_restore_handlers() }
        let inputFlags = fcntl(0, F_GETFL), outputFlags = fcntl(1, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0 else { throw SessionError.ioFailed }
        var raw = saved
        cfmakeraw(&raw)
        guard tcsetattr(0, TCSANOW, &raw) == 0 else { throw SessionError.ioFailed }
        var originalFocus: Bool?
        defer {
            if let originalFocus {
                writeSmall(1, Data("\u{1B}[?1004\(originalFocus ? "h" : "l")".utf8))
            }
            _ = tcsetattr(0, TCSANOW, &saved)
            _ = fcntl(0, F_SETFL, inputFlags); _ = fcntl(1, F_SETFL, outputFlags)
        }
        _ = fcntl(0, F_SETFL, inputFlags | O_NONBLOCK)
        _ = fcntl(1, F_SETFL, outputFlags | O_NONBLOCK)
        let mode = try queryFocusMode()
        originalFocus = mode.enabled
        writeSmall(1, Data("\u{1B}[?1004h".utf8))
        var master: Int32 = -1
        let arguments = command.map { strdup($0) }
        defer { for argument in arguments { free(argument) } }
        let child = (arguments + [nil]).withUnsafeBufferPointer { argv in
            executable.withCString {
                claudio_pty_spawn($0, argv.baseAddress, &saved, &size, &master)
            }
        }
        guard child > 0 else { throw SessionError.spawnFailed }
        defer { Darwin.close(master) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var childFinished = false
        defer {
            if !childFinished {
                let foreground = tcgetpgrp(master)
                if foreground > 1 && foreground != child {
                    _ = kill(-foreground, SIGTERM); _ = kill(-foreground, SIGCONT)
                }
                _ = kill(-child, SIGTERM); _ = kill(-child, SIGCONT)
                let until = uptime() + 0.25
                var ignored: Int32 = 0
                while uptime() < until {
                    if claudio_pty_wait(child, &ignored) == 1 { break }
                    _ = usleep(5000)
                }
                if claudio_pty_wait(child, &ignored) != -1 {
                    if foreground > 1 && foreground != child { _ = kill(-foreground, SIGKILL) }
                    _ = kill(-child, SIGKILL)
                    _ = waitpid(child, nil, 0)
                }
            }
        }
        let instance = UUID()
        var session: ZedPTYSessionIdentity?
        var channel: ZedPTYControlChannel?
        var nextConnect: TimeInterval = 0
        var sequence: UInt64 = 0, focused: Bool?
        var observedUptime: TimeInterval = 0
        var inputFilter = ZedPTYInputFilter(), outputFilter = ZedPTYOutputFilter()
        let initialInput = inputFilter.consume(mode.pending, forwardFocus: false)
        var toChild = initialInput.bytes, toOuter = Data()
        var inputPendingAt: TimeInterval?, outputPendingAt: TimeInterval?
        var exitedAt: TimeInterval?, exitCode: Int32 = 0, masterEOF = false

        func state(request: UUID? = nil) {
            guard let channel else { return }
            var frame = ZedPTYFrame(type: .state, epoch: channel.epoch, instance: instance)
            frame.request = request; frame.sequence = sequence
            frame.focused = focused; frame.observedUptime = observedUptime
            if request != nil {
                frame.caughtUp =
                    claudio_pty_input_caught_up(0) == 1
                    && !inputFilter.hasPending && toChild.count < 262144
            }
            channel.send(frame)
        }
        func suspend() throws {
            _ = tcsetattr(0, TCSANOW, &saved)
            writeSmall(1, Data("\u{1B}[?1004\(mode.enabled ? "h" : "l")".utf8))
            guard fcntl(0, F_SETFL, inputFlags) == 0,
                fcntl(1, F_SETFL, outputFlags) == 0
            else { throw SessionError.ioFailed }
            // The shell shares these open file descriptions. Leave them restored while
            // stopped, and a background continuation must not reclaim or read its TTY.
            repeat {
                guard kill(getpid(), SIGSTOP) == 0, tcgetpgrp(0) > 0 else {
                    throw SessionError.ioFailed
                }
            } while tcgetpgrp(0) != getpgrp()
            guard tcsetattr(0, TCSANOW, &raw) == 0,
                fcntl(0, F_SETFL, inputFlags | O_NONBLOCK) == 0,
                fcntl(1, F_SETFL, outputFlags | O_NONBLOCK) == 0
            else { throw SessionError.ioFailed }
            writeSmall(1, Data("\u{1B}[?1004h".utf8))
            _ = kill(-child, SIGCONT)
        }

        while true {
            while case let signal = claudio_pty_take_signal(), signal != 0 {
                if signal == SIGWINCH || signal == SIGCONT {
                    if ioctl(0, TIOCGWINSZ, &size) == 0 { _ = ioctl(master, TIOCSWINSZ, &size) }
                    if signal == SIGCONT { _ = kill(-child, SIGCONT) }
                } else if signal == SIGTSTP {
                    _ = kill(-child, SIGTSTP)
                } else {
                    _ = kill(-child, signal)
                }
            }
            if !childFinished {
                let status = claudio_pty_wait(child, &exitCode)
                if status == 1 {
                    childFinished = true; exitedAt = uptime()
                } else if status == 2 {
                    try suspend()
                } else if status < 0 {
                    throw SessionError.ioFailed
                }
            }
            if childFinished && toOuter.isEmpty && (masterEOF || uptime() - (exitedAt ?? 0) > 0.25)
            {
                return exitCode
            }
            if channel?.isAlive == false { channel = nil }
            if channel == nil, !childFinished, uptime() >= nextConnect {
                nextConnect = uptime() + 0.5
                if session == nil, let process = HostProcessAncestry.read(getpid()),
                    let childProcess = HostProcessAncestry.read(child),
                    childProcess.parentPID == getpid(),
                    let innerTTY = HostNavigationEvidence.controllingTTY(child),
                    innerTTY != outerTTY
                {
                    session = ZedPTYSessionIdentity(
                        instance: instance, process: process.identity,
                        child: childProcess.identity, outerTTY: outerTTY, innerTTY: innerTTY)
                }
                if let session, session.isValid,
                    let connected = ZedPTYControlChannel.connect(descriptor: descriptor)
                {
                    channel = connected
                    var frame = ZedPTYFrame(
                        type: .register, epoch: connected.epoch, instance: instance)
                    frame.session = session; connected.send(frame); state()
                }
            }
            channel?.flush()
            if let since = inputPendingAt, uptime() - since >= 0.025 {
                let pending = inputFilter.flushPending()
                toChild.append(pending); inputPendingAt = nil
                if !pending.isEmpty, let channel {
                    channel.send(
                        ZedPTYFrame(type: .input, epoch: channel.epoch, instance: instance))
                }
            }
            if let since = outputPendingAt, uptime() - since >= 0.025 {
                toOuter.append(outputFilter.flushPending()); outputPendingAt = nil
            }
            var descriptors = [
                pollfd(
                    fd: 0, events: toChild.count < 262144 && !childFinished ? Int16(POLLIN) : 0,
                    revents: 0),
                pollfd(
                    fd: master,
                    events: (toOuter.count < 262144 && !masterEOF ? Int16(POLLIN) : 0)
                        | (!toChild.isEmpty && !childFinished ? Int16(POLLOUT) : 0), revents: 0),
                pollfd(fd: 1, events: !toOuter.isEmpty ? Int16(POLLOUT) : 0, revents: 0),
                pollfd(fd: channel?.fd ?? -1, events: Int16(POLLIN), revents: 0),
            ]
            let count = poll(&descriptors, nfds_t(descriptors.count), 20)
            if count < 0 { if errno == EINTR { continue }; throw SessionError.ioFailed }
            if descriptors[0].revents & Int16(POLLERR | POLLNVAL) != 0
                || descriptors[2].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0
            {
                throw SessionError.ioFailed
            }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let bytes = try readAvailable(0)
                guard let bytes else { throw SessionError.ioFailed }
                let filtered = inputFilter.consume(
                    bytes, forwardFocus: outputFilter.childWantsFocus)
                inputPendingAt = inputFilter.hasPending ? uptime() : nil
                toChild.append(filtered.bytes)
                for focus in filtered.focus {
                    sequence += 1; focused = focus; observedUptime = uptime(); state()
                }
                if filtered.hasInput, let channel {
                    channel.send(
                        ZedPTYFrame(type: .input, epoch: channel.epoch, instance: instance))
                }
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP) != 0 && !masterEOF {
                if let bytes = try readAvailable(master, acceptEIO: true) {
                    let filtered = outputFilter.consume(bytes)
                    outputPendingAt = outputFilter.hasPending ? uptime() : nil
                    toOuter.append(filtered.bytes); toChild.append(filtered.reply)
                } else {
                    masterEOF = true; toOuter.append(outputFilter.finish())
                }
            }
            if descriptors[1].revents & Int16(POLLOUT) != 0 { try drain(&toChild, fd: master) }
            if descriptors[2].revents & Int16(POLLOUT) != 0 { try drain(&toOuter, fd: 1) }
            if descriptors[3].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                for frame in channel?.receive() ?? [] where frame.instance == instance {
                    if frame.type == .snapshot, let request = frame.request {
                        state(request: request)
                    }
                }
            }
        }
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func sameTTY(_ fd: Int32, _ tty: String) -> Bool {
        guard let name = ttyname(fd) else { return false }
        return String(cString: name) == tty
    }
    private static func executable(_ value: String) -> String? {
        if value.contains("/") {
            return FileManager.default.isExecutableFile(atPath: value) ? value : nil
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(
            separator: ":")
        {
            let path = String(directory) + "/" + value
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    private static func writeSmall(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
    }
    private static func drain(_ data: inout Data, fd: Int32) throws {
        guard !data.isEmpty else { return }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        if count > 0 {
            data.removeFirst(count)
        } else if count < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) {
            throw SessionError.ioFailed
        }
    }
    private static func readAvailable(_ fd: Int32, acceptEIO: Bool = false) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count == 0 || (acceptEIO && errno == EIO) { return nil }
        if [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return Data() }
        throw SessionError.ioFailed
    }
    private static func queryFocusMode() throws -> (enabled: Bool, pending: Data) {
        writeSmall(1, Data("\u{1B}[?1004$p".utf8))
        var pending = Data()
        let deadline = uptime() + 0.25
        while uptime() < deadline {
            var descriptor = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 10) < 0 && errno != EINTR { throw SessionError.ioFailed }
            if descriptor.revents & Int16(POLLIN) != 0, let data = try readAvailable(0) {
                pending.append(data)
                for (value, enabled) in [(1, true), (2, false), (3, true)] {
                    let reply = Data("\u{1B}[?1004;\(value)$y".utf8)
                    if let range = pending.range(of: reply) {
                        pending.removeSubrange(range); return (enabled, pending)
                    }
                }
                if pending.count > 8192 { break }
            }
        }
        throw SessionError.unsupportedFocusReports
    }
}
