import ClaudioCore
import Foundation

func grokBuildPayload(
    _ native: String, session: String = "grok-session", request: String = "request-1",
    overrides: [String: Any] = [:], removing: [String] = []
) -> Data {
    let promptID =
        native == "UserPromptSubmit" && UUID(uuidString: request) == nil
        ? "11111111-1111-4111-8111-111111111111" : request
    var object: [String: Any] = [
        "hookEventName": native == "StopFailure"
            ? "stop_failure"
            : native == "PreToolUse"
                ? "pre_tool_use"
                : native == "UserPromptSubmit" ? "user_prompt_submit" : native == "Stop" ? "stop"
                    : "notification",
        "hook_event_name": native, "sessionId": session, "session_id": session,
        "cwd": "/fixture/grok-project", "workspaceRoot": "/fixture/grok-project",
        "timestamp": "2026-10-21T00:00:00Z", "permissionMode": "default", "promptId": promptID,
    ]
    switch native {
    case "StopFailure": object["error"] = "server_error"; object["errorDetails"] = "PRIVATE_BODY"
    case "PreToolUse":
        object["toolName"] = "ask_user_question"; object["toolUseId"] = request
        object["toolInput"] = ["question": "PRIVATE_BODY"]; object["toolInputTruncated"] = false
    case "UserPromptSubmit":
        object["prompt"] = "fixture prompt"
    case "Stop":
        object["reason"] = "end_turn"
        object["stopHookActive"] = false
        object["stop_hook_active"] = false
        object["lastAssistantMessage"] = "OK"
        object["last_assistant_message"] = "OK"
        object["backgroundTasks"] = []
        object["sessionCrons"] = []
    default: object["notificationType"] = "permission_prompt"; object["message"] = "PRIVATE_BODY"
    }
    object.merge(overrides, uniquingKeysWith: { _, value in value })
    for key in removing { object.removeValue(forKey: key) }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func grokBuildRunnerEnvironment(_ native: String, session: String = "grok-session") -> [String:
    String]
{
    [
        "GROK_HOOK_EVENT": native == "StopFailure"
            ? "stop_failure"
            : native == "PreToolUse"
                ? "pre_tool_use"
                : native == "UserPromptSubmit" ? "user_prompt_submit" : native == "Stop" ? "stop"
                    : "notification",
        "GROK_HOOK_NAME": "claudio", "GROK_SESSION_ID": session,
        "GROK_WORKSPACE_ROOT": "/fixture/grok-project",
    ]
}

final class GrokBuildTestScope: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "grok-build-fixture-v1"
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

struct GrokBuildIntegrationFixture: Sendable {
    let root: URL
    let configurationRoot: URL
    let runtime: URL
    let receipts: HostHookReceiptStore
    let scope = GrokBuildTestScope()
    var file: URL { configurationRoot.appendingPathComponent("hooks/claudio.json") }
    var backupFile: URL { configurationRoot.appendingPathComponent("claudio-hooks.backup.json") }
    var legacyBackupFile: URL { file.appendingPathExtension("claudio.bak") }
    var helper: String { runtime.appendingPathComponent("bin/claudio").path }
    var adapter: GrokBuildIntegrationAdapter { .init(environment: environment()) }

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudio-grok-build-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        configurationRoot = root.appendingPathComponent("grok")
        runtime = root.appendingPathComponent(".claudio")
        receipts = HostHookReceiptStore(
            receiptsRoot: runtime.appendingPathComponent("receipts"),
            locksRoot: runtime.appendingPathComponent("receipt-locks"))
    }

    func environment(beforeFinalPublish: @escaping @Sendable () -> Void = {})
        -> AdditionalHostIntegrationEnvironment
    {
        .init(
            host: .grokBuild, configurationRoot: configurationRoot,
            claudioBinaryPath: helper, claudioRoot: runtime.path, receiptStore: receipts,
            scopeFingerprint: { [scope] in scope.value }, availability: { .available },
            beforeFinalPublish: beforeFinalPublish)
    }

    func write(_ data: Data, to file: URL? = nil) {
        let target = file ?? self.file
        try! FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: target)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Frozen v1 acceptance file for ordinary Release ownership/uninstall checks. The adapter
    /// is exercised through its public seam; a filename/marker or edited subset must not qualify.
    func acceptanceConfiguration(id: UUID) -> Data {
        let events: [(String, String?)] = [
            ("StopFailure", nil), ("Notification", "^permission_prompt$"),
            ("PreToolUse", "^(ask_user_question)$"), ("Stop", nil), ("UserPromptSubmit", nil),
        ]
        var hooks: [String: Any] = [:]
        for (event, matcher) in events {
            var group: [String: Any] = [
                "hooks": [
                    [
                        "type": "command", "timeout": 2,
                        "command":
                            "\(shellQuotedPath(helper)) hook grok-build \(event) --installation-id \(id.uuidString)",
                    ]
                ]
            ]
            group["matcher"] = matcher
            hooks[event] = [group]
        }
        var data = try! JSONSerialization.data(
            withJSONObject: ["hooks": hooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
}
