import CoreFoundation
import Foundation

/// Grok-native fields stay inside its adapter. Only validated identities and source facts escape;
/// tool arguments, messages, error details and responses are never retained.
public struct GrokBuildHookPayload: Sendable, Equatable {
    public let sessionID: String
    public let workingDirectory: String
    public let workspaceRoot: String
    public let isSubagent: Bool
    public let identity: HostQuestionHookPayload?
    public let reason: HostEventNoticeReason?

    public static func parse(nativeEvent: String, data: Data?) -> Self? {
        guard let nativeToken = eventToken(nativeEvent),
            ["StopFailure", "Notification", "PreToolUse"].contains(nativeEvent),
            let data, !data.isEmpty, data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data).isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            validEvent(object, nativeEvent: nativeEvent, nativeToken: nativeToken),
            aliasesAgree(object),
            let session = identifier(object["sessionId"] ?? object["session_id"]),
            let cwd = path(object["cwd"]),
            let workspace = path(object["workspaceRoot"] ?? object["workspace_root"])
        else { return nil }

        for key in [
            "timestamp", "permissionMode", "permission_mode", "transcriptPath", "transcript_path",
            "clientIdentifier", "client_identifier", "message", "title", "level", "errorDetails",
            "error_details", "lastAssistantMessage", "last_assistant_message",
            "notificationType", "notification_type", "error",
        ] where object[key] != nil {
            guard object[key] is String else { return nil }
        }
        for key in [
            "promptId", "prompt_id", "toolUseId", "tool_use_id", "toolName", "tool_name",
            "subagentType", "subagent_type", "subagentId", "subagent_id", "agent_id",
        ] where object[key] != nil {
            guard identifier(object[key]) != nil else { return nil }
        }
        for key in ["toolInput", "tool_input"] where object[key] != nil {
            guard object[key] is [String: Any] else { return nil }
        }
        for key in ["toolInputTruncated", "tool_input_truncated", "is_subagent", "subagent"]
        where object[key] != nil {
            guard boolean(object[key]) != nil else { return nil }
        }
        let child =
            object["subagentType"] != nil || object["subagent_type"] != nil
            || object["subagentId"] != nil || object["subagent_id"] != nil
            || object["agent_id"] != nil
            || boolean(object["is_subagent"]) == true || boolean(object["subagent"]) == true
        let identity: HostQuestionHookPayload?
        let reason: HostEventNoticeReason?
        switch nativeEvent {
        case "StopFailure":
            guard !child, let prompt = identifier(object["promptId"] ?? object["prompt_id"]),
                let error = object["error"] as? String,
                [
                    "rate_limit", "authentication_failed", "invalid_request", "server_error",
                    "max_output_tokens", "unknown",
                ].contains(error)
            else { return nil }
            identity = .init(sessionID: session, requestID: "StopFailure:" + prompt)
            reason = nil
        case "Notification":
            guard
                (object["notificationType"] ?? object["notification_type"]) as? String
                    == "permission_prompt",
                let mode = (object["permissionMode"] ?? object["permission_mode"]) as? String,
                ["default", "auto", "plan"].contains(mode)
            else { return nil }
            // 1.0.62 emits permission_prompt for forced ask even when a YOLO client
            // immediately auto-answers it. bypassPermissions is not a user wait.
            // The native notification has no stable approval request ID. Never invent one or
            // infer resolution; use the existing notification debounce/reminder revision policy.
            identity = nil
            reason = .permission
        case "PreToolUse":
            guard (object["toolName"] ?? object["tool_name"]) as? String == "ask_user_question",
                (object["toolInput"] ?? object["tool_input"]) is [String: Any],
                let request = identifier(object["toolUseId"] ?? object["tool_use_id"])
            else { return nil }
            identity = .init(sessionID: session, requestID: "PreToolUse:" + request)
            reason = .questionIntent
        default: return nil
        }
        return .init(
            sessionID: session, workingDirectory: cwd, workspaceRoot: workspace,
            isSubagent: child, identity: identity, reason: reason)
    }

    /// The runner reserves and injects these fields after applying hook-defined env values.
    public func matchesRunner(nativeEvent: String, environment: [String: String]) -> Bool {
        guard environment["GROK_HOOK_EVENT"] == Self.eventToken(nativeEvent),
            let name = environment["GROK_HOOK_NAME"], !name.isEmpty, name.utf8.count <= 4096,
            !HostEventSource.containsUnsafeScalar(name),
            let runnerSession = environment["GROK_SESSION_ID"],
            utf8BytesEqual(runnerSession, sessionID),
            let runnerRoot = environment["GROK_WORKSPACE_ROOT"],
            utf8BytesEqual(runnerRoot, workspaceRoot)
        else { return false }
        return true
    }

    static func eventToken(_ event: String) -> String? {
        switch event {
        case "StopFailure": "stop_failure"
        case "Notification": "notification"
        case "PreToolUse": "pre_tool_use"
        default: nil
        }
    }

    private static func validEvent(
        _ object: [String: Any], nativeEvent: String, nativeToken: String
    )
        -> Bool
    {
        guard object["hookEventName"] != nil || object["hook_event_name"] != nil else {
            return false
        }
        if let camel = object["hookEventName"], (camel as? String) != nativeToken { return false }
        if let snake = object["hook_event_name"], (snake as? String) != nativeEvent { return false }
        return true
    }

    private static func aliasesAgree(_ object: [String: Any]) -> Bool {
        for (camel, snake) in [
            ("sessionId", "session_id"), ("workspaceRoot", "workspace_root"),
            ("promptId", "prompt_id"), ("permissionMode", "permission_mode"),
            ("transcriptPath", "transcript_path"), ("clientIdentifier", "client_identifier"),
            ("toolName", "tool_name"), ("toolUseId", "tool_use_id"),
            ("subagentType", "subagent_type"), ("subagentId", "subagent_id"),
            ("notificationType", "notification_type"), ("errorDetails", "error_details"),
            ("lastAssistantMessage", "last_assistant_message"),
            ("toolInput", "tool_input"), ("toolInputTruncated", "tool_input_truncated"),
        ] {
            guard let first = object[camel], let second = object[snake] else { continue }
            // Sorted JSON retains numeric-vs-boolean distinctions and opaque string bytes;
            // dictionary equality could otherwise equate true with 1 or normalize identifiers.
            guard
                let a = try? JSONSerialization.data(
                    withJSONObject: first, options: [.sortedKeys, .fragmentsAllowed]),
                let b = try? JSONSerialization.data(
                    withJSONObject: second, options: [.sortedKeys, .fragmentsAllowed]),
                a == b
            else { return false }
        }
        return true
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
            !HostEventSource.containsUnsafeScalar(value), !value.contains(where: \.isWhitespace)
        else { return nil }
        return value
    }

    private static func path(_ value: Any?) -> String? {
        guard let value = value as? String, WorkspaceDirectory.validPath(value) else { return nil }
        return value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value.boolValue
    }
}
