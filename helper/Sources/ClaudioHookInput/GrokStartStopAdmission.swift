import ClaudioCore
import Foundation

/// Grok start/stop admission stays at the CLI process boundary. Keeping it out of ClaudioCore
/// avoids linking helper-only payload fields into the GUI's size-sensitive executable.
public enum GrokStartStopAdmission {
    public static func source(
        nativeEvent: String, data: Data?, environment: [String: String]
    ) -> HostEventSource? {
        guard
            nativeEvent == "UserPromptSubmit" || nativeEvent == "Stop",
            let data, !data.isEmpty, data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data).isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        for key in [
            "hookEventName", "hook_event_name", "sessionId", "session_id", "cwd",
            "workspaceRoot", "workspace_root", "prompt", "promptId", "prompt_id", "reason",
        ] where object[key] != nil {
            guard object[key] is String else { return nil }
        }
        func string(_ key: String) -> String? { object[key] as? String }
        func identifier(_ key: String) -> String? {
            guard let value = string(key), !value.isEmpty, value.utf8.count <= 256,
                !containsUnsafeScalar(value),
                !value.contains(where: \.isWhitespace)
            else { return nil }
            return value
        }
        func path(_ key: String) -> String? {
            guard let value = string(key), WorkspaceDirectory.validPath(value) else { return nil }
            return value
        }
        func aliasedIdentifier(_ camel: String, _ snake: String) -> String? {
            let first = identifier(camel)
            let second = identifier(snake)
            guard first == nil || second == nil || first == second else { return nil }
            return first ?? second
        }
        func aliasedPath(_ camel: String, _ snake: String) -> String? {
            let first = path(camel)
            let second = path(snake)
            guard first == nil || second == nil || first == second else { return nil }
            return first ?? second
        }

        let token = nativeEvent == "UserPromptSubmit" ? "user_prompt_submit" : "stop"
        let camelEvent = string("hookEventName")
        let snakeEvent = string("hook_event_name")
        guard camelEvent != nil || snakeEvent != nil,
            camelEvent == nil || camelEvent == token,
            snakeEvent == nil || snakeEvent == nativeEvent,
            let session = aliasedIdentifier("sessionId", "session_id"),
            let cwd = path("cwd"),
            let workspace = aliasedPath("workspaceRoot", "workspace_root"),
            environment["GROK_HOOK_EVENT"] == token,
            let name = environment["GROK_HOOK_NAME"], !name.isEmpty, name.utf8.count <= 4096,
            !containsUnsafeScalar(name),
            let runnerSession = environment["GROK_SESSION_ID"],
            runnerSession == session,
            let runnerRoot = environment["GROK_WORKSPACE_ROOT"], runnerRoot == workspace
        else { return nil }

        for key in ["is_subagent", "subagent"] where object[key] != nil {
            guard object[key] is Bool else { return nil }
        }
        let child =
            object["subagentType"] != nil || object["subagent_type"] != nil
            || object["subagentId"] != nil || object["subagent_id"] != nil
            || object["agent_id"] != nil
            || (object["is_subagent"] as? Bool) == true || (object["subagent"] as? Bool) == true
        guard !child else { return nil }

        switch nativeEvent {
        case "UserPromptSubmit":
            guard let prompt = string("prompt"), !prompt.hasPrefix("<system-reminder>"),
                let promptID = aliasedIdentifier("promptId", "prompt_id"),
                UUID(uuidString: promptID) != nil
            else { return nil }
        case "Stop":
            guard string("reason") == "end_turn",
                let promptID = aliasedIdentifier("promptId", "prompt_id"), !promptID.isEmpty
            else { return nil }
            for key in ["backgroundTasks", "sessionCrons"] where object[key] != nil {
                guard object[key] is [Any] else { return nil }
            }
            let camel = object["stopHookActive"]
            let snake = object["stop_hook_active"]
            if camel != nil && !(camel is Bool) { return nil }
            if snake != nil && !(snake is Bool) { return nil }
            guard (camel as? Bool) != true, (snake as? Bool) != true,
                (camel as? Bool) == (snake as? Bool) || camel == nil || snake == nil
            else { return nil }
        default:
            return nil
        }

        let project = HostEventSourceParser.projectIdentity(from: cwd)
        let candidate = HostEventSource(
            projectLabel: project?.label, projectKey: project?.key, sessionID: session,
            mainSessionIsKnown: true)
        let source =
            candidate.isSemanticallyValid
            ? candidate
            : HostEventSource(projectLabel: nil, sessionID: session, mainSessionIsKnown: true)
        return source.isSemanticallyValid ? source : nil
    }

    private static func containsUnsafeScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let number = scalar.value
            return number <= 0x1F || number == 0x7F || (0x80...0x9F).contains(number)
                || [
                    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                    0x2066, 0x2067, 0x2068, 0x2069,
                ].contains(Int(number))
        }
    }
}
