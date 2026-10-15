import ClaudioGUICore

/// The browsing conversion an in-session sound-pack deletion earns. Deep links and deletions
/// that happen outside this session keep the unavailable page; only a delete this session
/// requested and that succeeded converts the current entry to the overview.
package enum SettingsSoundPackDeletionTransition: Equatable, Sendable {
    /// No delete activity concerns the browsed pack right now; drop any remembered transaction.
    case inactive
    /// The writer accepted the delete and has not confirmed it yet.
    case pending
    /// The writer confirmed success; convert the current browsing entry to the overview.
    case convert
}

/// One pure decision per editor publication. The session owns the transaction stamp; this
/// function only decides what the newest delete activity phase means for the browsed pack.
package func settingsSoundPackDeletionTransition(
    browsedPackID: String?,
    phase: SoundPackEditorActivityPhase?,
    remembersPendingTransaction: Bool
) -> SettingsSoundPackDeletionTransition {
    guard let browsedPackID, let phase else { return .inactive }
    switch phase {
    case .busy:
        return .pending
    case .succeeded:
        // A terminal success without this session's own pending transaction belongs to an
        // external deletion; the requested route keeps its unavailable page.
        return remembersPendingTransaction ? .convert : .inactive
    case .failed, .partial, .orphan, .cancelled:
        // The pack remains on disk; the ordinary route continues unchanged.
        return .inactive
    }
}
