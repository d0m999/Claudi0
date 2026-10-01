import Foundation

public enum EventNoticeReadingConsumer: Hashable, Sendable {
    case panel
    case diagnostics
    /// Compatibility entry point for existing versioned source commands.
    case legacy
}

/// One shared frozen reading projection; consumers retain only selection identities.
public struct EventNoticeReadingSnapshot: Sendable, Equatable {
    public let latest: EventNoticeRecord?
    public let records: [EventNoticeRecord]
    public let pendingCount: Int
    public let droppedCount: Int
    public let receiverEpoch: UUID
    public let isOpen: Bool
    init(
        records: [EventNoticeRecord], pendingCount: Int, droppedCount: Int, receiverEpoch: UUID,
        isOpen: Bool, latest: EventNoticeRecord? = nil
    ) {
        self.records = records; self.pendingCount = pendingCount; self.droppedCount = droppedCount
        self.receiverEpoch = receiverEpoch; self.isOpen = isOpen; self.latest = latest
    }
    public var needsRefresh: Bool {
        pendingCount > 0 || records.contains { $0.isSuperseded }
    }
}
