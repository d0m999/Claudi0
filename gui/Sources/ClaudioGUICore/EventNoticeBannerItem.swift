import Foundation

/// Display identity survives an in-place revision; actions always capture the record version.
public struct EventNoticeBannerItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let record: EventNoticeRecord
    public let phase: EventNoticePresentationPhase
    public let readingTime: EventNoticeReadingTime
    public let entrance: EventNoticeMotionPlan?
    public let relocation: EventNoticeMotionPlan?
    public let exit: EventNoticeMotionPlan?
    public let positionY: Double
    public let layerIndex: Int

    public var isInteractive: Bool { phase == .entering || phase == .visible }
    public var backgroundVeil: Double {
        switch layerIndex {
        case 0: 0
        case 1: 0.20
        default: 0.32
        }
    }
}
