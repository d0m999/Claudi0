import Foundation

public struct ZedPTYFocusState: Sendable, Equatable {
    public let instance: UUID
    public let sequence: UInt64
    public let focused: Bool
    public let observedUptime: TimeInterval

    public init(instance: UUID, sequence: UInt64, focused: Bool, observedUptime: TimeInterval) {
        self.instance = instance; self.sequence = sequence; self.focused = focused
        self.observedUptime = observedUptime
    }
}

public struct ZedNavigationSnapshot: Sendable {
    public let epoch: UUID
    public let inputRevision: UInt64
    public let states: [ZedPTYFocusState]

    public init(epoch: UUID, inputRevision: UInt64, states: [ZedPTYFocusState]) {
        self.epoch = epoch; self.inputRevision = inputRevision; self.states = states
    }
}

/// Searches existing items only. Receipts, not window titles or dispatch success, prove return.
@MainActor
public enum ZedNavigationSearch {
    public enum Step: Sendable { case nextTab, left, right, up, down }

    public struct Environment {
        public var now: () -> TimeInterval
        public var isCurrent: () -> Bool
        public var windows: () -> [UUID]
        public var selectWindow: (UUID) async -> Bool
        public var isWindowCurrent: (UUID) -> Bool
        public var step: (Step) async -> Bool
        /// A barrier over current peers, so an already queued focus-out cannot be ignored.
        public var snapshot: () async -> ZedNavigationSnapshot?
        public var supportsDirections: () -> Bool

        public init(
            now: @escaping () -> TimeInterval, isCurrent: @escaping () -> Bool,
            windows: @escaping () -> [UUID], selectWindow: @escaping (UUID) async -> Bool,
            isWindowCurrent: @escaping (UUID) -> Bool, step: @escaping (Step) async -> Bool,
            snapshot: @escaping () async -> ZedNavigationSnapshot?,
            supportsDirections: @escaping () -> Bool = { true }
        ) {
            self.now = now; self.isCurrent = isCurrent; self.windows = windows
            self.selectWindow = selectWindow; self.isWindowCurrent = isWindowCurrent
            self.step = step; self.snapshot = snapshot
            self.supportsDirections = supportsDirections
        }
    }

    public static func navigate(instance: UUID, deadline: TimeInterval, environment e: Environment)
        async -> SessionNavigationActionResult
    {
        func status() -> SessionNavigationActionResult? {
            if e.now() >= deadline { return .timedOut }
            if Task.isCancelled || !e.isCurrent() { return .cancelled }
            return nil
        }
        if let result = status() { return result }
        guard let baseline = await e.snapshot() else { return .unavailable }
        if let result = status() { return result }
        let startedAt = e.now()
        let oldSequence = baseline.states.first { $0.instance == instance }?.sequence ?? 0
        var failure: SessionNavigationActionResult?

        func checkpoint(_ window: UUID) async -> ZedNavigationSnapshot? {
            if let result = status() { failure = result; return nil }
            guard e.isWindowCurrent(window), let snapshot = await e.snapshot() else {
                failure = .unavailable; return nil
            }
            if let result = status() { failure = result; return nil }
            guard snapshot.epoch == baseline.epoch,
                snapshot.inputRevision == baseline.inputRevision
            else { failure = .cancelled; return nil }
            guard e.isWindowCurrent(window) else { failure = .cancelled; return nil }
            return snapshot
        }
        func targetIsFocused(_ snapshot: ZedNavigationSnapshot) -> Bool {
            let focused = snapshot.states.filter(\.focused)
            guard focused.count == 1, let state = focused.first else { return false }
            return state.instance == instance && state.sequence > oldSequence
                && state.observedUptime.isFinite && state.observedUptime >= startedAt
                && state.observedUptime <= e.now()
        }
        func confirm(_ snapshot: ZedNavigationSnapshot, window: UUID) async -> Bool {
            guard targetIsFocused(snapshot), let final = await checkpoint(window) else {
                return false
            }
            return targetIsFocused(final)
        }

        let windows = Array(e.windows().prefix(4))
        var managedWindows: [UUID] = []
        // Probe each window's current item before a deep sweep. An uninstrumented first
        // window must not consume the whole budget before a later window can report focus.
        for window in windows {
            if let result = status() { return result }
            guard await e.selectWindow(window) else { return status() ?? .unavailable }
            guard var snapshot = await checkpoint(window) else { return failure ?? .unavailable }
            if e.supportsDirections() && !snapshot.states.contains(where: \.focused) {
                // AX selection can leave Zed's center/sidebar focused. Probe the open
                // terminal dock through the explicit Workspace binding before deciding
                // whether this window has any managed sessions to search.
                guard e.isWindowCurrent(window), await e.step(.down) else {
                    return status() ?? .unavailable
                }
                guard let dock = await checkpoint(window) else {
                    return failure ?? .unavailable
                }
                snapshot = dock
            }
            let focused = snapshot.states.filter(\.focused)
            if focused.count == 1, let state = focused.first,
                state.sequence > 0,
                state.observedUptime.isFinite && state.observedUptime > 0
                    && state.observedUptime <= e.now()
            {
                managedWindows.append(window)
            }
            if await confirm(snapshot, window: window) { return .exactReturnConfirmed }
            if let failure { return failure }
        }

        // A bounded cardinal sweep covers common split layouts without a create/split action.
        // Receipts stop it immediately on a match; larger/unreachable layouts retain fallback.
        let sweep: [Step] = [
            .down, .left, .up, .right,
            .down, .down, .left, .left, .up, .up, .right, .right,
            .left, .down, .right, .up,
        ]
        // A barrier-read current receipt, including continuous focus, is only an order hint.
        // Each target still needs
        // its own new receipt and final window/identity barrier before confirmation.
        let searchWindows = managedWindows + windows.filter { !managedWindows.contains($0) }
        for window in searchWindows {
            if let result = status() { return result }
            guard await e.selectWindow(window) else { return status() ?? .unavailable }
            var searched = Set<UUID>()
            func scanTabs(allowUnmanaged: Bool = true) async -> Bool {
                var seen = Set<UUID>()
                for _ in 0..<16 {
                    guard let snapshot = await checkpoint(window) else { return false }
                    if await confirm(snapshot, window: window) { return true }
                    if failure != nil { return false }
                    let focused = snapshot.states.filter(\.focused)
                    if !allowUnmanaged && focused.count != 1 { break }
                    if focused.count == 1, let selected = focused.first?.instance {
                        if seen.contains(selected) || searched.contains(selected) { break }
                        seen.insert(selected)
                    }
                    if let result = status() { failure = result; return false }
                    guard e.isWindowCurrent(window), await e.step(.nextTab) else {
                        failure = status() ?? .unavailable; return false
                    }
                }
                searched.formUnion(seen)
                return false
            }
            if await scanTabs(allowUnmanaged: false) { return .exactReturnConfirmed }
            if let failure { return failure }
            if !e.supportsDirections() {
                if await scanTabs() { return .exactReturnConfirmed }
                if let failure { return failure }
                continue
            }
            // Inspect adjacent panes before spending up to 16 tab probes in an
            // uninstrumented editor/sidebar. The four explicit workspace bindings
            // also remain active if a direction leaves the terminal dock.
            for direction in [Step.right, .down, .left, .up] {
                if let result = status() { return result }
                guard e.isWindowCurrent(window), await e.step(direction) else {
                    return status() ?? .unavailable
                }
                guard let snapshot = await checkpoint(window) else {
                    return failure ?? .unavailable
                }
                if await confirm(snapshot, window: window) { return .exactReturnConfirmed }
                if let failure { return failure }
            }
            if await scanTabs(allowUnmanaged: false) { return .exactReturnConfirmed }
            if let failure { return failure }
            for direction in sweep {
                if let result = status() { return result }
                guard e.isWindowCurrent(window), await e.step(direction) else {
                    return status() ?? .unavailable
                }
                if await scanTabs(allowUnmanaged: false) { return .exactReturnConfirmed }
                if let failure { return failure }
            }
            // Leave opaque tab probes until all known pane directions have been visited.
            if await scanTabs() { return .exactReturnConfirmed }
            if let failure { return failure }
        }
        return status() ?? .unavailable
    }
}
