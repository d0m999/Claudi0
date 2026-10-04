import CoreFoundation
import Foundation

/// Validated identities only. The native JSON object and sensitive bodies do not escape parse().
public struct AdditionalHostHookPayload: Sendable, Equatable {
    public let identity: HostQuestionHookPayload?

    public static func parse(host: HostID, nativeEvent: String, data: Data?) -> Self? {
        guard host == .opencode || host == .kimiCode,
            HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent) != nil,
            let data, !data.isEmpty, data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data).isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["hook_event_name"] as? String == nativeEvent,
            let sessionID = identifier(object["session_id"])
        else { return nil }
        if let cwd = object["cwd"] {
            guard let cwd = cwd as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096,
                !HostEventSource.containsUnsafeScalar(cwd)
            else { return nil }
        }
        if host == .opencode {
            let allowed: Set<String> = [
                "bridge_schema", "hook_event_name", "session_id",
                "session_kind", "parent_session_id", "cwd", "turn_id", "message_id",
                "origin_kind", "executing", "terminal", "error_kind", "request_id",
            ]
            guard Set(object.keys).isSubset(of: allowed), integer(object["bridge_schema"]) == 1,
                let kind = object["session_kind"] as? String, ["main", "child"].contains(kind)
            else { return nil }
            if kind == "child" {
                guard let parent = identifier(object["parent_session_id"]), parent != sessionID
                else { return nil }
            } else if object["parent_session_id"] != nil {
                return nil
            }
            for field in ["turn_id", "message_id", "request_id"] where object[field] != nil {
                guard identifier(object[field]) != nil else { return nil }
            }
            if let raw = object["origin_kind"], !(raw is String) { return nil }
            if let raw = object["executing"], boolean(raw) == nil { return nil }
            if let raw = object["terminal"], !(raw is String) { return nil }
            if let raw = object["error_kind"], !(raw is String) { return nil }
            switch nativeEvent {
            case "UserTurnStarted":
                guard kind == "main", object["origin_kind"] as? String == "user",
                    boolean(object["executing"]) == true, identifier(object["message_id"]) != nil,
                    let turn = identifier(object["turn_id"])
                else { return nil }
                return .init(
                    identity: .init(sessionID: sessionID, requestID: nativeEvent + ":" + turn))
            case "ResponseCompleted", "ResponseFailed", "SubagentCompleted":
                let failed = nativeEvent == "ResponseFailed"
                guard kind == (nativeEvent == "SubagentCompleted" ? "child" : "main"),
                    object["terminal"] as? String == (failed ? "failure" : "success"),
                    identifier(object["message_id"]) != nil,
                    let turn = identifier(object["turn_id"])
                else { return nil }
                if failed {
                    guard let error = object["error_kind"] as? String,
                        [
                            "APIError", "ProviderAuthError", "UnknownError",
                            "MessageOutputLengthError",
                            "StructuredOutputError",
                        ].contains(error)
                    else { return nil }
                } else if object["error_kind"] != nil {
                    return nil
                }
                return .init(
                    identity: .init(sessionID: sessionID, requestID: nativeEvent + ":" + turn))
            case "PermissionRequested", "QuestionAsked":
                guard let request = identifier(object["request_id"]) else { return nil }
                return .init(
                    identity: .init(sessionID: sessionID, requestID: nativeEvent + ":" + request))
            default: return nil
            }
        }
        guard object["client_type"] as? String == "kimi_code_cli" else { return nil }
        if let agent = object["agent_id"], identifier(agent) == nil { return nil }
        if let turn = object["turn_id"], integer(turn) == nil { return nil }
        for key in ["tool_call_id", "id"] where object[key] != nil {
            guard identifier(object[key]) != nil else { return nil }
        }
        if let tool = object["tool_name"], identifier(tool) == nil { return nil }
        if let input = object["tool_input"], !(input is [String: Any]) { return nil }
        if let origin = object["origin_kind"], !(origin is String) { return nil }
        switch nativeEvent {
        case "TurnStarted":
            guard object["origin_kind"] as? String == "user",
                let turn = integer(object["turn_id"]), turn >= 0
            else { return nil }
            return .init(identity: .init(sessionID: sessionID, requestID: "TurnStarted:\(turn)"))
        case "PermissionRequest":
            guard let call = identifier(object["tool_call_id"]),
                identifier(object["tool_name"]) != nil
            else { return nil }
            let request = identifier(object["id"]) ?? call
            let agent = identifier(object["agent_id"]) ?? "unknown"
            return .init(
                identity: .init(
                    sessionID: sessionID,
                    requestID: "PermissionRequest:\(agent):\(request)"))
        case "PreToolUse":
            guard
                let question = HostQuestionHookPayload.parse(
                    host: host,
                    nativeEvent: nativeEvent, data: data)
            else { return nil }
            return .init(
                identity: .init(
                    sessionID: sessionID,
                    requestID: "PreToolUse:" + question.requestID))
        case "SubagentStop":
            guard let name = object["agent_name"] as? String, !name.isEmpty,
                name.utf8.count <= 256, !HostEventSource.containsUnsafeScalar(name),
                object["response"] is String
            else { return nil }
            // Upstream emits this callback only after successful completion. There is no stable
            // child ID in 2.1.1; never alias two successful tasks by their display name.
            return .init(identity: nil)
        default: return nil
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
            !HostEventSource.containsUnsafeScalar(value), !value.contains(where: \.isWhitespace)
        else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue >= 0,
            number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}
