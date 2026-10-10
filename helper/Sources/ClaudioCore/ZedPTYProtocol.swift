import Foundation

/// In-memory identity of a Claudio-managed terminal. No title, cwd, command or CLI output.
public struct ZedPTYSessionIdentity: Codable, Sendable, Equatable, Hashable {
    public let instance: UUID
    public let process: HostProcessIdentity
    public let child: HostProcessIdentity
    public let outerTTY: String
    public let innerTTY: String

    public init(
        instance: UUID, process: HostProcessIdentity, child: HostProcessIdentity,
        outerTTY: String, innerTTY: String
    ) {
        self.instance = instance; self.process = process; self.child = child
        self.outerTTY = outerTTY; self.innerTTY = innerTTY
    }

    public var isValid: Bool {
        process.isValid && child.isValid && process.pid != child.pid
            && HostNavigationEvidence.validTTY(outerTTY)
            && HostNavigationEvidence.validTTY(innerTTY) && outerTTY != innerTTY
    }
}

/// Private navigation transport, separate from and without changes to the hook notice schema.
public struct ZedPTYFrame: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case register, state, snapshot, input }
    public var schema = 1
    public let type: Kind
    public let epoch: UUID
    public let instance: UUID
    public var session: ZedPTYSessionIdentity?
    public var request: UUID?
    public var sequence: UInt64?
    public var focused: Bool?
    public var observedUptime: TimeInterval?
    public var caughtUp: Bool?

    public init(type: Kind, epoch: UUID, instance: UUID) {
        self.type = type; self.epoch = epoch; self.instance = instance
    }
}
