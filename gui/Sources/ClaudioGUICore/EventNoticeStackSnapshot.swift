import Foundation

/// The display queue is independent of the frozen Attention reader. Exits are inert frames.
public struct EventNoticeStackSnapshot: Sendable, Equatable {
    public let visible: [EventNoticeBannerItem]
    public let queued: [EventNoticeBannerItem]
    public let exiting: [EventNoticeBannerItem]
    public let isQueueExpanded: Bool
    public let queueOpenedAt: TimeInterval?
    public let pauseReasons: EventNoticePauseReason
    public let overflowCount: Int
    public let capacityHintCount: Int
    public let receiverEpoch: UUID

    public var hasPresentation: Bool {
        !visible.isEmpty || !queued.isEmpty || !exiting.isEmpty || capacityHintCount > 0
    }
    public var totalCount: Int { visible.count + queued.count }
    public var candidates: [EventNoticeBannerItem] { Array((visible + queued).prefix(3)) }

    public init(
        visible: [EventNoticeBannerItem] = [], queued: [EventNoticeBannerItem] = [],
        exiting: [EventNoticeBannerItem] = [], isQueueExpanded: Bool = false,
        queueOpenedAt: TimeInterval? = nil, pauseReasons: EventNoticePauseReason = [],
        overflowCount: Int = 0, capacityHintCount: Int = 0, receiverEpoch: UUID
    ) {
        self.visible = visible
        self.queued = queued
        self.exiting = exiting
        self.isQueueExpanded = isQueueExpanded
        self.queueOpenedAt = queueOpenedAt
        self.pauseReasons = pauseReasons
        self.overflowCount = overflowCount
        self.capacityHintCount = capacityHintCount
        self.receiverEpoch = receiverEpoch
    }
}
