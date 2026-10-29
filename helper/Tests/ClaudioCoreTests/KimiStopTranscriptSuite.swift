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
                KimiStopTranscriptAdmission.source(
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
                KimiStopTranscriptAdmission.source(
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
}

private struct KimiStopTranscriptFixture {
    let root: URL
    let home: URL
    let stateRoot: URL
    let sessionID: String
    let sessionRoot: URL
    let wire: URL
    let payloadData: Data

    init(root: URL, protocolVersion: String = "1.5", outcome: String = "done") {
        self.root = root
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
            "client_type": "kimi_code_cli", "cwd": "/tmp/example-project",
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
        KimiStopTranscriptAdmission.source(
            nativeEvent: "Stop", data: payloadData,
            environment: ["KIMI_CODE_HOME": home.path],
            homeDirectory: home, stateRoot: stateRoot)
    }

    private func append(_ objects: [[String: Any]]) {
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
