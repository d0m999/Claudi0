import Foundation

/// A native action can time out after dispatch. Only the concrete window readback proves
/// selection; this step does not prove terminal focus or extend the navigation deadline.
@MainActor
public enum ZedWindowSelection {
    public enum Dispatch: Sendable { case dispatched, indeterminate, unavailable }

    public struct Environment {
        public var now: () -> TimeInterval
        public var isCurrent: () -> Bool
        public var activate: () -> Bool
        public var raise: () -> Dispatch
        public var isSelected: () -> Bool
        public var pause: (TimeInterval) async -> Void

        public init(
            now: @escaping () -> TimeInterval, isCurrent: @escaping () -> Bool,
            activate: @escaping () -> Bool, raise: @escaping () -> Dispatch,
            isSelected: @escaping () -> Bool, pause: @escaping (TimeInterval) async -> Void
        ) {
            self.now = now; self.isCurrent = isCurrent; self.activate = activate
            self.raise = raise; self.isSelected = isSelected; self.pause = pause
        }
    }

    public static func select(deadline: TimeInterval, environment e: Environment) async -> Bool {
        func current() -> Bool { e.now() < deadline && !Task.isCancelled && e.isCurrent() }
        guard current(), e.activate(), current() else { return false }
        // cannotComplete is an uncertain dispatch, not evidence that Raise did not happen.
        // Do not resend it: only a concrete window readback can allow the next step.
        guard e.raise() != .unavailable else { return false }
        let readbackDeadline = min(deadline, e.now() + 0.25)
        while e.now() < readbackDeadline {
            guard current() else { return false }
            if e.isSelected() { return current() }
            guard current() else { return false }
            await e.pause(min(0.01, max(0, readbackDeadline - e.now())))
        }
        return false
    }
}
