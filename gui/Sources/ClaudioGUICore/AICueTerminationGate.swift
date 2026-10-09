import Foundation

/// Coalesces repeated application termination requests. The native caller must supply a fresh
/// coordinator reason when the user answers; a generating-to-unsaved transition needs the more
/// precise warning, while a completed task needs no second confirmation.
package struct AICueTerminationGate {
    package enum Decision: Equatable {
        case allow
        case cancel
        case alreadyWaiting
        case waitForAdoption
        case ask(AICueTerminationReason)
    }
    package init() {}

    private var waitingForAdoption = false
    private var presentedReason: AICueTerminationReason?

    package mutating func request(reason: AICueTerminationReason?) -> Decision {
        guard presentedReason == nil, !waitingForAdoption else { return .alreadyWaiting }
        guard let reason else { return .allow }
        if reason == .adopting { waitingForAdoption = true; return .waitForAdoption }
        presentedReason = reason
        return .ask(reason)
    }

    package mutating func adoptionCompleted(currentReason: AICueTerminationReason?) -> Decision {
        guard waitingForAdoption else { return .alreadyWaiting }
        waitingForAdoption = false
        return request(reason: currentReason)
    }

    package mutating func answer(quit: Bool, currentReason: AICueTerminationReason?) -> Decision {
        guard quit else { presentedReason = nil; return .cancel }
        if currentReason == .adopting {
            presentedReason = nil
            waitingForAdoption = true
            return .waitForAdoption
        }
        if let currentReason, currentReason != presentedReason {
            presentedReason = currentReason
            return .ask(currentReason)
        }
        presentedReason = nil
        return .allow
    }
}
