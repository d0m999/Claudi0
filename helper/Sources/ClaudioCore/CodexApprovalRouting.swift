import Foundation

/// The reviewer captured for a specific approval request, when the host can prove it.
/// PermissionRequest and initial turn settings cannot establish it. Unknown routing is silent.
/// This is transient host metadata, never a receipt or a task-state cache.
public enum CodexApprovalRouting: Sendable, Equatable {
    case user
    case automatic
    case unavailable
}
