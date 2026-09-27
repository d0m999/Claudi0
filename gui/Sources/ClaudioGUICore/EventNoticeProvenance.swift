/// Presentation sources remain distinct from receipt-backed host activation.
public enum EventNoticeProvenance: Sendable, Equatable {
    case hostHook
    case developmentCodexRollout
}
