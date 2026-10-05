import Foundation

/// A versioned adapter contract for a question tool's call intent. The matcher and
/// payload validator consume this same allowlist. It is not evidence that a question
/// reached a visible input UI or that the host has paused.
public struct HostQuestionTrigger: Sendable, Equatable {
    public let host: HostID
    public let nativeEvent: String
    public let toolNames: [String]
    public let schemaRevision: Int
    public let sessionIDField: String
    public let requestIDField: String

    public var matcher: String {
        "^(" + toolNames.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")$"
    }

    public var capability: HostCapabilityBinding {
        HostCapabilityBinding(
            host: host, event: .notification, nativeEvent: nativeEvent,
            support: .partial, qualification: .questionIntentOnly,
            schemaRevision: schemaRevision)
    }

    public static let claudeCode = HostQuestionTrigger(
        host: .claudeCode, nativeEvent: "PreToolUse", toolNames: ["AskUserQuestion"],
        schemaRevision: 1, sessionIDField: "session_id", requestIDField: "tool_use_id")

    public static let kimiCode = HostQuestionTrigger(
        host: .kimiCode, nativeEvent: "PreToolUse", toolNames: ["AskUserQuestion"],
        schemaRevision: 1, sessionIDField: "session_id", requestIDField: "tool_call_id")

    /// Codex and WorkBuddy remain evidence-gated. A protocol or tool-name guess does
    /// not install a production binding on either surface.
    public static func binding(host: HostID, nativeEvent: String) -> HostQuestionTrigger? {
        [claudeCode, kimiCode].first { $0.host == host && $0.nativeEvent == nativeEvent }
    }
}
