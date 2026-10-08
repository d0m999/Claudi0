import Foundation

/// Coalesces repeated application termination requests. The native caller must supply a fresh
/// coordinator reason when the user answers; a generating-to-unsaved transition needs the more
/// precise warning, while a completed task needs no second confirmation.
package struct AICueTerminationGate {
    package enum Decision: Equatable {
        case allow
        case cancel
        case alreadyWaiting
        case ask(AICueTerminationReason)
    }
    package init() {}

    private var presentedReason: AICueTerminationReason?

    package mutating func request(reason: AICueTerminationReason?) -> Decision {
        guard presentedReason == nil else { return .alreadyWaiting }
        guard let reason else { return .allow }
        presentedReason = reason
        return .ask(reason)
    }

    package mutating func answer(quit: Bool, currentReason: AICueTerminationReason?) -> Decision {
        guard quit else { presentedReason = nil; return .cancel }
        if let currentReason, currentReason != presentedReason {
            presentedReason = currentReason
            return .ask(currentReason)
        }
        presentedReason = nil
        return .allow
    }
}
