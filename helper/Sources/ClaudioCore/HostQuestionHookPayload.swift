import CoreFoundation
import Foundation

/// Only the request identity needed for question-intent deduplication. Tool arguments, question
/// text and answers are never retained. This value remains inside the helper invocation.
public struct HostQuestionHookPayload: Sendable, Equatable {
    public let sessionID: String
    public let requestID: String

    public init(sessionID: String, requestID: String) {
        self.sessionID = sessionID
        self.requestID = requestID
    }

    public static func parse(host: HostID, nativeEvent: String, data: Data?) -> Self? {
        guard let trigger = HostQuestionTrigger.binding(host: host, nativeEvent: nativeEvent),
            let data, !data.isEmpty, data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data).isDisjoint(with: [
                "hook_event_name", "tool_name", "tool_input", trigger.sessionIDField,
                trigger.requestIDField, "cwd", "agent_id", "is_subagent", "subagent",
                "notification_type",
            ]),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["hook_event_name"] as? String == nativeEvent,
            let toolName = object["tool_name"] as? String,
            trigger.toolNames.contains(where: { utf8BytesEqual($0, toolName) }),
            object["tool_input"] is [String: Any],
            let sessionID = identifier(object[trigger.sessionIDField]),
            let requestID = identifier(object[trigger.requestIDField])
        else { return nil }

        // Validate every source field before activity, receipts, audio or presentation. Optional
        // fields are never coerced: malformed context must not become a different valid identity.
        if let cwd = object["cwd"] {
            guard let value = cwd as? String, value.hasPrefix("/"), value.utf8.count <= 4096,
                !HostEventSource.containsUnsafeScalar(value)
            else { return nil }
        }
        if let agentID = object["agent_id"], identifier(agentID) == nil { return nil }
        for key in ["is_subagent", "subagent"] {
            if let value = object[key] {
                guard let number = value as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                else { return nil }
            }
        }
        if let kind = object["notification_type"], !(kind is String) { return nil }
        return Self(sessionID: sessionID, requestID: requestID)
    }

    private static func identifier(_ rawValue: Any?) -> String? {
        guard let value = rawValue as? String, !value.isEmpty,
            value.utf8.count <= HostEventSourceParser.maximumSessionIDBytes,
            !HostEventSource.containsUnsafeScalar(value),
            !value.contains(where: { $0.isWhitespace })
        else { return nil }
        return value
    }
}
