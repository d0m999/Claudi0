import ClaudioCore
import Foundation

public enum HostSessionRoute: Sendable, Equatable, Hashable {
    case terminal(tty: String)
    case iterm(sessionID: String, tty: String)
    case tmux(TmuxNavigationEvidence)
    case ide(shells: [HostProcessIdentity])
    case zedManaged(ZedPTYSessionIdentity)
    case codex(threadID: String)
}

public enum HostSessionTargetResolver {
    /// This establishes an OS application binding, not a claim that the session still exists.
    /// Host adapters revalidate the instance, unique session and selected window at click time.
    public static func resolve(_ notice: HostEventNotice, application: SourceApplicationTarget?)
        -> SessionNavigationTarget?
    {
        guard let application, let evidence = notice.navigationEvidence, evidence.isValid,
            notice.processAncestors?.contains(evidence.process) == true
        else { return nil }
        guard notice.event != .subagentStop || notice.source?.isParentSession == true else {
            return nil
        }
        let route: HostSessionRoute
        if let tmux = evidence.tmux {
            route = .tmux(tmux)
        } else {
            switch application.bundleIdentifier {
            case "com.apple.Terminal":
                guard let tty = evidence.tty, let terminalProcess = evidence.terminalProcess,
                    notice.processAncestors?.contains(terminalProcess) == true
                else { return nil }
                route = .terminal(tty: tty)
            case "com.googlecode.iterm2":
                guard let tty = evidence.tty, let session = evidence.itermSessionID else {
                    return nil
                }
                route = .iterm(sessionID: session, tty: tty)
            case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92":
                guard let ancestors = notice.processAncestors else { return nil }
                route = .ide(shells: ancestors)
            case "com.openai.codex":
                guard let thread = evidence.codexThreadID,
                    notice.source?.sessionID == thread
                else { return nil }
                route = .codex(threadID: thread)
            default: return nil
            }
        }
        // A parent session ID is supplied only by the source parser's explicit binding.
        return SessionNavigationTarget(
            surface: notice.surface, projectKey: notice.source?.projectKey,
            sessionID: notice.source?.sessionID ?? "", route: route,
            terminalProcess: evidence.terminalProcess,
            isParentSession: notice.source?.isParentSession == true)
    }
}
