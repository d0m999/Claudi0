import Foundation

/// AppKit metadata after checking activation policy. Tests inject this same OS boundary.
public struct SourceApplicationDescriptor: Sendable {
    public let pid: Int32
    public let bundleIdentifier: String
    public let url: URL
    public let name: String

    public init(pid: Int32, bundleIdentifier: String, url: URL, name: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.name = name
    }
}
