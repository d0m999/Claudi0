import Foundation

package enum EventNoticeMeasurementRole: Hashable {
    case card(UUID)
    case queueEntry(visibleCount: Int, expanded: Bool)
    case queueContent
    case capacityHint
}
