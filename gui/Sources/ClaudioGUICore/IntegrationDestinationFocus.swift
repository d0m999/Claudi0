import ClaudioCore

/// Focus targets for the prototype-aligned Integrations destination. The destination has one
/// vertical reading order; selection and Toggle remain separate focusable controls.
public enum IntegrationDestinationFocusTarget: Sendable, Hashable {
    case title
    case agent(HostID)
    case toggle(HostID)
    case connectionRow(IntegrationConnectionRowKind)
    case copyConfigurationSource(HostID)
    case dismissFeedback(revision: UInt64)
}

/// Monotonic hand-off from the retained Settings owner to the destination's FocusState. The
/// handshake itself (issue → revision → consume once → cancel) is the shared
/// ``FocusRequestCoordinator``; this alias only names the destination's target space. It must
/// stay on one line: the construction-census fence (`unmodeledConstructionShapes`) only models
/// single-line aliases whose right-hand side is decidable, and flags everything else.
public typealias IntegrationDestinationFocusCoordinator = FocusRequestCoordinator<IntegrationDestinationFocusTarget>
