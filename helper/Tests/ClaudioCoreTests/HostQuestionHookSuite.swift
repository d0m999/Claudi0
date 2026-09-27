import ClaudioCore
import Darwin
import Foundation

private let questionScope = "question-test-scope-v1"

@MainActor
func runHostQuestionHookSuites() {
    suite("Question hook：精确工具、身份与字段校验先于所有副作用") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let invalid: [Data?] = [
                nil, Data(), Data("[]".utf8), Data("{".utf8),
                questionData(overrides: ["tool_name": "askuserquestion"]),
                questionData(overrides: ["tool_name": "OtherAskUserQuestion"]),
                questionData(overrides: ["tool_name": "AskUserQuestion "]),
                questionData(overrides: ["tool_name": 1]),
                questionData(overrides: ["hook_event_name": "Notification"]),
                questionData(overrides: ["hook_event_name": true]),
                questionData(removing: ["session_id"]),
                questionData(removing: ["tool_use_id"]),
                questionData(removing: ["tool_input"]),
                questionData(overrides: ["session_id": NSNull()]),
                questionData(overrides: ["tool_use_id": 5]),
                questionData(overrides: ["tool_use_id": ""]),
                questionData(overrides: ["tool_use_id": "request two"]),
                questionData(overrides: ["tool_use_id": String(repeating: "r", count: 257)]),
                questionData(overrides: ["session_id": "unsafe\u{202E}id"]),
                questionData(overrides: ["cwd": false]),
                questionData(overrides: ["cwd": "relative/path"]),
                questionData(overrides: ["tool_input": "question"]),
                questionData(overrides: ["agent_id": []]),
                questionData(overrides: ["is_subagent": 1]),
                questionData(overrides: ["subagent": "false"]),
                questionData(overrides: ["notification_type": 1]),
                Data(repeating: 0x20, count: HookInputReader.defaultMaximumBytes + 1),
                Data(
                    #"{"hook_event_name":"PreToolUse","tool_name":"Other","tool_name":"AskUserQuestion","tool_input":{},"session_id":"s","tool_use_id":"r"}"#
                        .utf8),
                Data(
                    #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{},"session_id":"s","session_\u0069d":"s","tool_use_id":"r"}"#
                        .utf8),
                Data(
                    #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{},"session_id":"s","tool_use_id":"r","cwd":"/one","cwd":"/two"}"#
                        .utf8),
            ]
            for (index, data) in invalid.enumerated() {
                expect(
                    fixture.handle(data: data) == nil,
                    "非法 payload \(index) 必须在副作用前拒绝")
            }
            expect(fixture.spawner.calls.isEmpty, "非法输入不能启动播放器")
            expect(fixture.notices.values.isEmpty, "非法输入不能发送提示")
            expect(!FileManager.default.fileExists(atPath: fixture.summaryFile.path), "非法输入不能写活动")
            expect(
                !FileManager.default.fileExists(atPath: fixture.deduplication.stateFile.path),
                "非法输入不能消费请求身份")
            expect(
                fixture.receipts.receiptHistory(host: .claudeCode, now: fixture.now).isEmpty,
                "非法输入不能写回执")
        }
    }

    suite("Question hook：新请求使用 notification，重复仍记录真实 callback") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            expect(fixture.handle()?.playbackResult == .played, "合法提问应播放 notification")
            let duplicate = fixture.handle()
            expect(duplicate?.playbackResult == .debounced, "同请求不得重复播放")
            expect(duplicate?.receiptWritten == true, "合法重复 callback 仍写回执")
            expect(duplicate?.activityRecordOutcome == .committed, "重复 callback 仍记录活动事实")
            expect(
                fixture.handle(data: questionData(request: "request-2"))?.playbackResult == .played,
                "不同请求不使用旧 1.5 秒去抖")
            expect(
                fixture.handle(data: questionData(session: "session-2"))?.playbackResult == .played,
                "不同会话的相同请求 token 彼此独立")
            expect(fixture.spawner.calls.count == 3, "四次 callback 只播放三个独立请求")
            expect(fixture.notices.values.count == 3, "重复 callback 不重发提示")
            expect(
                fixture.notices.values.allSatisfy {
                    $0.event == .notification && $0.reason == .questionIntent
                        && $0.isSemanticallyValid
                }, "提问前置信号不能冒充明确输入请求")
            if case .ready(let document) = fixture.activity.read(now: fixture.now).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .notification) == 4,
                    "活动按合法 callback 计数")
            } else {
                expect(false, "合法提问应生成活动摘要")
            }
            let persisted = String(
                decoding: try! Data(contentsOf: fixture.deduplication.stateFile), as: UTF8.self)
            expect(
                !persisted.contains("session-1") && !persisted.contains("request-1")
                    && !persisted.contains("PRIVATE_QUESTION"),
                "去重仅落盘不可逆身份，不落盘会话、请求 token 或正文")
        }
    }

    suite("Question hook：先前 Stop 及旧播放锁均不吞不同提问") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let stop = handleHostHook(
                host: .claudeCode, nativeEvent: "Stop", installationID: fixture.installationID,
                environment: fixture.environment(data: nil))
            expect(stop?.playbackResult == .played, "fixture 必须先实际走 Stop 播放链")
            let oldLock = FileLock(path: fixture.play.lockFile.path)
            expect(oldLock.attemptLock() == .acquired, "fixture 持有旧播放锁")
            defer { oldLock.unlock() }
            expect(fixture.handle()?.playbackResult == .played, "新提问不使用 Stop 的锁或时间戳")
            expect(fixture.spawner.calls.count == 2, "Stop 与提问均启动播放器")
        }
    }

    suite("Question hook：真实并发时同请求一次、不同请求可在播放器返回前进入") {
        withTempDirectory { root in
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let results = QuestionOutcomeCollector()
            let spawner = QuestionSpawner(onFirstSpawn: {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            })
            let fixture = QuestionHookFixture(root: root, spawner: spawner)
            let first = fixture.environment(data: questionData())
            let id = fixture.installationID
            DispatchQueue.global().async {
                results.append(
                    handleHostHook(
                        host: .claudeCode, nativeEvent: "PreToolUse", installationID: id,
                        environment: first))
                finished.signal()
            }
            expect(started.wait(timeout: .now() + 2) == .success, "首请求必须已启动播放器")
            expect(fixture.handle()?.playbackResult == .debounced, "并发重复在首请求完成前已消费")
            let independent = fixture.handle(data: questionData(request: "concurrent-request"))
            expect(independent?.playbackResult == .played, "不同请求在首播放器返回前独立播放")
            release.signal()
            expect(finished.wait(timeout: .now() + 2) == .success, "首请求应正常完成")
            expect(results.values.first??.playbackResult == .played, "首请求只播放一次")
            expect(spawner.calls.count == 2, "并发共启动两个播放器")
            expect(fixture.notices.values.count == 2, "重复 callback 不创建第二条提示")
        }
    }

    suite("Question hook：静音和启动失败消费身份，恢复后不补播") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
            config.eventsEnabled = ["notification": false]
            try! JSONEncoder().encode(config).write(to: fixture.play.configFile)
            expect(fixture.handle()?.playbackResult == .muted, "事件静音使用 notification 开关")
            config.eventsEnabled = [:]
            try! JSONEncoder().encode(config).write(to: fixture.play.configFile)
            expect(fixture.handle()?.playbackResult == .debounced, "解除静音不会补播已消费请求")
            expect(fixture.spawner.calls.isEmpty, "静默期间没有播放器")

            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: fixture.play.dynamicQuietEnvironment.snapshotFile,
                revisionStateFile: fixture.play.dynamicQuietEnvironment.revisionStateFile)
            guard case .success = publisher.publish(focusActive: true, now: fixture.now) else {
                expect(false, "fixture 必须发布静默状态")
                return
            }
            let quietData = questionData(request: "quiet-request")
            expect(fixture.handle(data: quietData)?.playbackResult == .muted, "动态静默抑制提问声音")
            _ = publisher.publish(focusActive: false, now: fixture.now)
            expect(fixture.handle(data: quietData)?.playbackResult == .debounced, "动态静默结束不补播")
            fixture.spawner.succeeds = false
            let failed = fixture.handle(data: questionData(request: "failed-request"))
            expect(failed?.playbackResult == .playbackFailed, "启动失败不能冒充 played")
            expect(failed?.receiptWritten == true, "播放失败仍保留 callback 回执")
            fixture.spawner.succeeds = true
            expect(
                fixture.handle(data: questionData(request: "failed-request"))?.playbackResult
                    == .debounced,
                "失败请求不因重复 callback 重试声音")
        }
    }

    suite("Question hook：代次和 scope 失效没有活动、声音、回执或提示") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let wrongScope = fixture.handle(scope: "old-scope")
            expect(wrongScope?.playbackResult == .notReady, "scope 不匹配必须拒绝")
            expect(wrongScope?.receiptWritten == false, "旧 scope 不产生回执")
            expect(
                !FileManager.default.fileExists(atPath: fixture.summaryFile.path), "旧 scope 不写活动")
            expect(
                fixture.notices.values.isEmpty && fixture.spawner.calls.isEmpty, "旧 scope 不进入声音或提示")
            expect(fixture.handle()?.playbackResult == .played, "当前代次先消费请求")
            let replacement = UUID()
            _ = fixture.receipts.activate(
                host: .claudeCode, installationID: replacement, scopeFingerprint: questionScope)
            expect(fixture.handle()?.playbackResult == .notReady, "重连后拒绝旧代次")
            let next = handleHostHook(
                host: .claudeCode, nativeEvent: "PreToolUse", installationID: replacement,
                environment: fixture.environment(data: questionData()))
            expect(next?.playbackResult == .played, "新安装代次不继承旧请求消费记录")
        }
    }

    suite("Question hook：入口 sourcePayload 是提示与声音的唯一已验证输入") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let environment = fixture.environment(
                data: questionData(session: "verified-session"),
                channelData: Data(
                    #"{"session_id":"wrong-session","notification_type":"agent_needs_input"}"#.utf8)
            )
            _ = handleHostHook(
                host: .claudeCode, nativeEvent: "PreToolUse",
                installationID: fixture.installationID,
                environment: environment)
            expect(
                fixture.notices.values.first?.source?.sessionID == "verified-session"
                    && fixture.notices.values.first?.reason == .questionIntent,
                "channel 中另一份 payload 不能覆盖已校验身份或升级原因")
        }
    }

    suite("Question hook：新事件未验证目录时使用默认组的声音与音量") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.17)
            config.workspaceRules = [
                WorkspaceSoundRule(
                    directory: WorkspaceDirectory(
                        kind: .directory, path: root.resolvingSymlinksInPath().path),
                    surfaces: [.claudeCode],
                    profile: WorkspaceSoundProfile(selectedPack: "missing-workspace", volume: 0.99))
            ]
            try! JSONEncoder().encode(config).write(to: fixture.play.configFile)
            let result = fixture.handle(data: questionData(overrides: ["cwd": root.path]))
            expect(result?.playbackResult == .played, "未经该事件目录证据验证时不能命中工作区")
            expect(
                fixture.spawner.calls.first?[1]
                    == AfplayVolume.afplayArgument(forMasterVolume: 0.17)
                    && fixture.spawner.calls.first?[2].contains("/default/") == true,
                "notification 使用默认组完整配置")
        }
    }

    suite("Question hook：去重锁忙、写失败和损坏文件如实失败") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let lock = FileLock(path: fixture.deduplication.lockFile.path)
            expect(lock.attemptLock() == .acquired, "fixture 必须持有去重锁")
            let busy = fixture.handle()
            expect(
                busy?.playbackResult == .playbackFailed && busy?.receiptWritten == true, "锁忙不是成功播放")
            expect(fixture.notices.values.isEmpty && fixture.spawner.calls.isEmpty, "未消费身份时不发提示或声音")
            lock.unlock()
            try! FileManager.default.createDirectory(
                at: fixture.deduplication.stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            writeFixture("invalid ledger", to: fixture.deduplication.stateFile)
            expect(fixture.handle()?.playbackResult == .playbackFailed, "损坏消费表失败关闭")
            try! FileManager.default.removeItem(at: fixture.deduplication.stateFile)
            try! FileManager.default.createDirectory(
                at: fixture.deduplication.stateFile, withIntermediateDirectories: true)
            expect(fixture.handle()?.playbackResult == .playbackFailed, "不能把非正规消费文件当作新请求")
            expect(fixture.spawner.calls.isEmpty, "所有存储失败都不能启动播放器")
        }
    }

    suite("Question hook：消费表有界且不驱逐未过期身份") {
        withTempDirectory { root in
            let fixture = QuestionHookFixture(root: root)
            let first = HostQuestionHookPayload.parse(
                host: .claudeCode, nativeEvent: "PreToolUse", data: questionData())!
            for index in 0..<HostQuestionDeduplicationStore.maximumEntries {
                let payload = HostQuestionHookPayload.parse(
                    host: .claudeCode, nativeEvent: "PreToolUse",
                    data: questionData(request: "\(index)"))!
                expect(
                    fixture.deduplication.consume(
                        host: .claudeCode, installationID: fixture.installationID,
                        payload: payload, now: fixture.now, isCurrent: { true }) == .consumed,
                    "容量内请求应消费")
            }
            expect(
                fixture.deduplication.consume(
                    host: .claudeCode, installationID: fixture.installationID,
                    payload: first, now: fixture.now, isCurrent: { true }) == .unavailable,
                "容量满时失败关闭，不驱逐未过期身份制造补播")
            let replacement = UUID()
            _ = fixture.receipts.activate(
                host: .claudeCode, installationID: replacement, scopeFingerprint: questionScope)
            expect(
                fixture.deduplication.consume(
                    host: .claudeCode, installationID: replacement,
                    payload: first, now: fixture.now,
                    isCurrent: {
                        fixture.receipts.isCurrentInstallation(
                            host: .claudeCode, installationID: replacement,
                            scopeFingerprint: questionScope)
                    }) == .consumed,
                "已失效安装占满的消费表不能阻塞新代次")
            let future = fixture.now.addingTimeInterval(
                HostQuestionDeduplicationStore.retention + 1)
            expect(
                fixture.deduplication.consume(
                    host: .claudeCode, installationID: fixture.installationID,
                    payload: first, now: future, isCurrent: { true }) == .consumed,
                "过期记录在有界读取内回收")
            expect(
                fixture.deduplication.consume(
                    host: .claudeCode, installationID: fixture.installationID,
                    payload: first, now: fixture.now, isCurrent: { true }) == .duplicate,
                "系统时钟回退不能重放相同请求")
        }
    }

    suite("Question hook：截断、超限和超时输入不能通过明确入口") {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(
            Data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion""#.utf8))
        let partial = HookInputReader.read(
            from: pipe.fileHandleForReading.fileDescriptor, budget: 0.005)
        expect(
            HostQuestionHookPayload.parse(
                host: .claudeCode, nativeEvent: "PreToolUse", data: partial.data) == nil,
            "截断分片即使 reader 返回有界数据也必须拒绝")
        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.closeFile()
        let empty = Pipe()
        let timeout = HookInputReader.read(
            from: empty.fileHandleForReading.fileDescriptor, budget: 0.005)
        expect(timeout.status == .timedOut && timeout.data == nil, "无数据输入超时不提供可接收 payload")
        empty.fileHandleForWriting.closeFile()
        empty.fileHandleForReading.closeFile()
        let data = questionData()
        expect(
            HostQuestionHookPayload.parse(host: .codex, nativeEvent: "PreToolUse", data: data)
                == nil, "Codex 生产提问入口仍关闭")
        expect(
            HostQuestionHookPayload.parse(host: .workBuddy, nativeEvent: "PreToolUse", data: data)
                == nil, "WorkBuddy 生产提问入口仍关闭")
    }
}

private func questionData(
    session: String = "session-1", request: String = "request-1",
    overrides: [String: Any] = [:], removing: [String] = []
) -> Data {
    var object: [String: Any] = [
        "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
        "session_id": session, "tool_use_id": request, "cwd": "/tmp/question-project",
        "tool_input": ["questions": [["question": "PRIVATE_QUESTION"]]],
    ]
    for (key, value) in overrides { object[key] = value }
    for key in removing { object.removeValue(forKey: key) }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private struct QuestionHookFixture: Sendable {
    let installationID = UUID()
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let play: PlayEnvironment
    let spawner: QuestionSpawner
    let receipts: HostHookReceiptStore
    let activity: LocalActivitySummaryStore
    let summaryFile: URL
    let deduplication: HostQuestionDeduplicationStore
    let notices = HostEventNoticeCollector()

    @MainActor
    init(root: URL, spawner: QuestionSpawner = QuestionSpawner()) {
        self.spawner = spawner
        let config = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs")
        let pack = packs.appendingPathComponent("default")
        try! FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        writeFixture(#"{"selected_pack":"default","master_volume":0.17,"events":{}}"#, to: config)
        writeFixture(
            #"{"id":"default","name":"Default","events":{"notification":"tone.aiff","stop":"tone.aiff"}}"#,
            to: pack.appendingPathComponent("manifest.json"))
        writeFixture("sound", to: pack.appendingPathComponent("tone.aiff"))
        let moment = now
        play = PlayEnvironment(
            lockFile: root.appendingPathComponent("legacy-play.lock"), configFile: config,
            userPacksDirectory: packs, spawner: spawner,
            debounceStateFile: root.appendingPathComponent("legacy-play.state"), now: { moment },
            logFile: root.appendingPathComponent("claudio.log"),
            logLockFile: root.appendingPathComponent("claudio.log.lock"))
        receipts = HostHookReceiptStore(
            receiptsRoot: root.appendingPathComponent("receipts"),
            locksRoot: root.appendingPathComponent("receipt-locks"))
        _ = receipts.activate(
            host: .claudeCode, installationID: installationID, scopeFingerprint: questionScope)
        summaryFile = root.appendingPathComponent("summary.json")
        activity = LocalActivitySummaryStore(
            summaryFile: summaryFile, lockFile: root.appendingPathComponent("summary.lock"),
            pendingDirectory: root.appendingPathComponent("pending"))
        deduplication = HostQuestionDeduplicationStore(
            directory: root.appendingPathComponent("question-requests"),
            lockFile: root.appendingPathComponent("question-requests.lock"))
    }

    func environment(data: Data?, scope: String = questionScope, channelData: Data? = nil)
        -> HostHookEnvironment
    {
        HostHookEnvironment(
            host: .claudeCode, playEnvironment: play, receiptStore: receipts,
            activityStore: activity,
            eventNoticeChannel: HostEventNoticeChannel(
                sourcePayload: channelData ?? data, receiverEpoch: UUID(), observedUptime: 10,
                sender: { [notices] notice in
                    notices.append(notice); return .sent
                }),
            sourcePayload: data, questionScopeFingerprint: { scope },
            questionDeduplicationStore: deduplication, now: { [now] in now })
    }

    func handle(data: Data? = questionData(), scope: String = questionScope)
        -> HostHookHandlingOutcome?
    {
        handleHostHook(
            host: .claudeCode, nativeEvent: "PreToolUse", installationID: installationID,
            environment: environment(data: data, scope: scope))
    }
}

private final class QuestionSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var succeedsValue = true
    private let onFirstSpawn: @Sendable () -> Void

    init(onFirstSpawn: @escaping @Sendable () -> Void = {}) { self.onFirstSpawn = onFirstSpawn }

    var succeeds: Bool {
        get { lock.lock(); defer { lock.unlock() }; return succeedsValue }
        set { lock.lock(); succeedsValue = newValue; lock.unlock() }
    }
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        recorded.append(arguments)
        let first = recorded.count == 1
        let result = succeedsValue
        lock.unlock()
        if first { onFirstSpawn() }
        return result
    }
}

private final class QuestionOutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [HostHookHandlingOutcome?] = []
    var values: [HostHookHandlingOutcome?] { lock.lock(); defer { lock.unlock() }; return outcomes }
    func append(_ value: HostHookHandlingOutcome?) {
        lock.lock(); outcomes.append(value); lock.unlock()
    }
}
