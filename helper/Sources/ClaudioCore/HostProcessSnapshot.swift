import Foundation

/// Local-only process facts used to capture and revalidate the bounded ancestry.
public struct HostProcessSnapshot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case ordinary
        case systemLogin
    }

    public let identity: HostProcessIdentity
    public let parentPID: Int32
    /// Effective UID. Only a verified system login can be owned by its real UID instead.
    public let userID: UInt32
    public let realUserID: UInt32
    public let kind: Kind

    public init(
        identity: HostProcessIdentity, parentPID: Int32, userID: UInt32,
        realUserID: UInt32? = nil, kind: Kind = .ordinary
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.realUserID = realUserID ?? userID
        self.kind = kind
    }

    public func isOwned(by userID: UInt32) -> Bool {
        switch kind {
        case .ordinary: return self.userID == userID && realUserID == userID
        case .systemLogin: return self.userID == 0 && realUserID == userID
        }
    }
}
