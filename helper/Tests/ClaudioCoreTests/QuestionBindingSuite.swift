import ClaudioCore
import Foundation

@MainActor
func runQuestionBindingSuites() {
    let rootPath = "/fixture/.claudio"
    let binary = rootPath + "/bin/claudio"
    let installationID = UUID()
    let trigger = HostQuestionTrigger.claudeCode
    let binding = trigger.capability

    suite("question binding: exact matcher, five events, stable existing identities") {
        expect(trigger.toolNames == ["AskUserQuestion"], "只允许已确认的精确工具")
        for name in [
            "AskUserQuestion", "AskUserQuestionMore", "askuserquestion", "mcp__AskUserQuestion",
        ] {
            let matches = name.range(of: trigger.matcher, options: .regularExpression) != nil
            expect(matches == (name == "AskUserQuestion"), "matcher 必须完整匹配工具名")
        }
        expect(
            HostCapabilityCatalog.bindings(host: .claudeCode, event: .notification).count == 2,
            "notification 必须保留两个独立绑定")
        expect(
            HostQuestionTrigger.binding(host: .codex, nativeEvent: "PreToolUse") == nil,
            "Codex 未过真实入口门槛")
        expect(
            HostQuestionTrigger.binding(host: .workBuddy, nativeEvent: "PreToolUse") == nil,
            "WorkBuddy Desktop 未过真实入口门槛")
        expect(
            HostCapabilityCatalog.binding(host: .claudeCode, nativeEvent: "Notification")?.id
                .rawValue
                == "claude-code:Notification:notification:none:v1", "旧绑定身份必须保持")
        expect(
            HostActivationScope.fingerprint(host: .claudeCode, hostVersion: "fixture")?
                .contains(binding.id.rawValue) == true, "新触发范围必须进入版本 scope")
    }

    suite("question configuration: missing, broad, duplicate and mixed-generation slots") {
        guard
            case .success(let canonical) = connectClaudeCodeHooks(
                root: [:], claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: installationID)
        else { expect(false, "canonical fixture"); return }
        let hooks = canonical.root["hooks"] as! [String: Any]
        let slot = (hooks["PreToolUse"] as! [[String: Any]])[0]
        expect(slot["matcher"] as? String == trigger.matcher, "安装精确槽位")
        for matcher in [nil, "", ".*", "AskUserQuestion", "^askuserquestion$"] as [String?] {
            var badSlot = slot
            badSlot["matcher"] = matcher
            var badHooks = hooks
            badHooks["PreToolUse"] = [badSlot]
            let bad: [String: Any] = ["hooks": badHooks]
            if case .success(.conflict) = inspectClaudeCodeHooks(
                root: bad, claudioRoot: rootPath, claudioBinaryPath: binary)
            {
            } else {
                expect(false, "非精确 matcher 不能显示 configured")
            }
            guard
                case .success(let repaired) = connectClaudeCodeHooks(
                    root: bad, claudioRoot: rootPath, claudioBinaryPath: binary,
                    installationID: UUID())
            else { expect(false, "精确修复必须成功"); continue }
            if case .success(.configured) = inspectClaudeCodeHooks(
                root: repaired.root, claudioRoot: rootPath, claudioBinaryPath: binary)
            {
            } else {
                expect(false, "修复后完整")
            }
            if case .success(let repeated) = connectClaudeCodeHooks(
                root: repaired.root, claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: UUID())
            {
                expect(!repeated.changed, "修复必须幂等")
            }
        }
        for differentID in [false, true] {
            var duplicate = slot
            if differentID {
                duplicate["hooks"] = [
                    [
                        "type": "command",
                        "command": hostIntegrationHookCommand(
                            host: .claudeCode, nativeEvent: "PreToolUse", installationID: UUID(),
                            claudioBinaryPath: binary)!,
                    ]
                ]
            }
            var badHooks = hooks
            badHooks["PreToolUse"] = [slot, duplicate]
            if case .success(.conflict) = inspectClaudeCodeHooks(
                root: ["hooks": badHooks], claudioRoot: rootPath, claudioBinaryPath: binary)
            {
            } else {
                expect(false, "重复或混代槽位必须冲突")
            }
        }
        var upgradeHooks = hooks
        upgradeHooks.removeValue(forKey: "PreToolUse")
        guard
            case .success(let upgrade) = connectClaudeCodeHooks(
                root: ["hooks": upgradeHooks], claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: UUID())
        else { expect(false, "旧五绑定可修复"); return }
        expect(
            inspectClaudeCodeHooks(
                root: upgrade.root, claudioRoot: rootPath,
                claudioBinaryPath: binary) == .success(.configured(installationID: installationID)),
            "纯配置补槽保留唯一代次；adapter scope 变更另行轮换")
    }

    suite("question configuration: preserve third-party hooks and opaque extensions") {
        let command = hostIntegrationHookCommand(
            host: .claudeCode, nativeEvent: "PreToolUse",
            installationID: installationID, claudioBinaryPath: binary)!
        let thirdParty: [String: Any] = ["type": "command", "command": "printf third", "opaque": 7]
        let original: [String: Any] = [
            "future": ["enabled": true],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": ".*", "futureGroup": ["flag": true],
                        "hooks": [
                            ["type": "command", "command": command, "futureEntry": "keep"]
                        ],
                    ],
                    ["matcher": trigger.matcher, "hooks": [thirdParty]],
                ],
                "FutureEvent": [["future": true, "hooks": [thirdParty]]],
            ],
        ]
        guard
            case .success(let repaired) = connectClaudeCodeHooks(
                root: original, claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: installationID)
        else { expect(false, "repair fixture"); return }
        let hooks = repaired.root["hooks"] as! [String: Any]
        let groups = hooks["PreToolUse"] as! [[String: Any]]
        expect((repaired.root["future"] as? [String: Bool]) == ["enabled": true], "顶层未知字段保留")
        expect(groups.allSatisfy { $0["matcher"] as? String == trigger.matcher }, "仅改自有宽泛槽位")
        expect(groups.contains { $0["futureGroup"] != nil }, "自有 group 扩展保留")
        expect(
            groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .contains { $0["futureEntry"] as? String == "keep" }, "自有 entry 扩展保留")
        guard
            case .success(let disconnected) = disconnectClaudeCodeHooks(
                root: repaired.root, claudioRoot: rootPath)
        else { expect(false, "disconnect fixture"); return }
        let remaining = disconnected.root["hooks"] as! [String: Any]
        let entries = (remaining["PreToolUse"] as! [[String: Any]])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        expect(
            entries.count == 1 && entries[0]["command"] as? String == "printf third",
            "断开只移除自有提问 callback")
        expect(remaining["FutureEvent"] != nil, "未来事件保留")
    }

    suite("question configuration: legacy play under PreToolUse is not owned by this migration") {
        let legacy = claudioHookCommand(for: .notification, claudioBinaryPath: binary)
        let original: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "CustomTool", "hooks": [["type": "command", "command": legacy]],
                    ]
                ]
            ]
        ]
        guard
            case .success(let connected) = connectClaudeCodeHooks(
                root: original, claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: installationID)
        else { expect(false, "connect fixture"); return }
        let hooks = connected.root["hooks"] as! [String: Any]
        let groups = hooks["PreToolUse"] as! [[String: Any]]
        expect(
            groups.contains { group in
                group["matcher"] as? String == "CustomTool"
                    && (group["hooks"] as? [[String: Any]])?.first?["command"] as? String == legacy
            }, "新入口不能扩大旧安装器的legacy删除范围")
    }

    suite("question activation: old notification never activates a new reminder") {
        let previous = HostCapabilityCatalog.binding(
            host: .claudeCode, nativeEvent: "Notification")!
        func evidence(_ value: HostCapabilityBinding) -> HostActivationEvidence {
            .observed(
                HostReceiptEvidence(
                    bindingID: value.id, installationID: installationID,
                    nativeEvent: value.nativeEvent!, event: value.event, timestamp: Date(),
                    playbackResult: .muted))
        }
        func snapshot(_ activations: [HostEventBindingID: HostActivationEvidence])
            -> HostIntegrationSnapshot
        {
            HostIntegrationSnapshot(
                host: .claudeCode, runtime: .ready, availability: .available,
                configuration: .configured, writability: .writable, activation: evidence(previous),
                bindingActivations: activations, installationID: installationID)
        }
        let old = snapshot([previous.id: evidence(previous)])
        expect(
            old.activation(for: binding) == .awaitingReceipt(installationID: installationID),
            "旧通知或授权回执不能激活提问")
        let coverage = Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) })
        func matrix(_ value: HostIntegrationSnapshot) -> AudibilityMatrix {
            AudibilityMatrix.make(
                snapshots: [value],
                capabilities: [.claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode)],
                soundCoverage: coverage, enabledEvents: coverage)
        }
        expect(matrix(old).summary(for: .claudeCode) == .ready(supported: 5, total: 5), "仍为5/5")
        expect(
            matrix(old).cell(host: .claudeCode, event: .notification)?.state == .awaitingActivation,
            "新增提问未验证时聚合格保持待验证")
        let current = snapshot([previous.id: evidence(previous), binding.id: evidence(binding)])
        expect(
            matrix(current).cell(host: .claudeCode, event: .notification)?.state == .audible,
            "两个类型各有当前回执才激活聚合格")
        expect(
            matrix(current).cell(host: .claudeCode, event: .notification)?.bindings.count == 2,
            "聚合格保留所有类型事实")
    }
}
