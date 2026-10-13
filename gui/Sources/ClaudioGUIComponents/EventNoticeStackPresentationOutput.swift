import Foundation

package struct EventNoticeStackPresentationOutput: Equatable {
    package var epoch: UUID
    package var width: Double = 440
    package var height: Double = 1
    package var queueHeight: Double = 0
    package var queueEntryHeight: Double = 0
    package var queueClearance: Double = 0
    package var showsCapacityHint = false
    package var isEligible = false
    package var requests: [EventNoticeMeasurementRequest] = []
    package var cardHeights: [UUID: Double] = [:]
    package var retiredContent: [UUID: EventNoticeCardContent] = [:]
}
