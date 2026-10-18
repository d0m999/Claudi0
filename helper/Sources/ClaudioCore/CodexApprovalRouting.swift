import Foundation

/// A hook says an approval is being considered, not who must handle it. Unknown routing is
/// deliberately silent. This is transient host metadata, never a receipt or a task-state cache.
public enum CodexApprovalRouting: Sendable, Equatable {
    case user
    case automatic
    case unavailable
}
