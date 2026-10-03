import Combine

/// Generic owner of the "issue → monotonic revision → consume once → acknowledge" focus
/// handshake shared by every retained surface. One instance owns one focus space's counters,
/// request dedup and return-focus debt; SwiftUI views keep only their `@FocusState`
/// application. `Target` stays a per-site focus identity enum.
///
/// The handshake: a domain owner calls ``requestFocus(_:)`` and publishes the returned
/// revision; the view observes the revision, calls ``consumeRequest(_:)`` exactly once per
/// issue, applies its `@FocusState`, then acknowledges through its owner's own command
/// channel. Foundation-free apart from `Combine`, so the harness drives it with plain values.
@MainActor
public final class FocusRequestCoordinator<Target: Hashable>: ObservableObject {
    /// Monotonic issue counter. 0 means no request has been issued yet.
    @Published public private(set) var requestRevision: UInt64 = 0
    /// Payload of the latest issued request. `nil` means "apply the surface's own default
    /// focus policy" rather than an explicit control identity.
    @Published public private(set) var requestedTarget: Target?

    // @Published emits in willSet, so synchronous subscribers must validate against the
    // issued revision instead of the still-previous value of requestRevision.
    private var issuedRevision: UInt64 = 0
    private var consumedThroughRevision: UInt64 = 0
    private var returnFocusDebts: [Target] = []

    public init() {}

    /// Issues a focus request and returns its revision. Every call advances the revision,
    /// even when the payload matches the previous one, so repeated deep links re-apply.
    @discardableResult
    public func requestFocus(_ target: Target?) -> UInt64 {
        requestedTarget = target
        issuedRevision &+= 1
        let revision = issuedRevision
        requestRevision = revision
        return revision
    }

    /// Exactly-once consumption of the latest issued request. A stale or already-consumed
    /// revision returns false, so ordinary view recomputation cannot steal focus back.
    @discardableResult
    public func consumeRequest(_ revision: UInt64) -> Bool {
        guard revision == issuedRevision, revision > consumedThroughRevision else {
            return false
        }
        consumedThroughRevision = revision
        return true
    }

    /// Drops an unconsumed request whose target left the screen before the view applied it.
    public func cancelPendingRequest() {
        consumedThroughRevision = issuedRevision
        requestedTarget = nil
    }

    /// Clears only the payload without advancing or consuming the revision. A fresh route
    /// publishes its own fallback focus rules instead of inheriting the previous target.
    public func clearRequestedTarget() {
        requestedTarget = nil
    }

    // MARK: - Return-focus debt

    /// The oldest outstanding return-focus debt, if any.
    public var pendingReturnFocus: Target? { returnFocusDebts.first }

    /// Records that once an interrupting surface (alert, sheet, detail page) finishes, focus
    /// should return to `target`. Debts survive until consumed or explicitly cleared.
    public func pushReturnFocus(_ target: Target) {
        returnFocusDebts.append(target)
    }

    /// Consumes the oldest debt exactly once when it still matches `target`.
    @discardableResult
    public func popReturnFocus(_ target: Target) -> Bool {
        guard returnFocusDebts.first == target else { return false }
        returnFocusDebts.removeFirst()
        return true
    }

    /// Drops every outstanding debt (route change, fresh request, surface teardown).
    public func clearReturnFocus() {
        returnFocusDebts.removeAll()
    }
}

/// Exactly-once application tracker for projected focus facts: applies on first sight, on any
/// projection change, and whenever forced (for example when its surface re-appears). Ordinary
/// re-publication of an unchanged projection never re-applies.
public struct FocusApplicationTracker<Projection: Equatable> {
    private var lastApplied: Projection?

    public init() {}

    public mutating func recordAndShouldApply(
        _ projection: Projection,
        force: Bool = false
    ) -> Bool {
        let changed = lastApplied != projection
        lastApplied = projection
        return force || changed
    }
}
