import ClaudioCore
import Combine
import Foundation

public struct SessionNavigationTarget: Sendable, Equatable, Hashable {
    public let surface: HostSurfaceID
    public let projectKey: String?
    public let sessionID: String
    public let terminalProcess: HostProcessIdentity?
    public let route: HostSessionRoute?
    public let isParentSession: Bool

    public init(
        surface: HostSurfaceID, projectKey: String?, sessionID: String,
        route: HostSessionRoute? = nil, terminalProcess: HostProcessIdentity? = nil,
        isParentSession: Bool = false
    ) {
        self.surface = surface
        self.projectKey = projectKey
        self.sessionID = sessionID
        self.route = route
        self.terminalProcess = terminalProcess
        self.isParentSession = isParentSession
    }
}

public enum SessionNavigationCapability: Sendable, Equatable, Hashable {
    case unavailable
    case detailsOnly
    case viewSource
    case viewSession(SessionNavigationTarget)

    public var canViewSource: Bool { self != .unavailable }
    public var canOpenSession: Bool {
        if case .viewSession = self { return true }
        return false
    }
    public var canCopySessionID: Bool {
        switch self {
        case .unavailable, .detailsOnly: false
        case .viewSource, .viewSession: true
        }
    }
}

public func sessionNavigationCapability(
    for notice: HostEventNotice,
    verifiedTarget: SessionNavigationTarget? = nil
) -> SessionNavigationCapability {
    guard notice.isSemanticallyValid else { return .unavailable }
    guard let source = notice.source, source.sessionID != nil else { return .detailsOnly }
    if let verifiedTarget, !source.isParentSession, source.mainSessionIsKnown == true,
        source.projectKey != nil,
        verifiedTarget.surface == notice.surface,
        verifiedTarget.projectKey.map({ Data($0.utf8) })
            == source.projectKey.map({ Data($0.utf8) }),
        source.sessionID.map({ verifiedTarget.sessionID.utf8.elementsEqual($0.utf8) }) == true
    {
        return .viewSession(verifiedTarget)
    }
    return .viewSource
}

public enum SessionNavigationActionResult: Sendable, Equatable {
    case idle, unavailable, started, succeeded, exactReturnConfirmed, failed, timedOut, cancelled,
        copied, copyFailed, requestSent, applicationFallback, focusHandoffStarted
}

/// One request at a time, with a cancellable adapter and an independent deadline. Late callbacks
/// contain only version identities, and never keep a task or source alive in this coordinator.
/// Production injects verified host adapters. A generic success never removes a reminder.
@MainActor
public final class SessionNavigationCoordinator: ObservableObject {
    public static let timeout: TimeInterval = 3
    @Published public private(set) var result: SessionNavigationActionResult = .idle
    @Published public private(set) var action: EventNoticeAction?
    @Published public private(set) var applicationResult: SourceApplicationOpenResult = .idle
    public private(set) var capabilityGeneration: UUID

    private let navigate:
        @MainActor (
            SessionNavigationTarget, @escaping @MainActor (SessionNavigationActionResult) -> Void
        ) -> EventNoticeCancellation
    private let navigateHost:
        (
            @MainActor (
                SessionNavigationTarget, SourceApplicationTarget,
                @escaping @MainActor () -> Bool, TimeInterval,
                @escaping @MainActor (SessionNavigationActionResult) -> Void
            ) -> EventNoticeCancellation
        )?
    private let scheduler: EventNoticeScheduler
    private let uptime: @MainActor () -> TimeInterval
    private let openApplication:
        @MainActor (
            SourceApplicationTarget, @escaping @MainActor () -> Bool,
            @escaping @MainActor (SourceApplicationOpenResult) -> Void
        ) -> EventNoticeCancellation
    private var applicationTarget: SourceApplicationTarget?
    private var requestID: UUID?
    private var applicationRequestOwner: UUID?
    private var expectedFocusHandoff = false
    private var operation: EventNoticeCancellation?
    private var timeoutTask: EventNoticeCancellation?
    private weak var model: EventNoticeModel?
    private var observation: AnyCancellable?

    public init(
        model: EventNoticeModel? = nil,
        scheduler: EventNoticeScheduler = .live,
        capabilityGeneration: UUID = UUID(),
        navigate:
            @escaping @MainActor (
                SessionNavigationTarget,
                @escaping @MainActor (SessionNavigationActionResult) -> Void
            ) -> EventNoticeCancellation = { _, complete in
                complete(.unavailable)
                return EventNoticeCancellation {}
            },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        navigateHost: (
            @MainActor (
                SessionNavigationTarget, SourceApplicationTarget,
                @escaping @MainActor () -> Bool, TimeInterval,
                @escaping @MainActor (SessionNavigationActionResult) -> Void
            ) -> EventNoticeCancellation
        )? = nil,
        openApplication:
            @escaping @MainActor (
                SourceApplicationTarget, @escaping @MainActor () -> Bool,
                @escaping @MainActor (SourceApplicationOpenResult) -> Void
            ) -> EventNoticeCancellation = { _, _, complete in
                complete(.unavailable)
                return EventNoticeCancellation {}
            }
    ) {
        self.model = model
        self.scheduler = scheduler
        self.uptime = uptime
        self.capabilityGeneration = capabilityGeneration
        self.navigate = navigate
        self.navigateHost = navigateHost
        self.openApplication = openApplication
        observation = model?.$snapshot.sink { [weak self] snapshot in
            guard let self, let action = self.action else { return }
            if snapshot.receiverEpoch != action.epoch || self.model?.isCurrent(action) != true {
                self.reset()
            }
        }
    }

    public func openSession(
        _ capability: SessionNavigationCapability,
        action: EventNoticeAction,
        generation: UUID
    ) {
        guard requestID == nil else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action),
            let notice = model.sourceNotice(for: action),
            case .viewSession(let target) = capability,
            sessionNavigationCapability(for: notice, verifiedTarget: target) == capability
        else { result = .unavailable; return }
        let id = UUID()
        requestID = id
        self.action = action
        model.protect(action)
        result = .started
        timeoutTask = scheduler.schedule(after: Self.timeout) { [weak self] in
            guard let self, self.requestID == id else { return }
            self.finish(.timedOut, id: id, action: action, generation: generation)
        }
        guard requestID == id, capabilityGeneration == generation, model.isCurrent(action) else {
            reset(); return
        }
        let cancellation = navigate(target) { [weak self] outcome in
            self?.finish(outcome, id: id, action: action, generation: generation)
        }
        // Adapters may complete synchronously during dispatch.
        if requestID == id { operation = cancellation } else { cancellation.cancel() }
    }

    public func openSourceApplication(
        _ action: EventNoticeAction, generation: UUID, owner: UUID? = nil,
        completion: @escaping @MainActor (SourceApplicationOpenResult) -> Void = { _ in }
    ) {
        guard requestID == nil else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action),
            let target = model.sourceApplication(for: action), target.action == action
        else {
            self.action = action
            applicationResult = .unavailable
            completion(.unavailable)
            return
        }
        let id = UUID()
        requestID = id
        self.action = action
        applicationTarget = target
        applicationRequestOwner = owner
        model.protect(action)
        applicationResult = .started
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, self.requestID == id, self.capabilityGeneration == generation,
                let target = self.applicationTarget,
                self.model?.sourceApplication(for: action) == target
            else { return false }
            return true
        }
        let finish: @MainActor (SourceApplicationOpenResult) -> Void = { [weak self] outcome in
            guard let self, isCurrent() else { return }
            self.cancelRequest()
            self.applicationResult = outcome
            if outcome == .opened, self.model?.bannerSnapshot.current?.action == action {
                self.model?.dismiss()
            }
            completion(outcome)
        }
        timeoutTask = scheduler.schedule(after: Self.timeout) { finish(.timedOut) }
        guard isCurrent() else { reset(); return }
        let cancellation = openApplication(target, isCurrent, finish)
        if requestID == id { operation = cancellation } else { cancellation.cancel() }
    }

    /// Shared entry for banner body, primary action, Panel and Diagnostics. Fallback shares the
    /// original deadline, and neither app activation nor deep-link acceptance consumes a reminder.
    public func navigateSource(
        _ action: EventNoticeAction, generation: UUID, owner: UUID? = nil,
        completion: @escaping @MainActor (SessionNavigationActionResult) -> Void = { _ in }
    ) {
        guard requestID == nil else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action),
            let application = model.sourceApplication(for: action)
        else {
            self.action = action; result = .unavailable; applicationResult = .unavailable
            completion(.unavailable); return
        }
        let id = UUID()
        requestID = id; self.action = action; applicationTarget = application
        applicationRequestOwner = owner; model.protect(action)
        result = .started; applicationResult = .started
        let deadline = uptime() + Self.timeout
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.requestID == id && self.capabilityGeneration == generation
                && self.model?.isCurrent(action) == true
                && self.model?.sourceApplication(for: action) == application
        }
        let beforeAction: @MainActor () -> Bool = {
            current() && self.uptime() < deadline
        }
        let complete: @MainActor (SessionNavigationActionResult) -> Void = { [weak self] outcome in
            guard let self, current() else { return }
            let outcome = self.uptime() < deadline ? outcome : .timedOut
            self.finish(outcome, id: id, action: action, generation: generation)
            self.applicationResult =
                outcome == .applicationFallback
                ? .opened
                : (outcome == .timedOut
                    ? .timedOut
                    : outcome == .cancelled ? .cancelled : outcome == .failed ? .failed : .idle)
            completion(outcome)
        }
        timeoutTask = scheduler.schedule(after: Self.timeout) { complete(.timedOut) }
        var didFallBack = false
        let fallback: @MainActor () -> Void = { [weak self] in
            guard let self, current(), !didFallBack else { return }
            guard beforeAction() else { complete(.timedOut); return }
            didFallBack = true
            self.operation?.cancel()
            self.operation = nil
            self.expectedFocusHandoff = true
            let cancellation = self.openApplication(application, beforeAction) { outcome in
                switch outcome {
                case .opened: complete(.applicationFallback)
                case .timedOut: complete(.timedOut)
                case .cancelled: complete(.cancelled)
                default: complete(.failed)
                }
            }
            if current() { self.operation = cancellation } else { cancellation.cancel() }
        }
        guard let target = model.navigationTarget(for: action), let navigateHost else {
            fallback(); return
        }
        let cancellation = navigateHost(target, application, beforeAction, deadline) { outcome in
            guard current(), !didFallBack else { return }
            guard beforeAction() else { complete(.timedOut); return }
            if outcome == .focusHandoffStarted { self.expectedFocusHandoff = true; return }
            if outcome == .failed || outcome == .unavailable {
                fallback()
            } else {
                complete(outcome)
            }
        }
        // A synchronous host failure may already have installed the fallback cancellation.
        if current(), operation == nil { operation = cancellation } else { cancellation.cancel() }
    }

    /// Explicit copy is synchronous, so both validation and the actual pasteboard result belong
    /// to the captured action. Source browsing and copying never consume an attention version.
    @discardableResult
    public func copy(_ action: EventNoticeAction, write: (String) -> Bool) -> Bool {
        cancelRequest()
        applicationResult = .idle
        self.action = action
        let success = model?.copySessionID(action, write: write) == true
        result = success ? .copied : .copyFailed
        return success
    }

    public func replaceCapabilityGeneration(_ generation: UUID) {
        guard generation != capabilityGeneration else { return }
        capabilityGeneration = generation
        reset()
    }

    public func permitsFocusHandoff(to pid: Int32?) -> Bool {
        requestID != nil && expectedFocusHandoff && pid == applicationTarget?.process.pid
    }

    /// A presentation surface may cancel only the application request it dispatched.
    public func cancelSourceApplication(owner: UUID) {
        guard requestID != nil, applicationRequestOwner == owner else { return }
        cancel()
    }

    public func cancel() {
        cancelRequest()
        result = .cancelled
        applicationResult = .cancelled
    }

    public func reset() {
        cancelRequest()
        action = nil
        result = .idle
        applicationResult = .idle
    }

    private func finish(
        _ outcome: SessionNavigationActionResult, id: UUID, action: EventNoticeAction,
        generation: UUID
    ) {
        guard requestID == id else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action) else {
            reset(); return
        }
        cancelRequest()
        if outcome == .exactReturnConfirmed {
            if model.bannerSnapshot.current?.action == action { model.dismiss() }
        }
        if outcome == .exactReturnConfirmed, model.isAttentionReminder(action) {
            // Removing this exact version may synchronously invalidate the observed action.
            self.action = nil
            guard model.remove(action, reason: .exactReturnConfirmed) == .applied else {
                result = .unavailable; return
            }
        }
        result = outcome
    }

    private func cancelRequest() {
        requestID = nil
        applicationTarget = nil
        applicationRequestOwner = nil
        expectedFocusHandoff = false
        operation?.cancel()
        operation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        model?.protect(nil)
    }
}
