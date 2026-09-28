import ClaudioCore
import Foundation

/// A verified, ephemeral application identity bound to exactly one reminder version.
/// Opening it says nothing about the selected tab, window or session inside that application.
public struct SourceApplicationTarget: Sendable, Equatable {
    public let action: EventNoticeAction
    public let process: HostProcessIdentity
    public let bundleIdentifier: String
    public let applicationURL: URL
    public let name: String

    public init(
        action: EventNoticeAction, process: HostProcessIdentity, bundleIdentifier: String,
        applicationURL: URL, name: String
    ) {
        self.action = action
        self.process = process
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.name = name
    }
}
