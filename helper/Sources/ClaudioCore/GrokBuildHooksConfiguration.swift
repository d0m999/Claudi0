import Foundation

/// One dedicated native hook file. Only exact known Claudio templates establish ownership;
/// a marker, a filename, or a command substring never authorizes replacement or deletion.
enum GrokBuildHooksConfiguration {
    static func render(installationID: UUID, helperPath: String, events: [String]? = nil) throws
        -> Data
    {
        let bindings = HostCapabilityCatalog.bindings(for: .grokBuild).filter {
            if let events {
                return $0.isImplementedCapability && events.contains($0.nativeEvent ?? "")
            }
            return $0.isAudibleCapability
        }
        var hooks: [String: Any] = [:]
        for binding in bindings {
            guard let native = binding.nativeEvent else { continue }
            let matcher: String? =
                native == "Notification"
                ? "^permission_prompt$"
                : HostQuestionTrigger.binding(host: .grokBuild, nativeEvent: native)?.matcher
            var group: [String: Any] = [
                "hooks": [
                    [
                        "type": "command", "timeout": 2,
                        "command": canonicalHostIntegrationHookCommand(
                            host: .grokBuild, nativeEvent: native,
                            installationID: installationID, claudioBinaryPath: helperPath),
                    ]
                ]
            ]
            group["matcher"] = matcher
            hooks[native] = [group]
        }
        var result = try JSONSerialization.data(
            withJSONObject: ["hooks": hooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        result.append(10)
        return result
    }

    static func inspect(data: Data?, helperPath: String, claudioRoot: String) throws
        -> AdditionalHostConfiguration.Inspection
    {
        guard let data else {
            return .init(
                state: .notConfigured, installationID: nil, helperPath: nil, ownedRange: nil)
        }
        guard data.count <= 1 << 20,
            let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let hooks = document["hooks"] as? [String: Any],
            let groups = hooks.values.first as? [[String: Any]],
            let handlers = groups.first?["hooks"] as? [[String: Any]],
            let command = handlers.first?["command"] as? String,
            let match = matchedAdditionalHostConfigurationHookCommand(
                inHookCommand: command, claudioRoot: claudioRoot), match.host == .grokBuild,
            let path = Self.helperPath(in: command, match: match)
        else { throw conflict() }
        let installed = hooks.keys.sorted()
        let implemented = HostCapabilityCatalog.bindings(for: .grokBuild)
            .filter(\.isImplementedCapability).compactMap(\.nativeEvent).sorted()
        let admitted = HostCapabilityCatalog.bindings(for: .grokBuild)
            .filter(\.isAudibleCapability).compactMap(\.nativeEvent).sorted()
        // The full v1 acceptance template remains owned in ordinary Release, including when
        // no binding is admitted. Arbitrary edited subsets are never treated as our templates.
        guard installed == implemented || (!admitted.isEmpty && installed == admitted),
            try render(installationID: match.installationID, helperPath: path, events: installed)
                == data
        else { throw conflict() }
        return .init(
            state: utf8BytesEqual(path, helperPath) && installed == admitted
                ? .configured : .incomplete(missingNativeEvents: admitted),
            installationID: match.installationID, helperPath: path, ownedRange: 0..<data.count)
    }

    static func connect(
        data: Data?, helperPath: String, claudioRoot: String, requestedID: UUID, reusableID: UUID?
    ) throws -> ConfigFileByteMutation<UUID> {
        let existing = try inspect(data: data, helperPath: helperPath, claudioRoot: claudioRoot)
        if existing.state == .configured, existing.installationID == reusableID, let reusableID {
            return .unchanged(reusableID)
        }
        return .replace(
            try render(installationID: requestedID, helperPath: helperPath), requestedID)
    }

    static func disconnect(data: Data?, helperPath: String, claudioRoot: String) throws
        -> ConfigFileByteMutation<Bool>
    {
        let existing = try inspect(data: data, helperPath: helperPath, claudioRoot: claudioRoot)
        return existing.ownedRange == nil ? .unchanged(false) : .replace(nil, true)
    }

    private static func helperPath(in command: String, match: MatchedHostHookCommand) -> String? {
        let suffix =
            " hook grok-build \(match.nativeEvent) --installation-id \(match.installationID.uuidString)"
        guard command.hasSuffix(suffix) else { return nil }
        let word = String(command.dropLast(suffix.count))
        if word.hasPrefix("'"), word.hasSuffix("'") {
            return String(word.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        return word
    }

    private static func conflict() -> ConfigFileTransactionError {
        .mutationRejected(reason: "Grok Build 的 hooks/claudio.json 为外来文件或已被修改，已拒绝覆盖／删除")
    }
}
