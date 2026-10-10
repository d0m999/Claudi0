import ClaudioCore
import Foundation

public enum ZedManagedSession {
    /// The stream peer is authenticated by the socket's kernel UID/PID. All JSON facts are
    /// re-read from the kernel, including both PTYs, before they become a routing identity.
    public static func validate(
        _ session: ZedPTYSessionIdentity, kernelPeerPID: Int32,
        application: SourceApplicationTarget, userID: UInt32,
        readProcess: (Int32) -> HostProcessSnapshot? = { HostProcessAncestry.read($0) },
        readTTY: (Int32) -> String? = HostNavigationEvidence.controllingTTY
    ) -> Bool {
        guard session.isValid, session.process.pid == kernelPeerPID,
            application.bundleIdentifier == "dev.zed.Zed",
            let bridge = readProcess(kernelPeerPID), bridge.identity == session.process,
            bridge.isOwned(by: userID),
            let child = readProcess(session.child.pid), child.identity == session.child,
            child.isOwned(by: userID), child.parentPID == kernelPeerPID,
            let app = readProcess(application.process.pid), app.identity == application.process,
            app.isOwned(by: userID),
            readTTY(kernelPeerPID) == session.outerTTY,
            readTTY(session.child.pid) == session.innerTTY,
            HostProcessAncestry.capture(
                startingAt: kernelPeerPID, userID: userID, readProcess: readProcess
            )
            .contains(application.process),
            readProcess(kernelPeerPID) == bridge, readProcess(session.child.pid) == child,
            readProcess(application.process.pid) == app,
            readTTY(kernelPeerPID) == session.outerTTY,
            readTTY(session.child.pid) == session.innerTTY
        else { return false }
        return true
    }

    /// Called while the one model still has the raw notice; it retains only the typed route.
    public static func resolve(
        _ notice: HostEventNotice, application: SourceApplicationTarget,
        sessions: [ZedPTYSessionIdentity]
    ) -> SessionNavigationTarget? {
        guard application.bundleIdentifier == "dev.zed.Zed",
            let ancestors = notice.processAncestors, let evidence = notice.navigationEvidence,
            evidence.isValid, ancestors.contains(evidence.process),
            notice.event != .subagentStop || notice.source?.isParentSession == true
        else { return nil }
        let matches = sessions.filter { session in
            guard session.isValid, evidence.tty == session.innerTTY,
                evidence.terminalProcess == session.child,
                let child = ancestors.firstIndex(of: session.child),
                child + 1 < ancestors.count, ancestors[child + 1] == session.process,
                ancestors.dropFirst(child + 2).contains(application.process)
            else { return false }
            return true
        }
        guard matches.count == 1, let session = matches.first else { return nil }
        return SessionNavigationTarget(
            surface: notice.surface, projectKey: notice.source?.projectKey,
            sessionID: notice.source?.sessionID ?? "", route: .zedManaged(session),
            terminalProcess: session.child, isParentSession: notice.source?.isParentSession == true)
    }
}
