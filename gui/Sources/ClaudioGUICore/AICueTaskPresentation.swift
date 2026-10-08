import Foundation

/// A readonly view projection, distinct from task ownership and adoption permissions.
package struct AICueTaskPresentation {
    package enum Kind: String { case ready, generating, saving, pending, results, failed }
    package let isDetachedTask: Bool
    package let showsLocalFailure: Bool
    package let kind: Kind
    package var isExpanded: Bool { kind != .ready }

    package init(
        state: AICueGenerationTaskState, hasVisibleResults: Bool, hasFailure: Bool,
        isCurrentContext: Bool = true
    ) {
        if case .failed = state {
            showsLocalFailure = false
        } else {
            showsLocalFailure = hasFailure
        }
        kind =
            switch state {
            case .generating: .generating
            case .saving: .saving
            case .pending: .pending
            case .failed: .failed
            case .saved, .idle:
                hasVisibleResults ? .results : (hasFailure ? .failed : .ready)
            }
        isDetachedTask = !isCurrentContext && kind != .ready
    }
}
