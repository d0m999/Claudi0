import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

/// The runtime uses `.live`; the harness exercises the same resolution and opening branches
/// with injected OS facts. No host-name to bundle-name mapping exists.
@MainActor
public enum SourceApplicationAdapter {
    public static func resolve(_ ancestors: [HostProcessIdentity], action: EventNoticeAction)
        -> SourceApplicationTarget?
    {
        resolve(ancestors, action: action, environment: .live)
    }

    public static func resolve(
        _ ancestors: [HostProcessIdentity], action: EventNoticeAction,
        environment: SourceApplicationEnvironment
    ) -> SourceApplicationTarget? {
        HostProcessAncestry.nearestApplication(
            in: ancestors, userID: environment.userID,
            readProcess: environment.process
        ) { identity in
            guard identity.pid != environment.ownPID,
                let app = environment.application(identity.pid), app.pid == identity.pid
            else { return nil }
            return SourceApplicationTarget(
                action: action, process: identity,
                bundleIdentifier: app.bundleIdentifier, applicationURL: app.url, name: app.name)
        }
    }

    public static func openApplication(
        _ target: SourceApplicationTarget,
        isCurrent: @escaping @MainActor () -> Bool,
        complete: @escaping @MainActor (SourceApplicationOpenResult) -> Void
    ) -> EventNoticeCancellation {
        openApplication(target, isCurrent: isCurrent, complete: complete, environment: .live)
    }

    public static func openApplication(
        _ target: SourceApplicationTarget,
        isCurrent: @escaping @MainActor () -> Bool,
        complete: @escaping @MainActor (SourceApplicationOpenResult) -> Void,
        environment: SourceApplicationEnvironment
    ) -> EventNoticeCancellation {
        let operation = SourceApplicationOpenOperation(
            target: target, isCurrent: isCurrent, complete: complete)
        let cancellation = EventNoticeCancellation { operation.cancel() }
        guard isCurrent() else { return cancellation }
        if let process = environment.process(target.process.pid) {
            guard process.identity == target.process, process.userID == environment.userID,
                let app = environment.application(target.process.pid),
                app.pid == target.process.pid,
                matches(app, target: target),
                environment.process(target.process.pid) == process, isCurrent()
            else { complete(.unavailable); return cancellation }
            complete(environment.activate(app.pid) ? .opened : .failed)
            return cancellation
        }
        // An unreadable live application must not be treated as an exited instance.
        guard !environment.processExists(target.process.pid),
            environment.application(target.process.pid) == nil,
            environment.locationMatches(target), isCurrent()
        else { complete(.unavailable); return cancellation }
        let frontmost = environment.frontmost()
        environment.reopenInactive(target.applicationURL) { app in
            guard let state = operation.take(), state.isCurrent() else { return }
            guard let app, matches(app, target: state.target),
                let process = environment.process(app.pid), process.userID == environment.userID,
                process.identity.pid == app.pid
            else { state.complete(.failed); return }
            guard environment.frontmost() == frontmost else { state.complete(.cancelled); return }
            state.complete(environment.activate(app.pid) ? .opened : .failed)
        }
        return cancellation
    }

    private static func matches(_ app: SourceApplicationDescriptor, target: SourceApplicationTarget)
        -> Bool
    {
        app.bundleIdentifier == target.bundleIdentifier && app.url == target.applicationURL
    }
}

/// NSWorkspace launch itself is not cancellable. Cancellation releases the source-bearing
/// state synchronously; the OS callback retains only this empty box after privacy clearing.
private final class SourceApplicationOpenOperation: @unchecked Sendable {
    struct State {
        let target: SourceApplicationTarget
        let isCurrent: @MainActor () -> Bool
        let complete: @MainActor (SourceApplicationOpenResult) -> Void
    }
    private let lock = NSLock()
    private var state: State?

    init(
        target: SourceApplicationTarget, isCurrent: @escaping @MainActor () -> Bool,
        complete: @escaping @MainActor (SourceApplicationOpenResult) -> Void
    ) {
        state = State(target: target, isCurrent: isCurrent, complete: complete)
    }

    func take() -> State? {
        lock.lock()
        defer { lock.unlock() }
        let value = state
        state = nil
        return value
    }

    func cancel() { _ = take() }
}
