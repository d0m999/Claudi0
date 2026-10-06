import ClaudioCore
import Foundation

@MainActor
func runAdditionalHostMigrationSuites() async {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let legacy = try! Data(contentsOf: tests.appendingPathComponent("Fixtures/opencode-3bf3840.js"))
    let current = try! Data(
        contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations/opencode/claudio.js"))
    for host in [HostID.opencode, .kimiCode] {
        let candidates =
            host == .opencode
            ? [
                "UserTurnStarted", "ResponseCompleted", "ResponseFailed", "PermissionRequested",
                "QuestionAsked", "SubagentCompleted",
            ]
            : ["TurnStarted", "PermissionRequest", "PreToolUse", "SubagentStop"]
        let expected =
            AdditionalHostReleasePolicy.isAcceptanceBuild
            ? candidates
            : (host == .opencode ? ["UserTurnStarted", "ResponseCompleted"] : ["TurnStarted"])
        let templates = host == .opencode ? [legacy, current] : [Data()]
        for (version, template) in templates.enumerated() {
            await asyncSuite("\(host.rawValue)：已知配置版本 \(version) 安全迁移及直接断开") {
                for (disconnectOnly, preserveBackup) in [
                    (false, false), (false, true), (true, true),
                ] {
                    let f = MigrationFixture(host: host)
                    defer { try? FileManager.default.removeItem(at: f.root) }
                    let id = UUID()
                    let original = f.configuration(events: candidates, id: id, template: template)
                    try! original.write(to: f.file)
                    expect(
                        f.receipts.activate(
                            host: host, installationID: id, scopeFingerprint: "migration-v1"
                        ).isMigrationSuccess,
                        "fixture 发布原安装身份")
                    let backup = Data("existing one-shot backup\r\n".utf8)
                    if preserveBackup { try! backup.write(to: f.backup) }
                    let before = await f.adapter.inspect(runtime: .ready)
                    expect(before.installationID == id, "旧自有配置仍可识别身份，不是第三方冲突")
                    if disconnectOnly {
                        let result = await f.adapter.disconnect(runtime: .ready)
                        expect(result.isMigrationSuccess, "旧自有配置可直接断开：\(result)")
                        expect(f.retainedThirdPartyBytes(), "断开仅移除旧自有配置")
                        expect(try! Data(contentsOf: f.backup) == backup, "直接断开保留已有备份")
                    } else {
                        let result = await f.adapter.connect(runtime: .ready)
                        expect(result.isMigrationSuccess, "旧自有配置可连接迁移：\(result)")
                        guard case .success(let snapshot) = result else { continue }
                        expect(snapshot.configuration == .configured, "迁移后完整配置")
                        let needsMigration =
                            (host == .opencode && version == 0) || candidates != expected
                        expect(
                            (snapshot.installationID != id) == needsMigration, "模板或准入集合变化须轮换安装身份")
                        let installed = try! Data(contentsOf: f.file)
                        if host == .opencode {
                            let text = String(decoding: installed, as: UTF8.self)
                            expect(
                                text.hasSuffix(String(decoding: current, as: UTF8.self)),
                                "迁移为当前默认导出模板")
                            let jsonLine = text.components(separatedBy: "\n")[1]
                            let json = Data(
                                jsonLine.dropFirst("const installation = ".count).dropLast().utf8)
                            let config =
                                try! JSONSerialization.jsonObject(with: json) as! [String: Any]
                            expect(
                                config["enabled_events"] as? [String] == expected, "只写当前构建允许的绑定集合")
                        } else {
                            let text = String(decoding: installed, as: UTF8.self)
                            let events = text.components(separatedBy: "\n").compactMap {
                                line -> String? in
                                guard line.hasPrefix("event = \"") else { return nil }
                                return String(line.dropFirst(9).dropLast())
                            }
                            expect(events == expected, "Kimi 迁移为当前构建允许的绑定集合")
                            expect(installed.starts(with: f.thirdParty), "迁移保留第三方 CRLF 和未知设置")
                        }
                        if preserveBackup {
                            expect(try! Data(contentsOf: f.backup) == backup, "迁移保留已有一次性备份")
                        } else if needsMigration {
                            expect(try! Data(contentsOf: f.backup) == original, "首次迁移备份精确旧文件")
                        }
                        let repeated = await f.adapter.connect(runtime: .ready)
                        expect(repeated.isMigrationSuccess, "迁移后重复连接成功")
                        if case .success(let next) = repeated {
                            expect(next.installationID == snapshot.installationID, "重复连接身份幂等")
                        }
                        expect(try! Data(contentsOf: f.file) == installed, "重复连接零字节变化")
                        expect(
                            (await f.adapter.disconnect(runtime: .ready)).isMigrationSuccess,
                            "迁移后可断开")
                        expect(f.retainedThirdPartyBytes(), "断开保留第三方配置")
                    }
                    expect(f.receipts.currentInstallationID(host: host) == nil, "断开撤销当前回调身份")
                    expect(
                        try! Data(contentsOf: f.protectedFile) == f.protectedOriginal,
                        "非托管文件和字段保留原字节")
                }
            }
        }

        await asyncSuite("\(host.rawValue)：已知但未准入的部分配置仍属于 Claudio") {
            let f = MigrationFixture(host: host)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let original = f.configuration(
                events: [candidates.last!], id: UUID(), template: current)
            try! original.write(to: f.file)
            expect(
                (await f.adapter.disconnect(runtime: .ready)).isMigrationSuccess,
                "不依赖首个事件的 Release 准入识别所有权")
            expect(f.retainedThirdPartyBytes(), "部分配置安全删除")
            if !AdditionalHostReleasePolicy.isAcceptanceBuild {
                expect(
                    HostCapabilityCatalog.binding(host: host, nativeEvent: candidates.last!) == nil,
                    "所有权兼容不开放未验收事件的运行准入")
                expect(
                    hostIntegrationHookCommand(
                        host: host, nativeEvent: candidates.last!, installationID: UUID(),
                        claudioBinaryPath: f.binary.path) == nil,
                    "公共命令生成仍关闭未准入事件")
                expect(
                    matchedHostHookCommand(
                        inHookCommand: f.binary.path + " hook " + host.rawValue + " "
                            + candidates.last! + " --installation-id " + UUID().uuidString,
                        claudioRoot: f.root.appendingPathComponent(".claudio").path) == nil,
                    "公共命令匹配仍关闭未准入事件")
            }
        }

        await asyncSuite("\(host.rawValue)：历史配置被修改或含未知事件时拒绝迁移及删除") {
            for invalidEvent in [false, true] {
                let f = MigrationFixture(host: host)
                defer { try? FileManager.default.removeItem(at: f.root) }
                let events =
                    invalidEvent ? [host == .opencode ? "InventedEvent" : "Stop"] : candidates
                var original = f.configuration(events: events, id: UUID(), template: legacy)
                if !invalidEvent {
                    original =
                        host == .opencode
                        ? original + Data("// edited\n".utf8)
                        : Data(
                            String(decoding: original, as: UTF8.self).replacingOccurrences(
                                of: "timeout = 2", with: "timeout = 30"
                            ).utf8)
                }
                try! original.write(to: f.file)
                let backup = Data("keep backup\n".utf8)
                try! backup.write(to: f.backup)
                expect(
                    !(await f.adapter.connect(runtime: .ready)).isMigrationSuccess, "修改或未知绑定不能获得所有权"
                )
                expect(
                    !(await f.adapter.disconnect(runtime: .ready)).isMigrationSuccess, "修改或未知绑定拒绝删除"
                )
                expect(try! Data(contentsOf: f.file) == original, "拒绝操作保持文件原字节")
                expect(try! Data(contentsOf: f.backup) == backup, "拒绝操作保持备份原字节")
            }
        }
    }

    await asyncSuite("Kimi：托管块外的未准入自有 hook 仍应拒绝为重复配置") {
        let f = MigrationFixture(host: .kimiCode)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let managed = f.configuration(events: ["TurnStarted"], id: UUID(), template: Data())
        let outside = String(
            decoding: f.configuration(events: ["SubagentStop"], id: UUID(), template: Data())
                .dropFirst(f.thirdParty.count), as: UTF8.self
        )
        .replacingOccurrences(of: "# >>> Claudio Kimi Code hooks v1\n", with: "")
        .replacingOccurrences(of: "# <<< Claudio Kimi Code hooks v1\n", with: "")
        let duplicate = managed + Data(outside.utf8)
        try! duplicate.write(to: f.file)
        expect(
            !(await f.adapter.connect(runtime: .ready)).isMigrationSuccess, "未准入绑定不能逃过重复自有 hook 检查")
        expect(!(await f.adapter.disconnect(runtime: .ready)).isMigrationSuccess, "重复配置拒绝删除")
        expect(try! Data(contentsOf: f.file) == duplicate, "重复自有配置保持原字节")
    }
}

extension Result {
    fileprivate var isMigrationSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private struct MigrationFixture {
    let host: HostID
    let root: URL
    let file: URL
    let binary: URL
    let receipts: HostHookReceiptStore
    let thirdParty = Data("# Vibe Island and unknown settings\r\n[future]\r\nkeep = true\r\n".utf8)
    let protectedFile: URL
    var protectedOriginal: Data {
        host == .opencode
            ? Data("// Vibe Island\n{\"plugin\":[\"vibe-island\"],\"future\":true}\n".utf8)
            : thirdParty
    }
    var backup: URL { file.appendingPathExtension("claudio.bak") }

    init(host: HostID) {
        self.host = host
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-migration-\(UUID())")
        let configurationRoot = root.appendingPathComponent(host.rawValue)
        file = AdditionalHostPaths.file(host: host, root: configurationRoot)
        binary = root.appendingPathComponent(".claudio/bin/claudio")
        receipts = HostHookReceiptStore(
            receiptsRoot: root.appendingPathComponent("receipts"),
            locksRoot: root.appendingPathComponent("locks"),
            installationsRoot: root.appendingPathComponent("installations"),
            installationLocksRoot: root.appendingPathComponent("installation-locks"))
        try! FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        protectedFile =
            host == .opencode ? configurationRoot.appendingPathComponent("opencode.jsonc") : file
        try! protectedOriginal.write(to: protectedFile)
    }

    var adapter: any HostIntegrationAdapter {
        let environment = AdditionalHostIntegrationEnvironment(
            host: host, configurationRoot: root.appendingPathComponent(host.rawValue),
            claudioBinaryPath: binary.path,
            claudioRoot: root.appendingPathComponent(".claudio").path,
            receiptStore: receipts, scopeFingerprint: { "migration-v1" },
            availability: { .available })
        return host == .opencode
            ? OpenCodeIntegrationAdapter(environment: environment)
            : KimiCodeIntegrationAdapter(environment: environment)
    }

    func configuration(events: [String], id: UUID, template: Data) -> Data {
        func quote(_ value: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        if host == .opencode {
            let config: [String: Any] = [
                "installation_id": id.uuidString, "helper_path": binary.path,
                "enabled_events": events,
            ]
            let json = try! JSONSerialization.data(
                withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
            return Data("// Claudio managed OpenCode bridge v1\nconst installation = ".utf8) + json
                + Data(";\n".utf8) + template
        }
        var block = "\n# >>> Claudio Kimi Code hooks v1\n"
        for event in events {
            block += "[[hooks]]\nevent = \(quote(event))\n"
            if event == "TurnStarted" { block += "matcher = \"^user$\"\n" }
            if event == "PreToolUse" { block += "matcher = \"^(AskUserQuestion)$\"\n" }
            block +=
                "command = \(quote(binary.path + " hook kimi-code " + event + " --installation-id " + id.uuidString))\ntimeout = 2\n"
        }
        return thirdParty + Data((block + "# <<< Claudio Kimi Code hooks v1\n").utf8)
    }

    func retainedThirdPartyBytes() -> Bool {
        host == .opencode
            ? !FileManager.default.fileExists(atPath: file.path)
            : (try! Data(contentsOf: file)) == thirdParty
    }
}
