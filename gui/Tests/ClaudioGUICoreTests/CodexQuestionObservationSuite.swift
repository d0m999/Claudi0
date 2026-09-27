import ClaudioGUICore
import Foundation

private final class CodexObservationFixture {
    let directory: URL
    let file: URL
    let sessionID = "00000000-0000-4000-8000-000000000027"
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let formatter: ISO8601DateFormatter

    init(initial: Data = Data()) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-codex-observation-\(UUID().uuidString)")
        file = directory.appendingPathComponent("rollout-fixture-\(sessionID).jsonl")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! initial.write(to: file)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reader(runID: UUID = UUID(), startedAt: Date? = nil) -> CodexRolloutObservationReader {
        try! CodexRolloutObservationReader(
            target: CodexRolloutObservationTarget(fileURL: file, sessionID: sessionID)!,
            runID: runID, startedAt: startedAt ?? start)
    }

    func append(_ data: Data) {
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
        try! handle.close()
    }

    func record(
        tool: String = "request_user_input", request: String = "call_sync", age: TimeInterval = 1,
        namespace: Any? = nil
    ) -> Data {
        var payload: [String: Any] = [
            "type": "function_call", "name": tool, "call_id": request,
            "arguments": "{\"questions\":[{\"question\":\"synthetic question\"}]}",
        ]
        if let namespace { payload["namespace"] = namespace }
        var data = try! JSONSerialization.data(
            withJSONObject: [
                "timestamp": formatter.string(from: start.addingTimeInterval(age)),
                "type": "response_item", "payload": payload,
            ], options: [.sortedKeys])
        data.append(10)
        return data
    }

    func poll(
        _ reader: CodexRolloutObservationReader, uptime: TimeInterval = 100,
        age: TimeInterval = 2
    ) -> Result<[CodexQuestionObservation], CodexQuestionObservationFailure> {
        reader.poll(now: start.addingTimeInterval(age), observedUptime: uptime)
    }
}

@MainActor
func runCodexQuestionObservationSuites() {
    suite("Codex 开发观察：必须显式开启、指定单文件与一致会话 UUID") {
        let fixture = CodexObservationFixture()
        let valid = CodexRolloutObservationTarget(
            fileURL: fixture.file, sessionID: fixture.sessionID)
        expect(valid != nil, "显式匹配文件名身份")
        expect(
            CodexRolloutObservationTarget(fileURL: fixture.file, sessionID: UUID().uuidString)
                == nil,
            "拒绝错配会话身份")
        expect(
            CodexRolloutObservationTarget(fileURL: fixture.file, sessionID: "session") == nil,
            "拒绝缺少稳定 UUID")
        expect(
            CodexRolloutObservationTarget(
                fileURL: URL(string: "https://example.invalid/rollout.jsonl")!,
                sessionID: fixture.sessionID) == nil, "拒绝网络地址")
        var environment = [
            "CLAUDIO_DEV_CODEX_ROLLOUT_PATH": fixture.file.path,
            "CLAUDIO_DEV_CODEX_SESSION_ID": fixture.sessionID,
        ]
        expect(
            CodexRolloutObservationTarget.developmentEnvironment(environment) == nil,
            "给出路径本身不启用观察")
        environment["CLAUDIO_DEV_CODEX_QUESTION_OBSERVER"] = "true"
        expect(
            CodexRolloutObservationTarget.developmentEnvironment(environment) == nil,
            "flag 必须精确为 1")
        environment["CLAUDIO_DEV_CODEX_QUESTION_OBSERVER"] = "1"
        expect(
            CodexRolloutObservationTarget.developmentEnvironment(environment) == valid,
            "开发运行显式启用")
        environment["CLAUDIO_DEV_CODEX_ROLLOUT_PATH"] = "relative.jsonl"
        expect(
            CodexRolloutObservationTarget.developmentEnvironment(environment) == nil,
            "相对路径拒绝")
    }

    suite("Codex 开发观察：历史不解析，新同步和异步调用均只表达意图") {
        let fixture = CodexObservationFixture(
            initial: Data(repeating: 65, count: 100_000) + Data([10]))
        let run = UUID()
        let reader = fixture.reader(runID: run)
        expect(fixture.poll(reader) == .success([]), "启动从 EOF，不回放或解析旧大记录")
        fixture.append(fixture.record())
        fixture.append(
            fixture.record(
                tool: "request_user_input_async", request: "call_async", namespace: "functions"))
        guard case .success(let observations) = fixture.poll(reader) else {
            expect(false, "新同步/异步行必须成功读取")
            return
        }
        expect(observations.count == 2, "不同请求不被吞掉")
        expect(observations.map(\.tool) == [.synchronous, .asynchronous], "同步与异步分别识别")
        expect(
            observations.allSatisfy {
                $0.runID == run && $0.sessionID == fixture.sessionID
                    && $0.kind == .callIntention && $0.provenance == .developmentRolloutV1
                    && $0.observedUptime == 100
            }, "独立来源与运行代次，任何 function_call 都不是明确待答证明")
        expect(reader.pendingByteCount == 0, "完整记录不保留原始数据")
        fixture.append(fixture.record())
        fixture.append(fixture.record(tool: "request_user_input_async", request: "call_sync"))
        expect(fixture.poll(reader) == .success([]), "同 request 身份跨重复工具回调不再发出")
    }

    suite("Codex 开发观察：精确名称、普通事件与未验证明确请求格式") {
        let fixture = CodexObservationFixture()
        let reader = fixture.reader()
        for name in [
            "Request_User_Input", "functions.request_user_input", "request_user_input_extra",
            "exec_command",
        ] {
            fixture.append(fixture.record(tool: name))
        }
        fixture.append(
            Data(
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"request_user_input\",\"call_id\":\"e1\"}}\n"
                    .utf8))
        fixture.append(
            Data(
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"name\":null,\"output\":\"synthetic answer\"}}\n"
                    .utf8))
        fixture.append(
            Data("{\"method\":\"item/tool/requestUserInput\",\"params\":{\"questions\":[]}}\n".utf8)
        )
        expect(fixture.poll(reader) == .success([]), "名称相似、普通输出与其他协议不扩大候选入口")
        fixture.append(fixture.record(namespace: NSNull()))
        expect((try? fixture.poll(reader).get().count) == 1, "schema 允许的 null namespace")
    }

    suite("Codex 开发观察：历史追加、未来时间与新运行均不回放") {
        let fixture = CodexObservationFixture()
        let first = fixture.reader()
        fixture.append(fixture.record(request: "old", age: -10))
        fixture.append(fixture.record(request: "future", age: 100))
        expect(fixture.poll(first) == .success([]), "启动前记录与未来时间没有输出")
        fixture.append(fixture.record(request: "new"))
        expect((try? fixture.poll(first).get().count) == 1, "本代新增信号通过")
        first.stop()
        expect(fixture.poll(first) == .failure(.inactive), "关闭后代次失效")
        let second = fixture.reader(startedAt: fixture.start.addingTimeInterval(3))
        expect(fixture.poll(second, age: 4) == .success([]), "恢复从新的 EOF 开始")
        fixture.append(fixture.record(request: "new", age: 3.5))
        expect((try? fixture.poll(second, age: 4).get().count) == 1, "新代的同一请求不会受旧代缓存影响")
    }

    suite("Codex 开发观察：半行、开始时残行、超时与隐私清空") {
        let fixture = CodexObservationFixture(initial: Data("{\"old\":".utf8))
        let reader = fixture.reader()
        fixture.append(Data("\"tail\"}\n".utf8))
        let record = fixture.record()
        fixture.append(record.prefix(record.count / 2))
        expect(fixture.poll(reader) == .success([]), "开始时的残行被丢弃，新半行暂不输出")
        expect(reader.pendingByteCount > 0, "只持有有界未完成新行")
        fixture.append(record.suffix(record.count - record.count / 2))
        expect((try? fixture.poll(reader, uptime: 101).get().count) == 1, "两秒内完成半行")
        fixture.append(record.prefix(10))
        expect(fixture.poll(reader, uptime: 102) == .success([]), "第二个半行未完成")
        expect(fixture.poll(reader, uptime: 105) == .failure(.partialLineExpired), "半行超过两秒退休本代")
        expect(reader.pendingByteCount == 0 && reader.rememberedRequestCount == 0, "失败释放缓冲与身份")
        fixture.append(record.suffix(record.count - 10))
        expect(fixture.poll(reader) == .failure(.partialLineExpired), "迟到补齐不能重启旧代")
    }

    suite("Codex 开发观察：敏感重复键、类型与 JSON 格式失效均无输出") {
        let fixture = CodexObservationFixture()
        let original = String(data: fixture.record(), encoding: .utf8)!
        let mutations: [(String, String)] = [
            ("缺失请求 ID", original.replacingOccurrences(of: "\"call_id\":\"call_sync\",", with: "")),
            (
                "错误请求 ID 类型",
                original.replacingOccurrences(
                    of: "\"call_id\":\"call_sync\"", with: "\"call_id\":42")
            ),
            (
                "重复请求 ID",
                original.replacingOccurrences(
                    of: "\"call_id\":\"call_sync\"",
                    with: "\"call_id\":\"call_sync\",\"call_id\":\"other\"")
            ),
            (
                "转义重复字段",
                original.replacingOccurrences(
                    of: "\"call_id\":\"call_sync\"",
                    with: "\"call_id\":\"call_sync\",\"call_\\u0069d\":\"other\"")
            ),
            (
                "重复根类型",
                original.replacingOccurrences(
                    of: "\"type\":\"response_item\"",
                    with: "\"type\":\"response_item\",\"type\":\"response_item\"")
            ),
            ("请求身份包含空白", original.replacingOccurrences(of: "call_sync", with: "call sync")),
            ("截断完整行", String(original.dropLast(2)) + "\n"),
            ("非法转义", original.replacingOccurrences(of: "synthetic", with: "\\q")),
            ("未配对 unicode", original.replacingOccurrences(of: "synthetic", with: "\\uD800")),
            (
                "超深结构",
                original.replacingOccurrences(
                    of: "\"payload\":",
                    with: "\"ignored\":" + String(repeating: "[", count: 25) + "0"
                        + String(repeating: "]", count: 25) + ",\"payload\":")
            ),
        ]
        for (name, malformed) in mutations {
            let reader = fixture.reader()
            fixture.append(Data(malformed.utf8))
            expect(fixture.poll(reader) == .failure(.invalidRecord), name)
            expect(reader.pendingByteCount == 0, "失败不保留原文：\(name)")
        }
        for namespace in ["unverified_namespace" as Any, 42] {
            let reader = fixture.reader()
            fixture.append(fixture.record(namespace: namespace))
            expect(fixture.poll(reader) == .failure(.invalidRecord), "namespace 不能猜测或接受错误类型")
        }
        let reader = fixture.reader()
        var invalidUTF8 = fixture.record()
        let quoted = invalidUTF8.firstIndex(of: 34)!
        invalidUTF8.insert(0xC0, at: quoted + 1)
        fixture.append(invalidUTF8)
        expect(fixture.poll(reader) == .failure(.invalidRecord), "非法 UTF-8 拒绝")
    }

    suite("Codex 开发观察：容量、积压与超限以整批失败关闭") {
        let fixture = CodexObservationFixture()
        let lineReader = fixture.reader()
        fixture.append(
            Data(repeating: 32, count: CodexRolloutObservationReader.maximumLineBytes + 1))
        expect(fixture.poll(lineReader) == .failure(.lineTooLarge), "单行超限")
        let backlogReader = fixture.reader()
        fixture.append(
            Data(repeating: 32, count: CodexRolloutObservationReader.maximumReadBytes + 1))
        expect(fixture.poll(backlogReader) == .failure(.backlogExceeded), "积压超限，不回追历史")
        fixture.append(Data([10]))
        let burstReader = fixture.reader()
        for id in 0...CodexRolloutObservationReader.maximumEventsPerPoll {
            fixture.append(fixture.record(request: "burst_\(id)"))
        }
        expect(fixture.poll(burstReader) == .failure(.eventLimitExceeded), "超大事件批次不部分投递")
        let capacityReader = fixture.reader()
        for batch in 0..<8 {
            for id in 0..<32 {
                fixture.append(fixture.record(request: "bounded_\(batch * 32 + id)"))
            }
            expect((try? fixture.poll(capacityReader).get().count) == 32, "容量内正常输出")
        }
        expect(capacityReader.rememberedRequestCount == 256, "请求去重严格有界")
        fixture.append(fixture.record(request: "overflow"))
        expect(fixture.poll(capacityReader) == .failure(.identityCapacityExceeded), "触顶终止，不驱逐后重响")
    }

    suite("Codex 开发观察：截断、替换、改写、权限失败使代次失效") {
        let operations:
            [(String, (CodexObservationFixture) -> Void, CodexQuestionObservationFailure)] = [
                (
                    "截断",
                    { fixture in
                        let handle = try! FileHandle(forWritingTo: fixture.file)
                        try! handle.truncate(atOffset: 0)
                        try! handle.close()
                    }, .replacedOrTruncated
                ),
                (
                    "替换",
                    { fixture in
                        try! fixture.record().write(to: fixture.file, options: .atomic)
                    }, .replacedOrTruncated
                ),
                (
                    "改写后重新增长",
                    { fixture in
                        let handle = try! FileHandle(forWritingTo: fixture.file)
                        try! handle.truncate(atOffset: 0)
                        try! handle.write(contentsOf: Data(repeating: 32, count: 1024))
                        try! handle.close()
                    }, .replacedOrTruncated
                ),
                (
                    "权限失效",
                    { fixture in
                        try! FileManager.default.setAttributes(
                            [.posixPermissions: 0], ofItemAtPath: fixture.file.path)
                    }, .unavailable
                ),
                (
                    "删除", { fixture in try! FileManager.default.removeItem(at: fixture.file) },
                    .unavailable
                ),
            ]
        for (name, operation, failure) in operations {
            let fixture = CodexObservationFixture()
            let reader = fixture.reader()
            fixture.append(fixture.record())
            expect((try? fixture.poll(reader).get().count) == 1, "先有合法新事件")
            operation(fixture)
            expect(fixture.poll(reader) == .failure(failure), "文件异常：\(name)")
            expect(reader.pendingByteCount == 0 && reader.rememberedRequestCount == 0, "异常清空内存")
        }
    }

    suite("Codex 开发观察：符号链接和非常规文件不被当作 rollout") {
        let fixture = CodexObservationFixture()
        let link = fixture.directory.appendingPathComponent(
            "rollout-link-\(fixture.sessionID).jsonl")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        let target = CodexRolloutObservationTarget(fileURL: link, sessionID: fixture.sessionID)!
        expect(
            (try? CodexRolloutObservationReader(target: target, runID: UUID())) == nil,
            "拒绝链接，不读取其目标")
        let directory = fixture.directory.appendingPathComponent(
            "rollout-dir-\(fixture.sessionID).jsonl")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let directoryTarget = CodexRolloutObservationTarget(
            fileURL: directory, sessionID: fixture.sessionID)!
        expect(
            (try? CodexRolloutObservationReader(target: directoryTarget, runID: UUID())) == nil,
            "拒绝目录")
    }
}
