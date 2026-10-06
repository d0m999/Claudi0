import Foundation

/// Complete measured cards determine a FIFO prefix. Queue expansion uses only the space left
/// after that prefix, so opening a list cannot oscillate the display capacity.
public struct EventNoticeStackLayout: Sendable, Equatable {
    public static let spacing: Double = 8
    public static let maximumQueueHeight: Double = 220
    public let visibleCapacity: Int
    public let cardsHeight: Double
    public let queueHeight: Double
    public let height: Double

    public static func resolve(
        cardHeights: [Double], totalCount: Int, availableHeight: Double,
        queueEntryHeight: Double, capacityHintHeight: Double = 0, queueExpanded: Bool = false,
        queueContentHeight: Double = maximumQueueHeight
    ) -> Self {
        let available = max(0, availableHeight)
        for count in stride(from: min(3, cardHeights.count, totalCount), through: 0, by: -1) {
            let prefix = Array(cardHeights.prefix(count))
            guard prefix.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            let cards = prefix.reduce(0, +) + Double(max(0, count - 1)) * spacing
            let waiting = totalCount > count
            let controls =
                (waiting ? queueEntryHeight + (count > 0 ? spacing : 0) : 0)
                + (capacityHintHeight > 0
                    ? capacityHintHeight + (waiting || count > 0 ? spacing : 0) : 0)
            guard count == 0 || cards + controls <= available else { continue }
            let base = min(available, cards + controls)
            let queue =
                waiting && queueExpanded
                ? min(
                    maximumQueueHeight, max(0, queueContentHeight),
                    max(0, available - base - spacing))
                : 0
            return Self(
                visibleCapacity: count, cardsHeight: cards, queueHeight: queue,
                height: base + (queue > 0 ? spacing + queue : 0))
        }
        return Self(visibleCapacity: 0, cardsHeight: 0, queueHeight: 0, height: 0)
    }
}
