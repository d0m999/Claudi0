import Foundation

/// Grok loads Claude-compatible settings by default. Those commands must stop before Claude
/// authorization, activity, deduplication, receipts, audio or notices. GROK_HOME alone is not origin.
public enum GrokBuildHookOrigin {
    public static func suppressesClaudeCallback(
        data: Data?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if ["GROK_HOOK_EVENT", "GROK_HOOK_NAME", "GROK_SESSION_ID", "GROK_WORKSPACE_ROOT"]
            .contains(where: { environment[$0] != nil })
        {
            return true
        }
        guard let data, data.count <= HookInputReader.defaultMaximumBytes,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        // Retain the guard if a compatibility launcher strips runner env. Claude's native
        // schema has neither the Grok event field nor this pair of common camelCase fields.
        return object["hookEventName"] != nil
            && (object["sessionId"] != nil || object["workspaceRoot"] != nil)
    }
}
