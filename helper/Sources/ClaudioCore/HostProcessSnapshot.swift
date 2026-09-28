import Foundation

/// Local-only process facts used to capture and revalidate the bounded ancestry.
public struct HostProcessSnapshot: Sendable, Equatable {
    public let identity: HostProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32

    public init(identity: HostProcessIdentity, parentPID: Int32, userID: UInt32) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
    }
}
