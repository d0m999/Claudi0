import ClaudioCore

/// A directory detail keeps the identity captured at entry, including across configuration reloads.
enum WorkspaceSettingsDetail: Equatable {
    case configuration
    case workspaces
    case scope(WorkspaceSoundWriteTarget)
}
