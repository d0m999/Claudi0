import ClaudioCore
import ClaudioHookInput
import Foundation

@MainActor
func runGrokBuildHookSuites() {
    suite("Grok Build：原生合同、camel/snake 别名和有界输入") {
        for native in ["StopFailure", "Notification", "PreToolUse"] {
            let payload = GrokBuildHookPayload.parse(
                nativeEvent: native, data: grokBuildPayload(native))
            expect(payload?.sessionID == "grok-session", "合法 \(native) 保留不透明会话身份")
            expect(
                payload?.matchesRunner(
                    nativeEvent: native, environment: grokBuildRunnerEnvironment(native)) == true,
                "核对 runner 注入身份")
            expect(
                payload?.matchesRunner(nativeEvent: native, environment: [:]) == false,
                "缺少 runner 身份拒收")
            expect(
                payload?.matchesRunner(
                    nativeEvent: native,
                    environment: grokBuildRunnerEnvironment(native, session: "other")) == false,
                "runner 会话不一致拒收")
            for data in [
                nil, Data(), Data("[]".utf8), Data("{".utf8), Data(repeating: 32, count: 65_537),
            ] as [Data?] {
                expect(
                    GrokBuildHookPayload.parse(nativeEvent: native, data: data) == nil, "有界非法输入拒收")
            }
            for fields in [
                ["hookEventName": native], ["hook_event_name": "Other"], ["sessionId": false],
                ["session_id": "different"], ["workspace_root": "/different"], ["cwd": "relative"],
                ["workspaceRoot": []], ["promptId": true], ["prompt_id": "different"],
                ["toolInputTruncated": 1], ["tool_input": "PRIVATE_BODY"],
                ["subagentType": NSNull()],
                ["tool_name": false], ["permissionMode": []], ["sessionId": "two words"],
                ["sessionId": "unsafe\u{202E}"], ["cwd": "/unsafe\npath"],
            ] as [[String: Any]] {
                expect(
                    GrokBuildHookPayload.parse(
                        nativeEvent: native, data: grokBuildPayload(native, overrides: fields))
                        == nil, "字段类型与别名冲突拒收")
            }
            let valid = String(decoding: grokBuildPayload(native), as: UTF8.self)
            let duplicate = valid.replacingOccurrences(
                of: "\"sessionId\":", with: "\"sessionId\":\"other\",\"session\\u0049d\":")
            expect(
                GrokBuildHookPayload.parse(nativeEvent: native, data: Data(duplicate.utf8)) == nil,
                "转义后的重复键也拒收")
            let snakeOnly = grokBuildPayload(
                native, overrides: ["workspace_root": "/fixture/grok-project"],
                removing: ["sessionId", "workspaceRoot", "hookEventName"])
            expect(
                GrokBuildHookPayload.parse(nativeEvent: native, data: snakeOnly) != nil,
                "一致的 snake common 字段保持兼容")
        }
        for error in [
            "rate_limit", "authentication_failed", "invalid_request", "server_error",
            "max_output_tokens", "unknown",
        ] {
            expect(
                GrokBuildHookPayload.parse(
                    nativeEvent: "StopFailure",
                    data: grokBuildPayload("StopFailure", overrides: ["error": error])) != nil,
                "仅 API 错误类 \(error)")
        }
        for fields in [
            ["subagentType": "explore"], ["subagent_type": "explore"], ["is_subagent": true],
            ["error": "permission_rejected"], ["error": false],
        ] as [[String: Any]] {
            expect(
                GrokBuildHookPayload.parse(
                    nativeEvent: "StopFailure",
                    data: grokBuildPayload("StopFailure", overrides: fields)) == nil,
                "子会话与取消不映射执行中断")
        }
        for type in [
            "idle_prompt", "task_complete", "auth_success", "permission_denied", "unknown",
        ] {
            expect(
                GrokBuildHookPayload.parse(
                    nativeEvent: "Notification",
                    data: grokBuildPayload("Notification", overrides: ["notificationType": type]))
                    == nil, "只接收真实授权等待")
        }
        for mode in ["bypassPermissions", "unknown"] {
            expect(
                GrokBuildHookPayload.parse(
                    nativeEvent: "Notification",
                    data: grokBuildPayload("Notification", overrides: ["permissionMode": mode]))
                    == nil, "自动答复或未知授权模式不能制造需要你")
        }
        expect(
            GrokBuildHookPayload.parse(
                nativeEvent: "Notification",
                data: grokBuildPayload("Notification", removing: ["permissionMode"])) == nil,
            "缺少授权模式不能确认用户等待")
        for tool in [
            "AskUserQuestion", "ask_user_question ", "other_ask_user_question",
            "server__ask_user_question",
        ] {
            expect(
                GrokBuildHookPayload.parse(
                    nativeEvent: "PreToolUse",
                    data: grokBuildPayload("PreToolUse", overrides: ["toolName": tool])) == nil,
                "精确内置提问工具")
        }
        expect(
            GrokBuildHookPayload.parse(
                nativeEvent: "StopFailure",
                data: grokBuildPayload("StopFailure", removing: ["promptId"])) == nil,
            "错误需 prompt 身份")
        expect(
            GrokBuildHookPayload.parse(
                nativeEvent: "PreToolUse",
                data: grokBuildPayload("PreToolUse", removing: ["toolUseId"])) == nil, "提问需 tool 身份"
        )
    }

    suite("Grok Build：开始结束来源复用 parser 的项目显示身份") {
        for native in ["UserPromptSubmit", "Stop"] {
            for cwd in [
                "/fixture/grok-project", "/fixture/中文项目", "/first/shared", "/second/shared", "/",
                "/fixture/  safe   name ", "/fixture/" + String(repeating: "中", count: 150),
            ] {
                let source = GrokStartStopAdmission.source(
                    nativeEvent: native, data: grokBuildPayload(native, overrides: ["cwd": cwd]),
                    environment: grokBuildRunnerEnvironment(native))
                let expected = HostEventSourceParser.parseInput(
                    host: .grokBuild, nativeEvent: "StopFailure",
                    data: grokBuildPayload("StopFailure", overrides: ["cwd": cwd])
                ).source.source
                expect(source != nil, "合法 cwd 保留开始结束准入")
                expect(source?.projectLabel == expected?.projectLabel, "Grok 标签遵守统一安全截断与规范化")
                expect(source?.projectKey == expected?.projectKey, "Grok 项目 key 与 parser 同完整路径摘要一致")
            }
            let first = GrokStartStopAdmission.source(
                nativeEvent: native,
                data: grokBuildPayload(native, overrides: ["cwd": "/first/shared"]),
                environment: grokBuildRunnerEnvironment(native))
            let second = GrokStartStopAdmission.source(
                nativeEvent: native,
                data: grokBuildPayload(native, overrides: ["cwd": "/second/shared"]),
                environment: grokBuildRunnerEnvironment(native))
            expect(first?.projectKey != second?.projectKey, "同 basename 不混淆不同项目")
        }
    }

    suite("Grok Build：Claude compatibility 与旧 play 来源防护") {
        expect(
            !GrokBuildHookOrigin.suppressesClaudeCallback(
                data: nil, environment: ["GROK_HOME": "/somewhere"]), "GROK_HOME 本身不表示调用来源")
        for key in ["GROK_HOOK_EVENT", "GROK_HOOK_NAME", "GROK_SESSION_ID", "GROK_WORKSPACE_ROOT"] {
            expect(
                GrokBuildHookOrigin.suppressesClaudeCallback(data: nil, environment: [key: ""]),
                "异常 runner 身份也不能误标 Claude")
        }
        expect(
            GrokBuildHookOrigin.suppressesClaudeCallback(
                data: grokBuildPayload("Notification"), environment: [:]),
            "丢失 runner env 的兼容 payload 也拦截")
        expect(
            !GrokBuildHookOrigin.suppressesClaudeCallback(
                data: Data(
                    #"{"hook_event_name":"Stop","session_id":"claude","cwd":"/project"}"#.utf8),
                environment: [:]), "正常 Claude schema 保持行为")
        let f = GrokBuildHookFixture()
        defer { f.cleanup() }
        _ = f.receipts.activate(host: .claudeCode, installationID: f.id, scopeFingerprint: f.scope)
        for environment in [grokBuildRunnerEnvironment("StopFailure"), [:]] {
            let result = f.handle("StopFailure", host: .claudeCode, environment: environment)
            expect(result == nil, "共享处理器也拦截兼容加载")
        }
        expect(f.spawner.calls.isEmpty && f.notices.values.isEmpty, "兼容加载零播放零提示")
        expect(f.receipts.receiptHistory(host: .claudeCode, now: f.now).isEmpty, "不误写 Claude 回执")
        expect(!FileManager.default.fileExists(atPath: f.summary.path), "不写 Claude 活动")
    }

    guard AdditionalHostReleasePolicy.isAcceptanceBuild else { return }
    suite("Grok Build：五条绑定分别留回执、原因和脱敏来源；提问使用默认组") {
        for (native, event, reason) in [
            ("StopFailure", Event.stopFailure, nil),
            ("Notification", .notification, HostEventNoticeReason.permission),
            ("PreToolUse", .notification, .questionIntent),
            ("UserPromptSubmit", .taskStart, nil),
            ("Stop", .stop, nil),
        ] {
            let f = GrokBuildHookFixture()
            let result = f.handle(native)
            expect(
                result?.event == event && result?.playbackResult == .played, "合法 \(native) 走公共事件")
            expect(
                result?.receiptWritten == true && result?.activityRecordOutcome == .committed,
                "合法 callback 独立记录回执与活动")
            let notice = f.notices.values.last
            expect(notice?.surface == .grokBuild && notice?.reason == reason, "独立来源与提示语义")
            expect(
                notice?.source?.sessionID == "grok-session"
                    && notice?.source?.projectLabel == "grok-project", "只投影安全来源")
            expect(f.spawner.calls.count == 1, "\(native) 独立播放，不被其他事件去抖")
            for file in [f.summary, f.dedup.stateFile]
            where FileManager.default.fileExists(atPath: file.path) {
                let bytes = try! Data(contentsOf: file)
                expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE_BODY"), "正文不持久化")
                expect(!String(decoding: bytes, as: UTF8.self).contains("grok-session"), "身份只留摘要")
            }
            f.cleanup()
        }
    }

    suite("Grok Build：结束使用已验收工作区，提问意图仍用默认组") {
        let f = GrokBuildHookFixture()
        let workspace = f.root.appendingPathComponent("workspace")
        try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
        config.workspaceRules = [
            WorkspaceSoundRule(
                directory: .init(kind: .directory, path: workspace.path),
                surfaces: [.grokBuild],
                profile: .init(selectedPack: "work", volume: 0.9))
        ]
        try! JSONEncoder().encode(config).write(to: f.config)
        let packs = f.root.appendingPathComponent("packs")
        let work = packs.appendingPathComponent("work")
        try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let events = Dictionary(
            uniqueKeysWithValues: Event.allCases.map { ($0.cliName, "work.aiff") })
        try! JSONSerialization.data(withJSONObject: [
            "id": "work", "name": "Work", "events": events,
        ]).write(to: work.appendingPathComponent("manifest.json"))
        try! Data("work".utf8).write(to: work.appendingPathComponent("work.aiff"))
        var environment = grokBuildRunnerEnvironment("StopFailure")
        environment["GROK_WORKSPACE_ROOT"] = workspace.path
        let stop = f.handle(
            "StopFailure",
            data: grokBuildPayload(
                "StopFailure", overrides: ["cwd": workspace.path, "workspaceRoot": workspace.path]),
            environment: environment)
        expect(stop?.playbackResult == .played, "结束使用工作区规则")
        expect(
            f.spawner.calls.last?.contains { $0.contains("/packs/work/") } == true,
            "工作区包参与播放路径")
        var questionEnvironment = grokBuildRunnerEnvironment("PreToolUse")
        questionEnvironment["GROK_WORKSPACE_ROOT"] = workspace.path
        let question = f.handle(
            "PreToolUse",
            data: grokBuildPayload(
                "PreToolUse", request: "question-1",
                overrides: ["cwd": workspace.path, "workspaceRoot": workspace.path]),
            environment: questionEnvironment)
        expect(question?.playbackResult == .played, "提问意图仍可播放")
        expect(
            f.spawner.calls.last?.contains { $0.contains("/packs/default/") } == true,
            "提问意图固定使用默认组")
        f.cleanup()
    }

    suite("Grok Build：错误按 session+prompt、提问按 session+tool 去重；授权沿用通知去抖") {
        for native in ["StopFailure", "PreToolUse"] {
            let f = GrokBuildHookFixture()
            defer { f.cleanup() }
            expect(f.handle(native)?.playbackResult == .played, "首次请求播放")
            expect(f.handle(native)?.playbackResult == .debounced, "重复请求不播放")
            expect(f.notices.values.count == 1, "重复请求不产生横幅")
            expect(
                f.handle(native, data: grokBuildPayload(native, request: "request-2"))?
                    .playbackResult == .played, "不同请求独立")
            expect(
                f.handle(
                    native, data: grokBuildPayload(native, session: "other"),
                    environment: grokBuildRunnerEnvironment(native, session: "other"))?
                    .playbackResult == .played, "不同会话独立")
            expect(f.spawner.calls.count == 3, "同一毫秒的不同请求不能互相吞掉")
        }
        let f = GrokBuildHookFixture()
        defer { f.cleanup() }
        expect(f.handle("Notification")?.playbackResult == .played, "授权通知首次播放")
        expect(f.handle("Notification")?.playbackResult == .debounced, "无请求 ID 的授权通知走时间去抖")
        expect(!FileManager.default.fileExists(atPath: f.dedup.stateFile.path), "不编造授权请求身份")
        for native in ["UserPromptSubmit", "Stop"] {
            let f = GrokBuildHookFixture()
            expect(f.handle(native)?.playbackResult == .played, "\(native) 首次播放")
            expect(f.handle(native)?.playbackResult == .debounced, "\(native) 共享时间去抖")
            f.cleanup()
        }
    }

    suite("Grok Build：拒收、旧代次、关闭与 GUI 退出不消费身份和提示") {
        let f = GrokBuildHookFixture()
        defer { f.cleanup() }
        for native in [
            "SubagentStop", "StopCancelled", "PermissionDenied", "PostToolUseFailure",
        ] {
            expect(f.handle(native) == nil, "未实现事件在副作用前拒收")
        }
        for (native, overrides) in [
            ("UserPromptSubmit", ["promptId": "task-completed-11111111-1111-4111-8111-111111111111"]),
            ("UserPromptSubmit", ["prompt": "<system-reminder>\nwake</system-reminder>"]),
            ("UserPromptSubmit", ["promptId": "request-1"]),
            ("UserPromptSubmit", ["prompt": []]),
            ("Stop", ["reason": "shutdown"]),
            ("Stop", ["reason": false]),
            ("Stop", ["stopHookActive": true, "stop_hook_active": true]),
            ("Stop", ["stopHookActive": 1]),
            ("Stop", ["backgroundTasks": "none"]),
            ("Stop", ["sessionCrons": false]),
            ("UserPromptSubmit", ["subagentType": "explore"]),
            ("Stop", ["subagentType": "explore"]),
        ] as [(String, [String: Any])] {
            expect(
                f.handle(native, data: grokBuildPayload(native, overrides: overrides)) == nil,
                "合成唤醒、会话关闭与被阻止的结束在副作用前拒收")
        }
        expect(
            f.handle("Stop", data: grokBuildPayload("Stop", removing: ["promptId"])) == nil,
            "无 turn 身份的结束拒收")
        expect(
            f.handle(
                "UserPromptSubmit",
                data: grokBuildPayload("UserPromptSubmit", removing: ["prompt"])) == nil,
            "开始需有界 prompt")
        expect(
            f.handle(
                "StopFailure",
                data: grokBuildPayload("StopFailure", overrides: ["subagentType": "explore"]))
                == nil, "子会话错误拒收")
        expect(
            f.handle(
                "Notification",
                data: grokBuildPayload(
                    "Notification", overrides: ["notificationType": "idle_prompt"])) == nil,
            "普通 idle 拒收")
        expect(f.handle("PreToolUse", environment: [:]) == nil, "未绑定 runner 身份拒收")
        expect(f.handle("UserPromptSubmit", environment: [:]) == nil, "开始缺少 runner 身份拒收")
        expect(f.handle("Stop", environment: [:]) == nil, "结束缺少 runner 身份拒收")
        expect(f.handle("PreToolUse", id: UUID())?.playbackResult == .notReady, "旧安装不播放")
        expect(f.spawner.calls.isEmpty && f.notices.values.isEmpty, "拒收无播放和提示")
        expect(!FileManager.default.fileExists(atPath: f.dedup.stateFile.path), "拒收不消费身份")
        expect(!FileManager.default.fileExists(atPath: f.summary.path), "拒收不写活动")
        let intents = HostIntegrationIntentStore(
            configFile: f.config, lockFile: f.root.appendingPathComponent("config.lock"))
        let runs = HostGUIRunRegistry(
            file: f.root.appendingPathComponent("gui-run.json"),
            authorizationLockFile: intents.authorizationLockFile)
        let authorization = HostEventAuthorization(intents: intents, runs: runs)
        _ = intents.setEnabled(surface: .grokBuild, enabled: true)
        let run = try! runs.register().get()
        _ = intents.setEnabled(surface: .grokBuild, enabled: false)
        expect(f.handle("PreToolUse", authorization: authorization) == nil, "OFF 拒收")
        _ = intents.setEnabled(surface: .grokBuild, enabled: true)
        _ = runs.revoke(runID: run.runID)
        expect(f.handle("PreToolUse", authorization: authorization) == nil, "GUI 退出拒收")
        expect(!FileManager.default.fileExists(atPath: f.dedup.stateFile.path), "暂停期间不消费和补播")
    }

    suite("Grok Build：事件静音和动态静默消费请求，恢复不补播") {
        let f = GrokBuildHookFixture()
        defer { f.cleanup() }
        var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
        config.eventsEnabled = [
            "notification": false, "stop_failure": false, "task_start": false, "stop": false,
        ]
        try! JSONEncoder().encode(config).write(to: f.config)
        for native in ["StopFailure", "PreToolUse", "UserPromptSubmit"] {
            expect(f.handle(native)?.playbackResult == .muted, "事件开关抑制对应声音")
        }
        config.eventsEnabled = [:]
        try! JSONEncoder().encode(config).write(to: f.config)
        for native in ["StopFailure", "PreToolUse", "UserPromptSubmit"] {
            expect(f.handle(native)?.playbackResult == .debounced, "恢复开关不补播旧请求")
        }
        let stopOnly = GrokBuildHookFixture()
        var stopConfig = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
        stopConfig.eventsEnabled = ["stop": false]
        try! JSONEncoder().encode(stopConfig).write(to: stopOnly.config)
        expect(stopOnly.handle("Stop")?.playbackResult == .muted, "结束事件开关独立生效")
        expect(stopOnly.spawner.calls.isEmpty, "结束静音不启动播放器")
        stopOnly.cleanup()
        let quiet = GrokBuildHookFixture()
        let publisher = DynamicQuietSnapshotPublisher(
            snapshotFile: quiet.play.dynamicQuietEnvironment.snapshotFile,
            revisionStateFile: quiet.play.dynamicQuietEnvironment.revisionStateFile)
        _ = publisher.publish(focusActive: true, now: quiet.now)
        for native in ["StopFailure", "PreToolUse", "UserPromptSubmit"] {
            expect(
                quiet.handle(native, data: grokBuildPayload(native, request: "quiet"))?
                    .playbackResult == .muted, "静默覆盖原生事件")
        }
        _ = publisher.publish(focusActive: false, now: quiet.now)
        for native in ["StopFailure", "PreToolUse", "UserPromptSubmit"] {
            expect(
                quiet.handle(native, data: grokBuildPayload(native, request: "quiet"))?
                    .playbackResult == .debounced, "静默恢复不补播")
        }
        expect(f.spawner.calls.isEmpty && quiet.spawner.calls.isEmpty, "静音与静默期间无播放器")
        quiet.cleanup()
    }
}

private struct GrokBuildHookFixture {
    let root: URL
    let receipts: HostHookReceiptStore
    let id = UUID()
    let scope = "grok-hook-v1"
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let spawner = GrokBuildTestSpawner()
    let notices = HostEventNoticeCollector()
    let config: URL
    let summary: URL
    let dedup: HostQuestionDeduplicationStore
    let play: PlayEnvironment

    @MainActor init() {
        let f = GrokBuildIntegrationFixture()
        root = f.root; receipts = f.receipts
        config = root.appendingPathComponent("config.json")
        summary = root.appendingPathComponent("summary.json")
        f.write(
            Data(#"{"selected_pack":"default","master_volume":0.17,"events":{}}"#.utf8), to: config)
        let packs = root.appendingPathComponent("packs")
        let pack = packs.appendingPathComponent("default")
        let events = Dictionary(
            uniqueKeysWithValues: Event.allCases.map { ($0.cliName, "tone.aiff") })
        f.write(
            try! JSONSerialization.data(withJSONObject: [
                "id": "default", "name": "Default", "events": events,
            ]), to: pack.appendingPathComponent("manifest.json"))
        f.write(Data("sound".utf8), to: pack.appendingPathComponent("tone.aiff"))
        let moment = now
        play = PlayEnvironment(
            surfaceID: .grokBuild, lockFile: root.appendingPathComponent("play.lock"),
            configFile: config, userPacksDirectory: packs, spawner: spawner,
            debounceStateFile: root.appendingPathComponent("play.state"), now: { moment },
            logFile: root.appendingPathComponent("claudio.log"),
            logLockFile: root.appendingPathComponent("log.lock"))
        dedup = .init(
            directory: root.appendingPathComponent("requests"),
            lockFile: root.appendingPathComponent("requests.lock"))
        _ = receipts.activate(host: .grokBuild, installationID: id, scopeFingerprint: scope)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func handle(
        _ native: String, data: Data? = nil, host: HostID = .grokBuild, id: UUID? = nil,
        environment: [String: String]? = nil, authorization: HostEventAuthorization? = nil
    ) -> HostHookHandlingOutcome? {
        let payload = data ?? grokBuildPayload(native)
        let sourceEnvironment = environment ?? grokBuildRunnerEnvironment(native)
        let isGrokStartStop =
            host == .grokBuild && (native == "UserPromptSubmit" || native == "Stop")
        let grokSource =
            isGrokStartStop
            ? GrokStartStopAdmission.source(
                nativeEvent: native, data: payload, environment: sourceEnvironment)
            : nil
        if isGrokStartStop, grokSource == nil { return nil }
        return handleHostHook(
            host: host, nativeEvent: native, installationID: id ?? self.id,
            environment: HostHookEnvironment(
                host: host, authorization: authorization, playEnvironment: play,
                receiptStore: receipts,
                activityStore: .init(
                    summaryFile: summary, lockFile: root.appendingPathComponent("summary.lock"),
                    pendingDirectory: root.appendingPathComponent("pending")),
                eventNoticeChannel: .init(
                    sourcePayload: payload, receiverEpoch: UUID(),
                    sender: { [notices] in
                        notices.append($0); return .sent
                    }),
                sourcePayload: payload,
                sourceEnvironment: sourceEnvironment,
                additionalHostStartStopSource: grokSource,
                scopeFingerprint: { [scope] in scope },
                questionScopeFingerprint: { [scope] in scope },
                questionDeduplicationStore: dedup, now: { [now] in now }))
    }
}

private final class GrokBuildTestSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock(); recorded.append(arguments); lock.unlock(); return true
    }
}
