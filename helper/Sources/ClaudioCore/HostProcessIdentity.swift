import Foundation

/// Kernel identity only. No command line, environment, executable path or user data goes on wire.
public struct HostProcessIdentity: Codable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public var isValid: Bool {
        pid > 1 && startSeconds > 0 && startMicroseconds < 1_000_000
    }
}
