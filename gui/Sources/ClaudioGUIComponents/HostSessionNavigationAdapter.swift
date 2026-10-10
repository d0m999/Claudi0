import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
public final class HostSessionNavigationAdapter {
    public let ide = IDENavigationBridge()
    public let zed: ZedPTYNavigationBridge
    public init(zedPrototypeEnabled: Bool = false) {
        zed = ZedPTYNavigationBridge(enabled: zedPrototypeEnabled)
    }

    public func navigate(
        _ target: SessionNavigationTarget, application: SourceApplicationTarget,
        isCurrent: @escaping @MainActor () -> Bool, deadline: TimeInterval,
        complete: @escaping @MainActor (SessionNavigationActionResult) -> Void
    )
        -> EventNoticeCancellation
    {
        let focus = NavigationFocusGuard(targetPID: application.process.pid)
        let task = Task { @MainActor in
            defer { focus.stop() }
            let current: @MainActor () -> Bool = {
                isCurrent() && focus.isValid && !Task.isCancelled
                    && ProcessInfo.processInfo.systemUptime < deadline && Self.live(application)
                    && (target.terminalProcess.map {
                        HostProcessAncestry.read($0.pid)?.identity == $0
                    } ?? true)
            }
            let handoff: @MainActor () -> Void = {
                guard current() else { return }
                focus.beginHandoff(); complete(.focusHandoffStarted)
            }
            guard isCurrent(), !Task.isCancelled else { return }
            if !focus.isValid { complete(.cancelled); return }
            guard current(), let route = target.route else { complete(.unavailable); return }
            let outcome: SessionNavigationActionResult
            switch route {
            case .terminal(let tty):
                guard let terminalProcess = target.terminalProcess,
                    HostProcessAncestry.read(terminalProcess.pid)?.identity == terminalProcess,
                    HostNavigationEvidence.controllingTTY(terminalProcess.pid) == tty
                else {
                    complete(.unavailable); return
                }
                outcome = await Self.terminal(
                    tty: tty, app: application, current: current, deadline: deadline,
                    handoff: handoff)
            case .iterm(let session, let tty):
                outcome = await Self.iterm(
                    session: session, tty: tty, app: application,
                    current: current, deadline: deadline, handoff: handoff)
            case .tmux(let evidence):
                outcome = await tmux(
                    evidence, app: application, current: current, deadline: deadline,
                    handoff: handoff)
            case .ide(let shells):
                handoff()
                outcome = await ide.navigate(
                    shells: shells, application: application,
                    isCurrent: current, deadline: deadline)
            case .zedManaged(let session):
                handoff()
                outcome = await zed.navigate(
                    session, application: application, isCurrent: current, deadline: deadline)
            case .codex(let thread):
                guard current(), UUID(uuidString: thread) != nil,
                    application.bundleIdentifier == "com.openai.codex",
                    let url = URL(string: "codex://threads/" + thread)
                else { complete(.unavailable); return }
                handoff()
                if await Self.openURL(url, app: application, current: current), current(),
                    NSRunningApplication(processIdentifier: application.process.pid)?.activate(
                        options: []) == true
                {
                    outcome = .requestSent
                } else {
                    outcome = .failed
                }
            }

            guard isCurrent(), !Task.isCancelled else { return }
            if !focus.isValid { complete(.cancelled); return }
            guard current() else { complete(.unavailable); return }
            complete(outcome)
        }
        focus.cancelOnInvalidation(task, complete: complete)
        return EventNoticeCancellation { task.cancel() }
    }

    public static func live(_ target: SourceApplicationTarget) -> Bool {
        guard let process = HostProcessAncestry.read(target.process.pid),
            process.identity == target.process, process.userID == getuid(),
            let app = NSRunningApplication(processIdentifier: target.process.pid), !app.isTerminated
        else { return false }
        return app.bundleIdentifier == target.bundleIdentifier
            && app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target.applicationURL
    }

    private static func script(_ source: String, deadline: TimeInterval) async -> String? {
        await NavigationCommand.run("/usr/bin/osascript", ["-e", source], deadline: deadline)
    }

    private static func openURL(
        _ url: URL, app: SourceApplicationTarget,
        current: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard current() else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let state = NavigationURLContinuation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation), current(), !Task.isCancelled else {
                    state.finish(false); return
                }
                NSWorkspace.shared.open(
                    [url], withApplicationAt: app.applicationURL,
                    configuration: configuration
                ) { _, error in state.finish(error == nil) }
            }
        } onCancel: {
            state.finish(false)
        }
    }

    private static func terminal(
        tty: String, app: SourceApplicationTarget,
        current: @escaping @MainActor () -> Bool, deadline: TimeInterval,
        handoff: @escaping @MainActor () -> Void
    )
        async -> SessionNavigationActionResult
    {
        guard current(), app.bundleIdentifier == "com.apple.Terminal",
            HostNavigationEvidence.validTTY(tty)
        else { return .unavailable }
        // First query is read-only: permission approval can return late without moving focus.
        let query = """
            tell application id "com.apple.Terminal"
                set matches to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then set end of matches to id of w
                    end repeat
                end repeat
                if (count matches) is 1 then return item 1 of matches
                return ""
            end tell
            """
        guard let window = await script(query, deadline: deadline), Int(window) != nil, current()
        else { return .unavailable }
        let select = """
            tell application id "com.apple.Terminal"
                set w to window id \(window)
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set miniaturized of w to false
                        set index of w to 1
                        return "selected"
                    end if
                end repeat
                return ""
            end tell
            """
        handoff()
        guard current(), await script(select, deadline: deadline) == "selected", current(),
            NSRunningApplication(processIdentifier: app.process.pid)?.activate(
                options: []) == true, current()
        else { return .failed }
        let readback = """
            tell application id "com.apple.Terminal"
                if id of front window is \(window) then return tty of selected tab of front window
                return ""
            end tell
            """
        guard await script(readback, deadline: deadline) == tty, current(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.process.pid
        else { return .failed }
        return .exactReturnConfirmed
    }

    private static func iterm(
        session: String, tty: String, app: SourceApplicationTarget,
        current: @escaping @MainActor () -> Bool, deadline: TimeInterval,
        handoff: @escaping @MainActor () -> Void
    )
        async -> SessionNavigationActionResult
    {
        guard current(), app.bundleIdentifier == "com.googlecode.iterm2",
            HostNavigationEvidence.validToken(session), HostNavigationEvidence.validTTY(tty)
        else { return .unavailable }
        let guid = String(session.split(separator: ":").last ?? "")
        let query = """
            tell application id "com.googlecode.iterm2"
                set matches to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique ID of s is "\(guid)" and tty of s is "\(tty)" then set end of matches to id of w
                        end repeat
                    end repeat
                end repeat
                if (count matches) is 1 then return item 1 of matches
                return ""
            end tell
            """
        guard let window = await script(query, deadline: deadline), Int(window) != nil, current()
        else { return .unavailable }
        var components = URLComponents()
        components.scheme = "iterm2"; components.path = "reveal"
        components.queryItems = [URLQueryItem(name: "sessionid", value: session)]
        handoff()
        guard let url = components.url, current(), await openURL(url, app: app, current: current),
            current()
        else { return .failed }
        guard
            await script(
                "tell application id \"com.googlecode.iterm2\" to set miniaturized of window id \(window) to false",
                deadline: deadline) != nil,
            current(),
            NSRunningApplication(processIdentifier: app.process.pid)?.activate(
                options: []) == true
        else { return .failed }
        let readback = """
            tell application id "com.googlecode.iterm2"
                if id of current window is \(window) then
                    set s to current session of current window
                    return (unique ID of s) & "|" & (tty of s)
                end if
                return ""
            end tell
            """
        guard current(), await script(readback, deadline: deadline) == guid + "|" + tty,
            current(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.process.pid
        else { return .failed }
        return .exactReturnConfirmed
    }

    private func tmux(
        _ evidence: TmuxNavigationEvidence, app: SourceApplicationTarget,
        current: @escaping @MainActor () -> Bool, deadline: TimeInterval,
        handoff: @escaping @MainActor () -> Void
    )
        async -> SessionNavigationActionResult
    {
        guard current(),
            let client = await TmuxNavigationAdapter.client(evidence, deadline: deadline),
            current(), let tty = HostNavigationEvidence.controllingTTY(client.pid),
            tty == client.tty
        else { return .unavailable }
        // Rebind the current sole client to this exact outer application instance.
        let ancestors = HostProcessAncestry.capture(startingAt: client.pid)
        guard let source = SourceApplicationAdapter.resolve(ancestors, action: app.action),
            source.process == app.process,
            await TmuxNavigationAdapter.select(
                evidence, client: client, deadline: deadline,
                current: current), current()
        else { return .unavailable }
        let outcome: SessionNavigationActionResult
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            outcome = await Self.terminal(
                tty: tty, app: app, current: current, deadline: deadline, handoff: handoff)
        case "com.googlecode.iterm2":
            // Client TTY uniquely binds a live session; obtain its stable identity without titles.
            let query = """
                tell application id "com.googlecode.iterm2"
                    set matches to {}
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then set end of matches to unique ID of s
                            end repeat
                        end repeat
                    end repeat
                    if (count matches) is 1 then return item 1 of matches
                    return ""
                end tell
                """
            guard current(), let session = await Self.script(query, deadline: deadline), current()
            else { return .failed }
            outcome = await Self.iterm(
                session: session, tty: tty, app: app, current: current, deadline: deadline,
                handoff: handoff)
        case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92":
            handoff()
            outcome = await ide.navigate(
                shells: ancestors, application: app, isCurrent: current, deadline: deadline)
        default: return .unavailable
        }
        guard outcome == .exactReturnConfirmed, current(),
            await TmuxNavigationAdapter.confirm(evidence, client: client, deadline: deadline),
            current()
        else { return .failed }
        return outcome
    }
}

private final class NavigationURLContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    func install(_ value: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { value.resume(returning: false); return false }
        continuation = value; return true
    }
    func finish(_ value: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let completion = continuation; continuation = nil
        lock.unlock(); completion?.resume(returning: value)
    }
}
