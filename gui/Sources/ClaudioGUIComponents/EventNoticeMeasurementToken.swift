import Foundation

/// Created when requesting layout, carried unchanged by the measured view. Returning to the
/// same width does not return to the same generation (or resurrect an earlier content token).
package struct EventNoticeMeasurementToken: Hashable {
    package let identity: UUID
    package let epoch: UUID
    package let generation: UInt64
    package let width: Double
    package let role: EventNoticeMeasurementRole

    package init(
        identity: UUID, epoch: UUID, generation: UInt64, width: Double,
        role: EventNoticeMeasurementRole
    ) {
        self.identity = identity; self.epoch = epoch; self.generation = generation
        self.width = width; self.role = role
    }
}
