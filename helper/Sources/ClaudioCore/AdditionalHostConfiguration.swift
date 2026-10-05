import Foundation

/// The native schemas stay in this adapter module. Installation bytes are compared exactly;
/// a foreign or edited plugin/block is a conflict, never an overwrite authorization.
enum AdditionalHostConfiguration {
    struct Inspection {
        let state: HostConfigurationState
        let installationID: UUID?
        let helperPath: String?
        let ownedRange: Range<Int>?
    }

    private static let pluginHeader = "// Claudio managed OpenCode bridge v1\nconst installation = "
    private static let blockStart = "# >>> Claudio Kimi Code hooks v1"
    private static let blockEnd = "# <<< Claudio Kimi Code hooks v1"

    struct PluginInstallation: Codable {
        let installationID: UUID
        let helperPath: String
        let enabledEvents: [String]
        enum CodingKeys: String, CodingKey {
            case installationID = "installation_id"
            case helperPath = "helper_path"
            case enabledEvents = "enabled_events"
        }
    }

    static func render(
        host: HostID, installationID: UUID, helperPath: String,
        events: [String]? = nil
    ) throws -> Data {
        let bindings = HostCapabilityCatalog.bindings(for: host).filter {
            $0.isAudibleCapability && (events == nil || events!.contains($0.nativeEvent ?? ""))
        }
        if host == .opencode {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let config = PluginInstallation(
                installationID: installationID, helperPath: helperPath,
                enabledEvents: bindings.compactMap(\.nativeEvent))
            return Data(
                (pluginHeader + String(decoding: try encoder.encode(config), as: UTF8.self)
                    + ";\n" + OpenCodePluginSource.template).utf8)
        }
        var block = "\n\(blockStart)\n"
        for binding in bindings {
            guard let native = binding.nativeEvent,
                let command = hostIntegrationHookCommand(
                    host: host, nativeEvent: native,
                    installationID: installationID, claudioBinaryPath: helperPath)
            else { throw rejected("无法生成 Kimi Code 自有 hook") }
            block += "[[hooks]]\nevent = \(try quoted(native))\n"
            if native == "TurnStarted" { block += "matcher = \(try quoted("^user$"))\n" }
            if let trigger = HostQuestionTrigger.binding(host: host, nativeEvent: native) {
                block += "matcher = \(try quoted(trigger.matcher))\n"
            }
            block += "command = \(try quoted(command))\ntimeout = 2\n"
        }
        block += "\(blockEnd)\n"
        return Data(block.utf8)
    }

    static func inspect(
        host: HostID, data: Data?, helperPath: String,
        claudioRoot: String
    ) throws -> Inspection {
        guard let data, !data.isEmpty else {
            return .init(
                state: .notConfigured, installationID: nil, helperPath: nil, ownedRange: nil)
        }
        if host == .opencode {
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix(pluginHeader),
                let end = text.range(
                    of: ";\n",
                    range: text.index(
                        text.startIndex,
                        offsetBy: pluginHeader.count)..<text.endIndex),
                let json = text[
                    text.index(text.startIndex, offsetBy: pluginHeader.count)..<end.lowerBound
                ]
                .data(using: .utf8),
                let config = try? JSONDecoder().decode(PluginInstallation.self, from: json),
                config.helperPath.hasPrefix("/"),
                !HostEventSource.containsUnsafeScalar(config.helperPath),
                Set(config.enabledEvents).count == config.enabledEvents.count,
                config.enabledEvents.allSatisfy({
                    HostCapabilityCatalog.binding(
                        host: host,
                        nativeEvent: $0) != nil
                }),
                try render(
                    host: host, installationID: config.installationID,
                    helperPath: config.helperPath, events: config.enabledEvents) == data
            else {
                throw rejected("OpenCode 的 claudio.js 为第三方文件或已被修改，已拒绝覆盖／删除")
            }
            let expected = HostCapabilityCatalog.bindings(for: host).filter(\.isAudibleCapability)
                .compactMap(\.nativeEvent)
            let missing = expected.filter { !config.enabledEvents.contains($0) }
            return .init(
                state: utf8BytesEqual(config.helperPath, helperPath) && missing.isEmpty
                    ? .configured
                    : .incomplete(missingNativeEvents: missing.isEmpty ? expected : missing),
                installationID: config.installationID, helperPath: config.helperPath,
                ownedRange: 0..<data.count)
        }
        let document = try KimiCodeTOMLDocument(data: data)
        let starts = document.comments.filter { $0.text == blockStart }
        let ends = document.comments.filter { $0.text == blockEnd }
        if starts.isEmpty && ends.isEmpty {
            guard
                !document.hooks.contains(where: { hook in
                    if case .string(let command) = hook.fields["command"] {
                        return matchedHostHookCommand(
                            inHookCommand: command,
                            claudioRoot: claudioRoot)?.host == .kimiCode
                    }
                    return false
                })
            else { throw rejected("检测到托管块外的 Claudio Kimi Code hook，请先处理重复配置") }
            return .init(
                state: .notConfigured, installationID: nil, helperPath: nil, ownedRange: nil)
        }
        guard starts.count == 1, ends.count == 1, let start = starts.first, let end = ends.first,
            start.start > 0, data[start.start - 1] == 10, end.start > start.end
        else { throw rejected("Kimi Code 的 Claudio 托管标记损坏或重复，已拒绝写入") }
        let range = (start.start - 1)..<end.end
        let ownHooks = document.hooks.filter { range.contains($0.start) }
        let outsideHooks = document.hooks.filter { !range.contains($0.start) }
        guard
            !outsideHooks.contains(where: { hook in
                if case .string(let command) = hook.fields["command"] {
                    return matchedHostHookCommand(
                        inHookCommand: command,
                        claudioRoot: claudioRoot)?.host == .kimiCode
                }
                return false
            })
        else { throw rejected("检测到重复的 Claudio Kimi Code hook，已拒绝写入") }
        guard let first = ownHooks.first,
            case .string(let command) = first.fields["command"],
            let match = matchedHostHookCommand(inHookCommand: command, claudioRoot: claudioRoot),
            match.host == .kimiCode,
            let ownPath = commandPath(command: command, match: match),
            try render(
                host: host, installationID: match.installationID,
                helperPath: ownPath,
                events: ownHooks.compactMap {
                    if case .string(let name) = $0.fields["event"] { return name }; return nil
                }) == data.subdata(in: range)
        else { throw rejected("Kimi Code 的 Claudio 托管块已被修改，已拒绝覆盖／删除") }
        let installedEvents = ownHooks.compactMap { hook -> String? in
            if case .string(let name) = hook.fields["event"] { return name }; return nil
        }
        let expected = HostCapabilityCatalog.bindings(for: host).filter(\.isAudibleCapability)
            .compactMap(\.nativeEvent)
        let missing = expected.filter { !installedEvents.contains($0) }
        return .init(
            state: utf8BytesEqual(ownPath, helperPath) && missing.isEmpty
                ? .configured
                : .incomplete(missingNativeEvents: missing.isEmpty ? expected : missing),
            installationID: match.installationID, helperPath: ownPath, ownedRange: range)
    }

    static func connect(
        host: HostID, data: Data?, helperPath: String, claudioRoot: String,
        requestedID: UUID, reusableID: UUID?
    ) throws -> ConfigFileByteMutation<UUID> {
        guard helperPath.hasPrefix("/"), helperPath.utf8.count <= 4096,
            !HostEventSource.containsUnsafeScalar(helperPath),
            !binaryPathContradictsItsNamespace(helperPath)
        else {
            throw rejected("helper 路径无效，未写入来源配置")
        }
        let existing = try inspect(
            host: host, data: data, helperPath: helperPath,
            claudioRoot: claudioRoot)
        if existing.state == .configured, existing.installationID == reusableID,
            let reusableID
        {
            return .unchanged(reusableID)
        }
        let replacement = try render(
            host: host, installationID: requestedID, helperPath: helperPath)
        if host == .opencode { return .replace(replacement, requestedID) }
        var next = data ?? Data()
        if let range = existing.ownedRange { next.removeSubrange(range) }
        next.append(replacement)
        _ = try KimiCodeTOMLDocument(data: next)
        return .replace(next, requestedID)
    }

    static func disconnect(
        host: HostID, data: Data?, helperPath: String,
        claudioRoot: String
    ) throws -> ConfigFileByteMutation<Bool> {
        let existing = try inspect(
            host: host, data: data, helperPath: helperPath,
            claudioRoot: claudioRoot)
        guard let range = existing.ownedRange else { return .unchanged(false) }
        if host == .opencode { return .replace(nil, true) }
        var next = data ?? Data()
        next.removeSubrange(range)
        _ = try KimiCodeTOMLDocument(data: next)
        return .replace(next, true)
    }

    private static func commandPath(command: String, match: MatchedHostHookCommand) -> String? {
        // The matcher already verified an owned absolute path. Preserve its exact quoting.
        let suffix =
            " hook kimi-code \(match.nativeEvent) --installation-id \(match.installationID.uuidString)"
        guard command.hasSuffix(suffix) else { return nil }
        let prefix = String(command.dropLast(suffix.count))
        if prefix.hasPrefix("'"), prefix.hasSuffix("'") {
            return String(prefix.dropFirst().dropLast()).replacingOccurrences(
                of: "'\\''", with: "'")
        }
        return prefix
    }

    private static func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func rejected(_ reason: String) -> ConfigFileTransactionError {
        .mutationRejected(reason: reason)
    }
}
