import ClaudioCore
import Foundation

private let additionalHookScope = "additional-hook-fixture-v1"

@MainActor
func runAdditionalHostHookSuites() {
    for host in [HostID.opencode, .kimiCode] {
        suite("\(host.displayName)：非法输入在一切副作用前拒绝") {
            withTempDirectory { root in
                let f = AdditionalHookFixture(root: root, host: host)
                let native = host == .opencode ? "UserTurnStarted" : "TurnStarted"
                var invalid: [Data?] = [
                    nil, Data(), Data("[]".utf8), Data("{".utf8),
                    additionalHookData(host, native, removing: ["session_id"]),
                    additionalHookData(host, native, overrides: ["session_id": false]),
                    additionalHookData(host, native, overrides: ["session_id": "unsafe\u{202E}"]),
                    additionalHookData(host, native, overrides: ["session_id": "two words"]),
                    additionalHookData(host, native, overrides: ["hook_event_name": "Other"]),
                    additionalHookData(host, native, overrides: ["cwd": "relative"]),
                    additionalHookData(host, native, overrides: ["cwd": 1]),
                    Data(repeating: 32, count: HookInputReader.defaultMaximumBytes + 1),
                ]
                let valid = String(decoding: additionalHookData(host, native), as: UTF8.self)
                invalid.append(
                    Data(
                        valid.replacingOccurrences(
                            of: "\"session_id\":",
                            with: "\"session_id\":\"other\",\"session_\\u0069d\":"
                        ).utf8))
                if host == .opencode {
                    for fields in [
                        ["bridge_schema": true], ["bridge_schema": 2], ["executing": 1],
                        ["executing": false], ["origin_kind": "synthetic"],
                        ["session_kind": "child"],
                        ["parent_session_id": "p"], ["message_id": []], ["turn_id": ""],
                        ["unknown_body": "PRIVATE_BODY"],
                    ] as [[String: Any]] {
                        invalid.append(additionalHookData(host, native, overrides: fields))
                    }
                } else {
                    for fields in [
                        ["client_type": "other"], ["turn_id": true], ["turn_id": -1],
                        ["turn_id": 1.5], ["turn_id": "1"], ["origin_kind": "agent"],
                        ["agent_id": []], ["tool_input": "PRIVATE_BODY"],
                    ] as [[String: Any]] {
                        invalid.append(additionalHookData(host, native, overrides: fields))
                    }
                }
                for (index, data) in invalid.enumerated() {
                    expect(f.handle(native, data: data) == nil, "非法输入 \(index) 失败关闭")
                }
                expect(f.spawner.calls.isEmpty && f.notices.values.isEmpty, "非法输入无播放或提示")
                expect(!FileManager.default.fileExists(atPath: f.summaryFile.path), "非法输入无活动")
                expect(
                    !FileManager.default.fileExists(atPath: f.deduplication.stateFile.path),
                    "非法输入不消费身份")
                expect(f.receipts.receiptHistory(host: host, now: f.now).isEmpty, "非法输入无回执")
            }
        }

        suite("\(host.displayName)：所有已实现事件走默认声音、脱敏回执和提示") {
            withTempDirectory { root in
                let f = AdditionalHookFixture(root: root, host: host)
                let bindings = HostCapabilityCatalog.bindings(for: host).filter(
                    \.isAudibleCapability)
                for binding in bindings {
                    let native = binding.nativeEvent!
                    let outcome = f.handle(native)
                    expect(
                        outcome?.event == binding.event && outcome?.playbackResult == .played,
                        "\(native) 使用公共 \(binding.event.cliName)")
                    expect(outcome?.receiptWritten == true, "合法 callback 留当前回执")
                    expect(outcome?.activityRecordOutcome == .committed, "合法 callback 留活动事实")
                    let notice = f.notices.values.last
                    expect(
                        notice?.surface == host.surfaceID && notice?.bindingID == binding.id
                            && notice?.isSemanticallyValid == true, "提示复用既有生命周期合同")
                    if native == "QuestionAsked" { expect(notice?.reason == .needsInput, "明确输入请求") }
                    if native == "PreToolUse" {
                        expect(notice?.reason == .questionIntent, "只能展示即将提问")
                    }
                    if native == "PermissionRequested" || native == "PermissionRequest" {
                        expect(notice?.reason == .permission, "真实权限请求")
                    }
                }
                expect(f.spawner.calls.count == bindings.count, "不同语义事件不被同宿主时间戳吞掉")
                expect(f.spawner.calls.allSatisfy { $0.contains("0.17") }, "新增来源先使用默认组音量")
                if let files = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil)
                {
                    for case let file as URL in files where file.pathExtension == "json" {
                        let text = String(
                            decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
                        if file == f.play.configFile || file.lastPathComponent == "manifest.json" {
                            continue
                        }
                        expect(
                            !text.contains("PRIVATE_BODY") && !text.contains("session-1")
                                && !text.contains("request-1"),
                            "落盘仅保留脱敏合同：\(file.lastPathComponent)")
                    }
                }
                if host == .kimiCode {
                    let source = HostEventSourceParser.parseInput(
                        host: host, nativeEvent: "SubagentStop",
                        data: additionalHookData(host, "SubagentStop")
                    ).source.source
                    expect(
                        source?.isParentSession == true && source?.mainSessionIsKnown != true,
                        "Kimi 子任务成功不声称具体子任务导航或主会话身份")
                }
            }
        }

        suite("\(host.displayName)：请求身份去重、并发会话和重连代次隔离") {
            withTempDirectory { root in
                let f = AdditionalHookFixture(root: root, host: host)
                let native = host == .opencode ? "QuestionAsked" : "PreToolUse"
                expect(f.handle(native)?.playbackResult == .played, "首请求播放")
                expect(f.handle(native)?.playbackResult == .debounced, "同请求只播放一次")
                expect(
                    f.handle(native, data: additionalHookData(host, native, session: "session-2"))?
                        .playbackResult == .played, "并发会话同 token 不串音")
                expect(
                    f.handle(native, data: additionalHookData(host, native, request: "request-2"))?
                        .playbackResult == .played, "不同请求无旧时间去抖")
                expect(f.notices.values.count == 3 && f.spawner.calls.count == 3, "重复不重发提示")
                let replacement = UUID()
                _ = f.receipts.activate(
                    host: host, installationID: replacement,
                    scopeFingerprint: additionalHookScope)
                let old = f.handle(native)
                expect(
                    old?.playbackResult == .notReady && old?.receiptWritten == false,
                    "旧安装回调不能激活新连接")
                expect(
                    f.handle(native, installationID: replacement)?.playbackResult == .played,
                    "新安装同请求可独立消费")
            }
        }

        suite("\(host.displayName)：scope 失效和静音仍保持既有事实边界") {
            withTempDirectory { root in
                let f = AdditionalHookFixture(root: root, host: host)
                let native = host == .opencode ? "PermissionRequested" : "PermissionRequest"
                let stale = f.handle(native, scope: "old-scope")
                expect(
                    stale?.playbackResult == .notReady && stale?.receiptWritten == false,
                    "配置根或版本改变不得用旧代次回执激活")
                expect(!FileManager.default.fileExists(atPath: f.summaryFile.path), "旧作用域不写活动")
                expect(f.spawner.calls.isEmpty && f.notices.values.isEmpty, "旧作用域无播放与提示")
                var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
                config.eventsEnabled = ["notification": false]
                try! JSONEncoder().encode(config).write(to: f.play.configFile)
                let muted = f.handle(native)
                expect(
                    muted?.playbackResult == .muted && muted?.receiptWritten == true,
                    "静音不抹掉 callback")
                expect(f.spawner.calls.isEmpty && f.notices.values.count == 1, "声音开关不控制事件提示")
                config.eventsEnabled = [:]
                try! JSONEncoder().encode(config).write(to: f.play.configFile)
                expect(f.handle(native)?.playbackResult == .debounced, "解除静音不补播旧请求")
                let publisher = DynamicQuietSnapshotPublisher(
                    snapshotFile: f.play.dynamicQuietEnvironment.snapshotFile,
                    revisionStateFile: f.play.dynamicQuietEnvironment.revisionStateFile)
                _ = publisher.publish(focusActive: true, now: f.now)
                expect(
                    f.handle(native, data: additionalHookData(host, native, request: "quiet"))?
                        .playbackResult == .muted, "动态静默沿用默认组播放策略")
            }
        }

        suite("\(host.displayName)：播放期间重连不能写旧回执或发旧提示") {
            withTempDirectory { root in
                let receipts = HostHookReceiptStore(
                    receiptsRoot: root.appendingPathComponent("receipts"),
                    locksRoot: root.appendingPathComponent("receipt-locks"))
                let spawner = AdditionalHookSpawner(onSpawn: {
                    _ = receipts.activate(
                        host: host, installationID: UUID(),
                        scopeFingerprint: additionalHookScope)
                })
                let f = AdditionalHookFixture(
                    root: root, host: host, spawner: spawner, receipts: receipts)
                let native = host == .opencode ? "UserTurnStarted" : "TurnStarted"
                expect(f.handle(native)?.receiptWritten == false, "晚到写入必须复查安装代次")
                expect(f.notices.values.isEmpty, "晚到提示必须复查安装代次")
            }
        }

        suite("\(host.displayName)：回执锁内复核相同 UUID 的 scope 变化") {
            withTempDirectory { root in
                let receipts = HostHookReceiptStore(
                    receiptsRoot: root.appendingPathComponent("receipts"),
                    locksRoot: root.appendingPathComponent("receipt-locks"))
                let id = UUID()
                let spawner = AdditionalHookSpawner(onSpawn: {
                    _ = receipts.activate(
                        host: host, installationID: id,
                        scopeFingerprint: "upgraded-scope")
                })
                let f = AdditionalHookFixture(
                    root: root, host: host, spawner: spawner,
                    receipts: receipts, installationID: id)
                let native = host == .opencode ? "UserTurnStarted" : "TurnStarted"
                expect(
                    f.handle(native)?.receiptWritten == false,
                    "同 UUID 也不能把旧 scope 的回执写入新 scope")
                expect(
                    receipts.receiptHistory(host: host, now: f.now).isEmpty,
                    "旧 scope 不生成看似可激活的历史")
                expect(
                    !FileManager.default.fileExists(
                        atPath:
                            receipts.receiptFile(host: host, nativeEvent: native)!.path),
                    "复核必须发生在稳定回执发布前")
            }
        }
    }

    suite("OpenCode：取消、恢复、缺少终态及子会话身份全部失败关闭") {
        for fields in [
            ["error_kind": "MessageAbortedError"], ["error_kind": "ContextOverflowError"],
            ["error_kind": "PluginInitializationError"], ["terminal": "running"],
            ["session_kind": "child", "parent_session_id": "parent"],
        ] as [[String: Any]] {
            expect(
                AdditionalHostHookPayload.parse(
                    host: .opencode, nativeEvent: "ResponseFailed",
                    data: additionalHookData(.opencode, "ResponseFailed", overrides: fields))
                    == nil,
                "非主会话不可恢复失败不能播放失败音")
        }
        expect(
            AdditionalHostHookPayload.parse(
                host: .opencode, nativeEvent: "ResponseCompleted",
                data: additionalHookData(.opencode, "ResponseCompleted", removing: ["message_id"]))
                == nil,
            "完成必须有对应消息身份")
        expect(
            AdditionalHostHookPayload.parse(
                host: .opencode, nativeEvent: "SubagentCompleted",
                data: additionalHookData(
                    .opencode, "SubagentCompleted",
                    overrides: ["parent_session_id": "session-1"])) == nil, "子会话不能把自己当父会话")
    }

    suite("Kimi Code：精确提问、未启用终态与两个成功子任务") {
        for name in ["askuserquestion", "AskUserQuestion ", "OtherAskUserQuestion"] {
            expect(
                AdditionalHostHookPayload.parse(
                    host: .kimiCode, nativeEvent: "PreToolUse",
                    data: additionalHookData(
                        .kimiCode, "PreToolUse", overrides: ["tool_name": name])) == nil,
                "必须精确匹配提问工具")
        }
        for native in ["Stop", "StopFailure"] {
            expect(
                AdditionalHostHookPayload.parse(
                    host: .kimiCode, nativeEvent: native,
                    data: additionalHookData(.kimiCode, native)) == nil, "缺少主子身份不能启用 \(native)")
        }
        withTempDirectory { root in
            let f = AdditionalHookFixture(root: root, host: .kimiCode)
            expect(f.handle("SubagentStop")?.playbackResult == .played, "第一个成功子任务")
            expect(f.handle("SubagentStop")?.playbackResult == .played, "同名子任务不能用显示名去重")
            expect(f.spawner.calls.count == 2, "不得跨子任务吞成功结束")
        }
    }
}

private func additionalHookData(
    _ host: HostID, _ native: String,
    session: String = "session-1", request: String = "request-1",
    overrides: [String: Any] = [:], removing: [String] = []
) -> Data {
    var value: [String: Any] = [
        "hook_event_name": native, "session_id": session,
        "cwd": "/tmp/additional-project",
    ]
    if host == .opencode {
        value.merge(["bridge_schema": 1, "session_kind": "main"], uniquingKeysWith: { _, v in v })
        switch native {
        case "UserTurnStarted":
            value.merge(
                [
                    "turn_id": request, "message_id": "message", "origin_kind": "user",
                    "executing": true,
                ], uniquingKeysWith: { _, v in v })
        case "ResponseCompleted", "ResponseFailed", "SubagentCompleted":
            value["turn_id"] = request; value["message_id"] = "message"
            value["terminal"] = native == "ResponseFailed" ? "failure" : "success"
            if native == "ResponseFailed" { value["error_kind"] = "APIError" }
            if native == "SubagentCompleted" {
                value["session_kind"] = "child"; value["parent_session_id"] = "parent"
            }
        default: value["request_id"] = request
        }
    } else {
        value["client_type"] = "kimi_code_cli"
        switch native {
        case "TurnStarted": value["turn_id"] = 1; value["origin_kind"] = "user"
        case "SubagentStop": value["agent_name"] = "same child"; value["response"] = "PRIVATE_BODY"
        default:
            value["tool_call_id"] = request;
            value["tool_name"] = native == "PreToolUse" ? "AskUserQuestion" : "Shell"
            value["tool_input"] = ["command": "PRIVATE_BODY"]
        }
    }
    for (key, v) in overrides { value[key] = v }
    for key in removing { value.removeValue(forKey: key) }
    return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private struct AdditionalHookFixture: Sendable {
    let host: HostID
    let installationID: UUID
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let play: PlayEnvironment
    let spawner: AdditionalHookSpawner
    let receipts: HostHookReceiptStore
    let activity: LocalActivitySummaryStore
    let summaryFile: URL
    let deduplication: HostQuestionDeduplicationStore
    let notices = HostEventNoticeCollector()

    @MainActor
    init(
        root: URL, host: HostID, spawner: AdditionalHookSpawner = AdditionalHookSpawner(),
        receipts: HostHookReceiptStore? = nil, installationID: UUID = UUID()
    ) {
        self.installationID = installationID
        self.host = host; self.spawner = spawner
        let config = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs")
        let pack = packs.appendingPathComponent("default")
        writeFixture(#"{"selected_pack":"default","master_volume":0.17,"events":{}}"#, to: config)
        let events = Dictionary(
            uniqueKeysWithValues: Event.allCases.map { ($0.cliName, "tone.aiff") })
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "id": "default", "name": "Default", "events": events,
        ])
        writeFixture(
            String(decoding: manifest, as: UTF8.self),
            to: pack.appendingPathComponent("manifest.json"))
        writeFixture("sound", to: pack.appendingPathComponent("tone.aiff"))
        let moment = now
        play = PlayEnvironment(
            surfaceID: host.surfaceID, lockFile: root.appendingPathComponent("play.lock"),
            configFile: config, userPacksDirectory: packs, spawner: spawner,
            debounceStateFile: root.appendingPathComponent("play.state"), now: { moment },
            logFile: root.appendingPathComponent("claudio.log"),
            logLockFile: root.appendingPathComponent("log.lock"))
        self.receipts =
            receipts
            ?? HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("receipt-locks"))
        _ = self.receipts.activate(
            host: host, installationID: installationID, scopeFingerprint: additionalHookScope)
        summaryFile = root.appendingPathComponent("summary.json")
        activity = LocalActivitySummaryStore(
            summaryFile: summaryFile, lockFile: root.appendingPathComponent("summary.lock"),
            pendingDirectory: root.appendingPathComponent("pending"))
        deduplication = HostQuestionDeduplicationStore(
            directory: root.appendingPathComponent("requests"),
            lockFile: root.appendingPathComponent("requests.lock"))
    }

    func handle(
        _ native: String, installationID: UUID? = nil,
        scope: String = additionalHookScope
    ) -> HostHookHandlingOutcome? {
        handle(
            native, data: additionalHookData(host, native),
            installationID: installationID, scope: scope)
    }

    func handle(
        _ native: String, data: Data?, installationID: UUID? = nil,
        scope: String = additionalHookScope
    )
        -> HostHookHandlingOutcome?
    {
        handleHostHook(
            host: host, nativeEvent: native, installationID: installationID ?? self.installationID,
            environment: HostHookEnvironment(
                host: host, playEnvironment: play, receiptStore: receipts,
                activityStore: activity,
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: data,
                    receiverEpoch: UUID(), observedUptime: 10,
                    sender: { [notices] in
                        notices.append($0); return .sent
                    }),
                sourcePayload: data, scopeFingerprint: { scope },
                questionScopeFingerprint: { scope },
                questionDeduplicationStore: deduplication, now: { [now] in now }))
    }
}

private final class AdditionalHookSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let onSpawn: @Sendable () -> Void
    init(onSpawn: @escaping @Sendable () -> Void = {}) { self.onSpawn = onSpawn }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock(); recorded.append(arguments); lock.unlock()
        onSpawn(); return true
    }
}
