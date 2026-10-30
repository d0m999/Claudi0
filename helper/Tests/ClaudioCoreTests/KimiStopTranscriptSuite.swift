import ClaudioCore
import ClaudioHookInput
import Foundation

@MainActor
func runKimiStopTranscriptSuites() {
    suite("Kimi Stop 落盘：主 turn end 判定、去重与版本门禁") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let first = f.source()
            expect(
                first?.projectLabel == "example-project"
                    && first?.sessionID == f.sessionID
                    && first?.mainSessionIsKnown == true,
                "主 turn end 产生合法来源")
            expect(f.source() == nil, "同一 turnId 的重复/subagent Stop 不再提醒")

            f.appendMainEnd(turnID: 1, outcome: "done")
            expect(f.source() != nil, "新的主 turnId 再次提醒")
            expect(f.source() == nil, "同一新 turnId 仍去重")

            f.appendSubagentOnly()
            expect(f.source() == nil, "subagent 事件不产生主 turn 提醒")
            if let marker = try? FileManager.default.attributesOfItem(
                atPath: f.markerPath.path),
                let permissions = marker[.posixPermissions] as? NSNumber
            {
                expect(permissions.intValue == 0o600, "turn 标记为 0600")
            } else {
                expect(false, "turn 标记必须存在且可读")
            }
        }

        for nextTurnID in [0, 1] {
            withTempDirectory { root in
                let f = KimiStopTranscriptFixture(root: root)
                f.appendMainStart(turnID: nextTurnID)
                f.appendSubagentOnly()
                expect(f.source() == nil, "后续 started \(nextTurnID) 使旧 ended 候选失效")
                expect(!FileManager.default.fileExists(atPath: f.markerPath.path), "未结束主轮不消费旧 turn")
                f.appendMainEnd(turnID: nextTurnID, outcome: "failed")
                expect(f.source() == nil, "最新 ended 非 done 不能退回旧成功轮")
                f.appendMainStart(turnID: nextTurnID + 1)
                f.appendMainEnd(turnID: nextTurnID + 1)
                expect(f.source() != nil, "当前主轮成功结束后可准入")
            }
        }

        for malformedEnd in [
            ["type": "agent.turn.ended", "turnId": 1],
            ["type": "agent.turn.ended", "turnId": "1", "outcome": "done"],
        ] as [[String: Any]] {
            withTempDirectory { root in
                let f = KimiStopTranscriptFixture(root: root)
                f.append([malformedEnd])
                expect(f.source() == nil, "最新 ended 缺少 outcome 或 turnId 类型错误时不复用旧 done")
                expect(
                    !FileManager.default.fileExists(atPath: f.markerPath.path),
                    "非法最新 ended 不消费 marker")
                f.appendMainEnd(turnID: 1)
                expect(f.source() != nil, "后续合法 done 恢复准入")
            }
        }

        for scalar in ["中", "😀"] {
            withTempDirectory { root in
                let f = KimiStopTranscriptFixture(root: root)
                var bytes = try! Data(contentsOf: f.wire)
                let prefix = Data("{\"type\":\"text\",\"text\":\"".utf8)
                bytes.append(prefix)
                bytes.append(Data(repeating: 97, count: 4095 - bytes.count))
                bytes.append(Data("\(scalar)\"}\n".utf8))
                try! bytes.write(to: f.wire)
                f.appendMainEnd(turnID: 1)
                expect(f.source() != nil, "4096 字节边界截断 \(scalar) 不影响完整 metadata")
            }
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            f.rewriteMetadata(padding: 5000)
            expect(f.source() != nil, "超过 4096 字节的 metadata 行仍读取到首个 LF")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            f.rewriteMetadata(padding: 140_000)
            expect(f.source() == nil, "超出读取上限的 metadata 行失败关闭")
            expect(!FileManager.default.fileExists(atPath: f.markerPath.path), "超限 metadata 不消费")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root, protocolVersion: "1.4")
            expect(f.source() == nil, "未知 wire 版本失败关闭")
            expect(!FileManager.default.fileExists(atPath: f.markerPath.path), "版本拒绝不写标记")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root, outcome: "failed")
            expect(f.source() == nil, "主 turn 失败不播放完成提示")
            expect(!FileManager.default.fileExists(atPath: f.markerPath.path), "失败不消费 turnId")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            var object = try! JSONSerialization.jsonObject(with: f.payload()) as! [String: Any]
            object["stop_hook_active"] = "false"
            let data = try! JSONSerialization.data(withJSONObject: object)
            expect(
                KimiStopTranscriptAdmission.prepare(
                    nativeEvent: "Stop", data: data,
                    environment: ["KIMI_CODE_HOME": f.home.path],
                    homeDirectory: f.home, stateRoot: f.stateRoot) == nil,
                "stop_hook_active 类型错误失败关闭")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let valid = String(decoding: f.payload(), as: UTF8.self)
            let duplicate = Data(
                valid.replacingOccurrences(
                    of: "\"session_id\":", with: "\"session_id\":\"other\",\"session_\\u0069d\":"
                ).utf8)
            expect(
                KimiStopTranscriptAdmission.prepare(
                    nativeEvent: "Stop", data: duplicate,
                    environment: ["KIMI_CODE_HOME": f.home.path],
                    homeDirectory: f.home, stateRoot: f.stateRoot) == nil,
                "重复顶层键失败关闭")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let session = f.sessionRoot
            let target = root.appendingPathComponent("outside-session", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: target.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
            try! Data(contentsOf: f.wire).write(
                to: target.appendingPathComponent("agents/main/wire.jsonl"))
            try! FileManager.default.removeItem(at: session)
            try! FileManager.default.createSymbolicLink(
                atPath: session.path, withDestinationPath: target.path)
            expect(f.source() == nil, "session 目录符号链接失败关闭")
        }
    }

    suite("Kimi Stop：来源项目身份复用 parser 的显示投影") {
        for cwd in [
            "/tmp/example-project", "/tmp/中文项目", "/first/shared", "/second/shared", "/",
            "/tmp/  safe   name ", "/tmp/" + String(repeating: "中", count: 150),
        ] {
            withTempDirectory { root in
                let f = KimiStopTranscriptFixture(root: root, cwd: cwd)
                let expected = HostEventSourceParser.parse(host: .claudeCode, data: f.payload())
                    .source
                let source = f.prepare()?.source
                expect(source != nil, "合法 cwd 保留主轮准入")
                expect(source?.projectLabel == expected?.projectLabel, "项目标签遵守统一安全截断与规范化")
                expect(source?.projectKey == expected?.projectKey, "Kimi 项目 key 与 parser 同完整路径摘要一致")
            }
        }
    }

    suite("Kimi Stop：只读准备、安装复验和发布许可后才消费主轮") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let admission = f.prepare()!
            expect(
                !FileManager.default.fileExists(atPath: f.stateRoot.path), "prepare 不创建 marker 目录或锁"
            )
            expect(f.handle(nil) == nil, "缺少 CLI 来源和消费 token 时拒收")
            expect(f.handle(admission, includeConsumption: false) == nil, "缺少消费 token 时拒收")
            expect(
                f.handle(admission, installationID: UUID())?.playbackResult == .notReady,
                "错误安装在消费前拒收")
            expect(!FileManager.default.fileExists(atPath: f.stateRoot.path), "错误安装不消费主轮")
            expect(f.handle(admission)?.receiptWritten == true, "合法重试可接收同一主轮")
            expect(f.handle(admission) == nil, "重复主轮不再次发布事实")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let admission = f.prepare()!
            let intents = HostIntegrationIntentStore(
                configFile: f.config, lockFile: root.appendingPathComponent("config.lock"))
            let runs = HostGUIRunRegistry(
                file: root.appendingPathComponent("gui-run.json"),
                authorizationLockFile: intents.authorizationLockFile)
            _ = intents.setEnabled(surface: .kimiCode, enabled: true)
            _ = runs.register()
            let authorization = HostEventAuthorization(intents: intents, runs: runs)
            let token = authorization.capture(surface: .kimiCode)!
            let outcome = f.handle(
                admission, authorization: authorization, token: token,
                beforePublication: { effect in
                    if effect == .deduplication {
                        _ = f.receipts.activate(
                            host: .kimiCode, installationID: UUID(), scopeFingerprint: f.scope)
                    }
                })
            expect(outcome == nil, "deduplication permit 前安装被替换时拒收")
            expect(!FileManager.default.fileExists(atPath: f.stateRoot.path), "permit 内复验失败不消费")
            _ = f.receipts.activate(
                host: .kimiCode, installationID: f.installationID, scopeFingerprint: f.scope)
            expect(
                f.handle(admission, authorization: authorization, token: token)?.receiptWritten
                    == true,
                "恢复合法安装后同轮仍可重试")
        }

        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let intents = HostIntegrationIntentStore(
                configFile: f.config, lockFile: root.appendingPathComponent("config.lock"))
            let runs = HostGUIRunRegistry(
                file: root.appendingPathComponent("gui-run.json"),
                authorizationLockFile: intents.authorizationLockFile)
            _ = intents.setEnabled(surface: .kimiCode, enabled: true)
            _ = runs.register()
            let authorization = HostEventAuthorization(intents: intents, runs: runs)
            let token = authorization.capture(surface: .kimiCode)!
            let admission = f.prepare()!
            _ = intents.setEnabled(surface: .kimiCode, enabled: false)
            expect(
                f.handle(admission, authorization: authorization, token: token) == nil, "失效授权在消费前拒收"
            )
            expect(!FileManager.default.fileExists(atPath: f.stateRoot.path), "失效授权不消费 marker")
            expect(!FileManager.default.fileExists(atPath: f.summary.path), "失效授权不写活动")
            expect(
                !FileManager.default.fileExists(atPath: f.activityStore.pendingDirectory.path),
                "失效授权不暂存活动")
            _ = intents.setEnabled(surface: .kimiCode, enabled: true)
            let currentToken = authorization.capture(surface: .kimiCode)!
            let revoked = f.handle(
                admission, authorization: authorization, token: currentToken,
                beforePublication: { effect in
                    if effect == .deduplication {
                        _ = intents.setEnabled(surface: .kimiCode, enabled: false)
                    }
                })
            expect(revoked == nil, "deduplication permit 前撤销授权拒收")
            expect(!FileManager.default.fileExists(atPath: f.stateRoot.path), "撤销发布许可不消费 marker")
            expect(f.receipts.receiptHistory(host: .kimiCode).isEmpty, "许可拒绝无回执")
            expect(!FileManager.default.fileExists(atPath: f.summary.path), "许可拒绝无活动")
            expect(
                !FileManager.default.fileExists(atPath: f.activityStore.pendingDirectory.path),
                "许可拒绝不暂存活动")
            _ = intents.setEnabled(surface: .kimiCode, enabled: true)
            expect(
                f.handle(
                    admission, authorization: authorization,
                    token: authorization.capture(surface: .kimiCode))?.receiptWritten == true,
                "合法新授权可重试同轮")
        }
    }

    suite("Kimi Stop：消费许可内活动提交后重复主轮仍恰好一次") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let intents = HostIntegrationIntentStore(
                configFile: f.config, lockFile: root.appendingPathComponent("config.lock"))
            let runs = HostGUIRunRegistry(
                file: root.appendingPathComponent("gui-run.json"),
                authorizationLockFile: intents.authorizationLockFile)
            _ = intents.setEnabled(surface: .kimiCode, enabled: true)
            _ = runs.register()
            let authorization = HostEventAuthorization(intents: intents, runs: runs)
            let token = authorization.capture(surface: .kimiCode)!
            // A competing callback probes the authorization lock while activity publishes.
            // The runner holds that lock for the deduplication permit; the retries below
            // must still produce exactly one activity fact.
            let competitor = HostPublicationContext.unconditional(
                lockFile: intents.authorizationLockFile)
            let first = f.handle(
                f.prepare()!, authorization: authorization, token: token,
                beforePublication: { effect in
                    if effect == .activity { _ = competitor.acquire() }
                })
            competitor.release()
            let markerExists = FileManager.default.fileExists(atPath: f.markerPath.path)
            let pending = root.appendingPathComponent("pending")
            let pendingCount =
                (try? FileManager.default.contentsOfDirectory(
                    at: pending, includingPropertiesForKeys: nil))?.count ?? 0
            let retries = (0..<3).map { _ in
                f.handle(f.prepare(), authorization: authorization, token: token)
            }
            let activity = LocalActivitySummaryStore(
                summaryFile: f.summary, lockFile: root.appendingPathComponent("activity.lock"),
                pendingDirectory: pending)
            let count: UInt64
            switch activity.read().state {
            case .ready(let document), .stale(let document):
                count = document.buckets.reduce(0) { $0 + $1.count(host: .kimiCode, event: .stop) }
            case .missing, .unavailable:
                count = 0
            }
            let firstActivity = first.map { String(describing: $0.activityRecordOutcome) } ?? "nil"
            let retryResults = retries.map {
                $0.map { String(describing: $0.activityRecordOutcome) } ?? "nil"
            }.joined(separator: ",")
            expect(
                first?.activityRecordOutcome == .committed
                    || first?.activityRecordOutcome == .deferred,
                "消费主轮后活动已提交或可靠暂存")
            expect(markerExists, "已接收主轮保留 marker")
            expect(retries.allSatisfy { $0 == nil }, "三次重复主轮不再发布事实")
            expect(
                count == 1,
                "发布锁竞争后同轮活动恰好一次：first=\(firstActivity), marker=\(markerExists), "
                    + "pending=\(pendingCount), retries=[\(retryResults)], count=\(count)")
        }
    }

    suite("Kimi Stop：活动锁忙暂存一次，消费失败不产生活动") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let authorization = f.authorize()
            let token = authorization.capture(surface: .kimiCode)!
            let activityLock = FileLock(path: f.activityStore.lockFile.path)
            expect(activityLock.attemptLock() == .acquired, "占用专用 activity lock")
            let outcome = f.handle(f.prepare(), authorization: authorization, token: token)
            expect(outcome?.activityRecordOutcome == .deferred, "活动锁忙时消费后可靠暂存")
            expect(FileManager.default.fileExists(atPath: f.markerPath.path), "暂存活动保留消费 marker")
            expect(
                (try? FileManager.default.contentsOfDirectory(
                    at: f.activityStore.pendingDirectory, includingPropertiesForKeys: nil))?.count
                    == 1,
                "同轮只产生一个 pending delta")
            expect(
                f.handle(f.prepare(), authorization: authorization, token: token) == nil,
                "pending 未合并前重复主轮也拒收")
            activityLock.unlock()
            for _ in 0..<2 {
                if case .ready(let document) = f.activityStore.read().state {
                    expect(
                        document.buckets.reduce(0) { $0 + $1.count(host: .kimiCode, event: .stop) }
                            == 1,
                        "pending 合并及重复读取后活动始终一次")
                } else {
                    expect(false, "pending 解锁后可合并读取")
                }
            }
            expect(
                (try? FileManager.default.contentsOfDirectory(
                    at: f.activityStore.pendingDirectory, includingPropertiesForKeys: nil))?.isEmpty
                    == true,
                "成功合并后移除唯一 pending")
        }
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let authorization = f.authorize()
            let attempts = root.appendingPathComponent("consumption-attempts")
            try! Data().write(to: attempts)
            let outcome = f.handle(
                f.prepare(), authorization: authorization,
                token: authorization.capture(surface: .kimiCode),
                consumptionOverride: { _ in
                    let output = try! FileHandle(forWritingTo: attempts)
                    defer { try! output.close() }
                    _ = try! output.seekToEnd()
                    try! output.write(contentsOf: Data([1]))
                    return .rejected
                })
            expect(outcome == nil, "消费失败返回拒收，不伪造活动失败 outcome")
            expect((try! Data(contentsOf: attempts)).count == 1, "消费失败不走无许可 fallback 或重跑消费")
            expect(!FileManager.default.fileExists(atPath: f.stateRoot.path), "消费失败不创建 marker")
            expect(!FileManager.default.fileExists(atPath: f.summary.path), "消费失败不写活动")
            expect(
                !FileManager.default.fileExists(atPath: f.activityStore.pendingDirectory.path),
                "消费失败不暂存活动")
        }
    }

    suite("Kimi Stop：活动事实失败不消费主轮，合法重试仍可发布") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let authorization = f.authorize()
            let admission = f.prepare()!
            expect(
                f.handle(
                    admission, includeActivityStore: false, authorization: authorization,
                    token: authorization.capture(surface: .kimiCode)) == nil,
                "活动事实失败时整条回调拒收")
            expect(!FileManager.default.fileExists(atPath: f.markerPath.path), "活动失败不消费主轮 marker")
            expect(
                !FileManager.default.fileExists(atPath: f.activityStore.pendingDirectory.path),
                "活动失败不暂存 delta")
            let retried = f.handle(
                admission, authorization: authorization,
                token: authorization.capture(surface: .kimiCode))
            expect(retried?.activityRecordOutcome == .committed, "活动恢复后同一主轮可重试")
            expect(FileManager.default.fileExists(atPath: f.markerPath.path), "重试成功后才写 marker")
        }
    }

    suite("Kimi Stop：活动与主轮消费共用发布许可，回执和通知在许可外") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            let authorization = f.authorize()
            let probe = KimiStopLeaseProbe(lockFile: authorization.intents.authorizationLockFile)
            let outcome = f.handle(
                f.prepare(), authorization: authorization,
                token: authorization.capture(surface: .kimiCode),
                beforePublication: { probe.inspect(String(describing: $0)) },
                resolveScope: {
                    probe.inspect("scope")
                    return f.scope
                },
                noticeChannel: HostEventNoticeChannel(
                    sourcePayload: f.payload(), receiverEpoch: UUID(), sender: { _ in .sent }))
            expect(
                outcome?.activityRecordOutcome == .committed && outcome?.receiptWritten == true,
                "正常主轮提交活动和回执")
            expect(probe.decisions(for: "activity") == [.busy], "activity effect 复用消费许可")
            let scopeDecisions = probe.decisions(for: "scope")
            expect(
                scopeDecisions.count > 1 && scopeDecisions.allSatisfy { $0 == .allowed },
                "scope 探测始终在许可外")
            expect(probe.decisions(for: "receipt") == [.allowed], "回执发布前已释放活动许可")
            expect(probe.decisions(for: "notice") == [.allowed], "通知发送前已释放活动许可")
        }
    }

    suite("Kimi Stop：marker 损坏和锁忙失败关闭") {
        withTempDirectory { root in
            let f = KimiStopTranscriptFixture(root: root)
            expect(f.source() != nil, "首轮创建 marker")
            let marker = f.markerPath
            let first = try! Data(contentsOf: marker)
            f.appendMainEnd(turnID: 1)
            let admission = f.prepare()!
            let lock = FileLock(
                path: marker.deletingPathExtension().appendingPathExtension("lock").path)
            expect(lock.attemptLock() == .acquired, "占用本会话锁")
            expect(
                !admission.consume(recordingActivity: { .committed }).isConsumed,
                "锁忙不消费主轮")
            expect((try! Data(contentsOf: marker)) == first, "锁忙保持原 marker")
            lock.unlock()
            expect(
                admission.consume(recordingActivity: { .committed }).isConsumed,
                "解锁后仍可合法重试")
            let broken = Data("{broken".utf8)
            try! broken.write(to: marker)
            f.appendMainEnd(turnID: 2)
            expect(f.source() == nil, "损坏 marker 失败关闭")
            expect((try! Data(contentsOf: marker)) == broken, "损坏 marker 不被覆盖")
        }
    }
}

extension AdditionalHostTurnConsumptionOutcome {
    fileprivate var isConsumed: Bool {
        if case .consumed = self { return true }
        return false
    }
}

private struct KimiStopTranscriptFixture {
    let root: URL
    let home: URL
    let stateRoot: URL
    let sessionID: String
    let sessionRoot: URL
    let wire: URL
    let payloadData: Data
    let installationID = UUID()
    let scope = "kimi-stop-runner-fixture-v1"
    let receipts: HostHookReceiptStore
    let config: URL
    let summary: URL

    init(
        root: URL, protocolVersion: String = "1.5", outcome: String = "done",
        cwd: String = "/tmp/example-project"
    ) {
        self.root = root
        config = root.appendingPathComponent("config.json")
        summary = root.appendingPathComponent("activity.json")
        try! Data(#"{"selected_pack":"default","master_volume":0,"events":{"stop":false}}"#.utf8)
            .write(to: config)
        receipts = HostHookReceiptStore(
            receiptsRoot: root.appendingPathComponent("receipts"),
            locksRoot: root.appendingPathComponent("receipt-locks"),
            installationsRoot: root.appendingPathComponent("installations"),
            installationLocksRoot: root.appendingPathComponent("installation-locks"))
        _ = receipts.activate(
            host: .kimiCode, installationID: installationID, scopeFingerprint: scope)
        home = root.appendingPathComponent("kimi-home", isDirectory: true)
        stateRoot = root.appendingPathComponent("claudio-state", isDirectory: true)
        sessionID = "session_\(UUID().uuidString)"
        sessionRoot =
            home.appendingPathComponent("sessions/wd_example_123456789abc/\(sessionID)")
        wire = sessionRoot.appendingPathComponent("agents/main/wire.jsonl")
        try! FileManager.default.createDirectory(
            at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(
            at: stateRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "type": "metadata", "protocol_version": protocolVersion,
            "created_at": 1_900_000_000_000,
        ]
        let end: [String: Any] = [
            "type": "agent.turn.ended", "turnId": 0, "outcome": outcome, "time": 1_900_000_000_001,
        ]
        payloadData = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": sessionID,
            "client_type": "kimi_code_cli", "cwd": cwd,
            "stop_hook_active": false,
        ])
        write([metadata, end])
    }

    var markerPath: URL {
        // The admission hashes the session id; discover the single marker instead of
        // duplicating that hash helper in the test.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: stateRoot, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "json" }
            ?? stateRoot.appendingPathComponent("missing")
    }

    func payload() -> Data { payloadData }

    func rewriteMetadata(padding: Int) {
        let lines = String(decoding: try! Data(contentsOf: wire), as: UTF8.self)
            .split(separator: "\n")
        var metadata =
            try! JSONSerialization.jsonObject(
                with: Data(lines[0].utf8)) as! [String: Any]
        metadata["padding"] = String(repeating: "a", count: padding)
        var rewritten = try! JSONSerialization.data(
            withJSONObject: metadata, options: [.sortedKeys])
        rewritten.append(Data(("\n" + lines.dropFirst().joined(separator: "\n")).utf8))
        try! rewritten.write(to: wire)
    }

    func appendMainStart(turnID: Int) {
        append([
            [
                "type": "agent.turn.started", "turnId": turnID, "queueItemId": "fixture-item",
                "time": 1_900_000_000_002,
            ]
        ])
    }

    func appendMainEnd(turnID: Int, outcome: String = "done") {
        append([[
            "type": "agent.turn.ended", "turnId": turnID, "outcome": outcome,
            "time": 1_900_000_000_002,
        ]])
    }

    func appendSubagentOnly() {
        append([[
            "type": "subagent.started", "subagentId": "agent-0",
            "parentAgentId": "main", "time": 1_900_000_000_003,
        ]])
    }

    func source() -> HostEventSource? {
        guard
            let admission = prepare(),
            admission.consume(recordingActivity: { .committed }).isConsumed
        else { return nil }
        return admission.source
    }

    func prepare() -> KimiStopTranscriptAdmission.PreparedAdmission? {
        KimiStopTranscriptAdmission.prepare(
            nativeEvent: "Stop", data: payloadData,
            environment: ["KIMI_CODE_HOME": home.path],
            homeDirectory: home, stateRoot: stateRoot)
    }

    var activityStore: LocalActivitySummaryStore {
        LocalActivitySummaryStore(
            summaryFile: summary, lockFile: root.appendingPathComponent("activity.lock"),
            pendingDirectory: root.appendingPathComponent("pending"))
    }

    func authorize() -> HostEventAuthorization {
        let intents = HostIntegrationIntentStore(
            configFile: config, lockFile: root.appendingPathComponent("config.lock"))
        let runs = HostGUIRunRegistry(
            file: root.appendingPathComponent("gui-run.json"),
            authorizationLockFile: intents.authorizationLockFile)
        _ = intents.setEnabled(surface: .kimiCode, enabled: true)
        _ = runs.register()
        return HostEventAuthorization(intents: intents, runs: runs)
    }

    func handle(
        _ admission: KimiStopTranscriptAdmission.PreparedAdmission?,
        installationID: UUID? = nil, includeConsumption: Bool = true,
        includeActivityStore: Bool = true,
        authorization: HostEventAuthorization? = nil, token: HostEventAuthorizationToken? = nil,
        beforePublication: @escaping @Sendable (HostPublicationEffect) -> Void = { _ in },
        consumptionOverride: AdditionalHostTurnConsumption? = nil,
        resolveScope: (@Sendable () -> String?)? = nil,
        noticeChannel: HostEventNoticeChannel? = nil
    ) -> HostHookHandlingOutcome? {
        let consumption: AdditionalHostTurnConsumption?
        if let consumptionOverride {
            consumption = consumptionOverride
        } else if includeConsumption, let admission {
            consumption = { recordActivity in
                admission.consume(recordingActivity: recordActivity)
            }
        } else {
            consumption = nil
        }
        let scopeFingerprint: @Sendable () -> String?
        if let resolveScope {
            scopeFingerprint = resolveScope
        } else {
            scopeFingerprint = { [scope] in scope }
        }
        return handleHostHook(
            host: .kimiCode, nativeEvent: "Stop",
            installationID: installationID ?? self.installationID,
            environment: HostHookEnvironment(
                host: .kimiCode, authorization: authorization, authorizationToken: token,
                beforePublication: beforePublication,
                playEnvironment: PlayEnvironment(
                    surfaceID: .kimiCode, lockFile: root.appendingPathComponent("play.lock"),
                    configFile: config, userPacksDirectory: root.appendingPathComponent("packs"),
                    spawner: KimiStopSilentSpawner(),
                    debounceStateFile: root.appendingPathComponent("play.state"),
                    logFile: root.appendingPathComponent("log"),
                    logLockFile: root.appendingPathComponent("log.lock")),
                receiptStore: receipts,
                activityStore: includeActivityStore ? activityStore : nil,
                eventNoticeChannel: noticeChannel,
                sourcePayload: payloadData,
                additionalHostPreparedSource: admission?.source,
                additionalHostTurnConsumption: consumption,
                scopeFingerprint: scopeFingerprint))
    }

    func append(_ objects: [[String: Any]]) {
        let lines = objects.compactMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: wire) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lines.utf8))
            try? handle.close()
        }
    }

    private func write(_ objects: [[String: Any]]) {
        let text = objects.compactMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try! Data(text.utf8).write(to: wire)
    }
}

private struct KimiStopSilentSpawner: ProcessSpawning {
    func spawn(executablePath: String, arguments: [String]) -> Bool { false }
}

private final class KimiStopLeaseProbe: @unchecked Sendable {
    private let context: HostPublicationContext
    private let lock = NSLock()
    private var observations: [String: [HostPublicationDecision]] = [:]

    init(lockFile: URL) {
        context = .unconditional(lockFile: lockFile)
    }

    func inspect(_ phase: String) {
        let decision = context.acquire()
        context.release()
        lock.withLock { observations[phase, default: []].append(decision) }
    }

    func decisions(for phase: String) -> [HostPublicationDecision] {
        lock.withLock { observations[phase] ?? [] }
    }
}
