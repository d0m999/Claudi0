import ClaudioCore
import Foundation

/// The current PermissionRequest wire format has no request-scoped reviewer evidence.
public enum CodexApprovalRoutingResolver {
    /// Preserve the adapter interface while the host lacks evidence; neither argument is read.
    public static func resolve(
        _: Data?, sessionsDirectory _: URL = ClaudioPaths.codexSessionsDirectory
    ) -> CodexApprovalRouting {
        // turn/settings/update changes next_step_settings without updating the rollout's
        // initial turn_context or emitting thread_settings_applied. Even a matching turn ID
        // cannot qualify that snapshot as the reviewer captured for this request.
        // Until the host supplies request-scoped evidence, ADR 0034 requires silence for
        // both initial policies. Do not read transcripts or infer a route from hook fields.
        .unavailable
    }
}
