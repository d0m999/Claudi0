import ClaudioCore
import ClaudioHookInput
import Darwin
import Foundation

@MainActor
func runCodexApprovalRoutingSuites() {
    suite("Codex approval: an unqualified PermissionRequest is silent") {
        withTempDirectory { root in
            let id = UUID()
            let spawner = HostHookRunnerSpawner()
            let collector = HostEventNoticeCollector()
            let payload = Data(
                #"{"hook_event_name":"PermissionRequest","permission_mode":"default"}"#.utf8)
            let environment = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: spawner, fixtureIsReady: true,
                activeInstallationID: id, sourcePayload: payload,
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: payload, receiverEpoch: UUID(),
                    sender: {
                        collector.append($0); return .sent
                    }))
            let result = handleHostHook(
                host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                environment: environment)
            expect(
                spawner.callCount == 0,
                "PermissionRequest alone does not establish a human approval")
            expect(collector.values.isEmpty, "unconfirmed approval must not create a banner")
            expect(result?.playbackResult == .muted, "unconfirmed approval is silent")
            expect(result?.receiptWritten == true, "the genuine hook receipt is preserved")
        }
    }

    suite(
        "Codex approval: nine automatic reviews stay silent and the next human request is delivered"
    ) {
        withTempDirectory { root in
            let fixture = ApprovalFixture(root: root)
            fixture.write(reviewer: "auto_review")
            let productionFactory = systemHostHookEnvironment(
                for: .codex, sourcePayload: fixture.payload(),
                codexApprovalRouting: {
                    CodexApprovalRoutingResolver.resolve($0, sessionsDirectory: fixture.sessions)
                })
            expect(
                productionFactory.codexApprovalRouting(productionFactory.sourcePayload)
                    == .automatic,
                "production factory forwards CLI routing injection")
            let activity = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("activity/summary.json"),
                lockFile: root.appendingPathComponent("activity/summary.lock"),
                pendingDirectory: root.appendingPathComponent("activity/pending"))
            let id = UUID()
            let spawner = HostHookRunnerSpawner()
            let collector = HostEventNoticeCollector()
            let environment = makeHostHookRunnerEnvironment(
                root: root.appendingPathComponent("helper"), host: .codex,
                spawner: spawner, fixtureIsReady: true, activeInstallationID: id,
                sourcePayload: fixture.payload(),
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: fixture.payload(), receiverEpoch: UUID(),
                    sender: {
                        collector.append($0); return .sent
                    }),
                activityStore: activity,
                codexApprovalRouting: {
                    CodexApprovalRoutingResolver.resolve($0, sessionsDirectory: fixture.sessions)
                })
            for _ in 0..<9 {
                let result = handleHostHook(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                    environment: environment)
                expect(
                    result?.playbackResult == .muted && result?.receiptWritten == true,
                    "automatic review retains only its silent receipt")
                expect(
                    result?.activityRecordOutcome == .committed,
                    "actual callback activity is preserved")
            }
            expect(
                spawner.callCount == 0 && collector.values.isEmpty,
                "automatic review creates neither audio nor banner, independent of debounce")

            fixture.write(reviewer: "user")
            expect(
                productionFactory.codexApprovalRouting(productionFactory.sourcePayload) == .user,
                "production factory preserves confirmed human routing after module separation")
            let manual = handleHostHook(
                host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                environment: environment)
            expect(
                manual?.playbackResult == .played && manual?.receiptWritten == true,
                "the next confirmed human request is not consumed by automatic-review debounce")
            expect(
                spawner.callCount == 1 && collector.values.count == 1,
                "confirmed human approval retains sound and one banner")
            expect(
                collector.values.first?.reason == .permission,
                "normal permission reason is preserved")
            if case .ready(let summary) = activity.read(now: environment.now()).state {
                expect(
                    summary.buckets.reduce(0) { $0 + $1.count(host: .codex, event: .notification) }
                        == 10,
                    "activity counts callbacks independently from reminder eligibility")
            } else {
                expect(false, "activity summary remains readable")
            }
            let receipt = environment.receiptStore.receiptFile(
                host: .codex, nativeEvent: "PermissionRequest")!
            let persisted =
                (try! String(contentsOf: receipt, encoding: .utf8))
                + ((try? String(contentsOf: environment.playEnvironment.logFile, encoding: .utf8))
                    ?? "")
                + (try! String(contentsOf: activity.summaryFile, encoding: .utf8))
            expect(
                !persisted.contains(fixture.thread.uuidString)
                    && !persisted.contains(fixture.turn.uuidString)
                    && !persisted.contains(fixture.file.path)
                    && !persisted.contains("private-command-sentinel")
                    && !persisted.contains("approvals_reviewer"),
                "routing and transcript contents are not persisted")
        }
    }

    suite("Codex approval: current child turn owns routing, even in a long inherited transcript") {
        withTempDirectory { root in
            let fixture = ApprovalFixture(root: root)
            let inherited =
                ApprovalFixture.row(
                    "turn_context",
                    [
                        "turn_id": UUID().uuidString, "approvals_reviewer": "auto_review",
                    ])
                + ApprovalFixture.row(
                    "response_item", ["content": String(repeating: "x", count: 9 << 20)])
            let output = ApprovalFixture.row(
                "response_item", ["content": String(repeating: "x", count: 100 << 10)])
            fixture.write(reviewer: "user", beforeTurn: inherited, afterTurn: output)
            expect(
                fixture.resolve() == .user,
                "reads current turn across chunks without scanning old history")
            expect(
                fixture.resolve(payload: fixture.payload(session: UUID(), agent: fixture.thread))
                    == .user,
                "a subagent is checked against its own transcript identity, not its parent session")
            fixture.write(
                reviewer: "auto_review",
                beforeTurn: ApprovalFixture.row(
                    "turn_context",
                    [
                        "turn_id": UUID().uuidString, "approvals_reviewer": "user",
                    ]))
            expect(
                fixture.resolve() == .automatic,
                "inherited human policy cannot qualify automatic child approval")
        }
    }

    suite("Codex approval: stale, missing, changed and incomplete routing fail closed") {
        withTempDirectory { root in
            let fixture = ApprovalFixture(root: root)
            for reviewer in [nil, "future-reviewer", "auto_review", "user"] as [String?] {
                fixture.write(reviewer: reviewer)
                let expected: CodexApprovalRouting =
                    reviewer == "user"
                    ? .user : reviewer == "auto_review" ? .automatic : .unavailable
                expect(
                    fixture.resolve() == expected, "only the explicit current reviewer qualifies")
            }
            fixture.write(
                reviewer: "user",
                afterTurn: ApprovalFixture.row(
                    "turn_context",
                    [
                        "turn_id": UUID().uuidString, "approvals_reviewer": "auto_review",
                    ]))
            expect(
                fixture.resolve() == .unavailable,
                "never searches past a newer turn for an older user policy")
            fixture.write(reviewer: "user", afterTurn: #"{"type":"turn_context","payload":{ "#)
            expect(
                fixture.resolve() == .unavailable,
                "an incomplete last record cannot expose a stale policy")
            let settings = ApprovalFixture.row(
                "event_msg",
                [
                    "type": "thread_settings_applied",
                    "thread_id": fixture.thread.uuidString,
                    "thread_settings": ["approvals_reviewer": "auto_review"],
                ])
            fixture.write(reviewer: "user", afterTurn: settings)
            expect(
                fixture.resolve() == .unavailable,
                "conflicting later settings cannot retain a human reminder")
            fixture.write(reviewer: "user")
            expect(
                fixture.resolve(payload: fixture.payload(turn: UUID())) == .unavailable,
                "turn identity must match")
            expect(
                fixture.resolve(payload: fixture.payload(agent: UUID())) == .unavailable,
                "agent identity must match")
            for mode in ["bypassPermissions", "dontAsk", "future-mode"] {
                expect(
                    fixture.resolve(payload: fixture.payload(mode: mode)) == .unavailable,
                    "noninteractive or unknown mode is silent")
            }
            let payload = String(data: fixture.payload(), encoding: .utf8)!
            let duplicate = Data(
                ("{\"turn_id\":\"\(UUID().uuidString)\"," + payload.dropFirst()).utf8)
            expect(
                fixture.resolve(payload: duplicate) == .unavailable,
                "duplicate routing fields are ambiguous")
            fixture.write(reviewer: "user", metadataID: UUID())
            expect(
                fixture.resolve() == .unavailable,
                "filename alone cannot prove the session identity")
        }
    }

    suite("Codex approval: only bounded regular transcripts below the sessions root are read") {
        withTempDirectory { root in
            let fixture = ApprovalFixture(root: root)
            fixture.write(reviewer: "user")
            let outside = root.appendingPathComponent(fixture.file.lastPathComponent)
            try! FileManager.default.moveItem(at: fixture.file, to: outside)
            expect(
                fixture.resolve(payload: fixture.payload(path: outside.path)) == .unavailable,
                "outside path is rejected")
            try! FileManager.default.createSymbolicLink(
                at: fixture.file, withDestinationURL: outside)
            expect(fixture.resolve() == .unavailable, "leaf symlinks are rejected")
            try! FileManager.default.removeItem(at: fixture.file)
            expect(mkfifo(fixture.file.path, 0o600) == 0, "create isolated FIFO")
            expect(
                fixture.resolve() == .unavailable, "FIFO is rejected without waiting for a writer")
            try! FileManager.default.removeItem(at: fixture.file)
            let linked = fixture.sessions.appendingPathComponent("linked")
            try! FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
            expect(
                fixture.resolve(
                    payload: fixture.payload(
                        path: linked.appendingPathComponent(outside.lastPathComponent).path))
                    == .unavailable,
                "parent symlinks cannot escape the sessions root")
            fixture.write(
                reviewer: "user",
                afterTurn: ApprovalFixture.row(
                    "response_item", ["content": String(repeating: "x", count: (1 << 20) + 1)]))
            expect(fixture.resolve() == .unavailable, "oversized records are bounded")
            let output = ApprovalFixture.row(
                "response_item", ["content": String(repeating: "x", count: 256 << 10)])
            fixture.write(reviewer: "user", afterTurn: String(repeating: output, count: 33))
            expect(
                fixture.resolve() == .unavailable,
                "scan stops at its byte budget instead of searching unbounded history")
        }
    }
}

private struct ApprovalFixture: Sendable {
    let thread = UUID()
    let turn = UUID()
    let sessions: URL
    var file: URL {
        sessions.appendingPathComponent(
            "2026/10/18/rollout-fixture-\(thread.uuidString.lowercased()).jsonl")
    }

    init(root: URL) { sessions = root.appendingPathComponent("sessions") }

    static func row(_ type: String, _ payload: [String: Any]) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]),
            encoding: .utf8)! + "\n"
    }

    @MainActor
    func write(
        reviewer: String?, beforeTurn: String = "", afterTurn: String = "", metadataID: UUID? = nil
    ) {
        var context = ["turn_id": turn.uuidString]
        context["approvals_reviewer"] = reviewer
        writeFixture(
            Self.row("session_meta", ["id": (metadataID ?? thread).uuidString])
                + beforeTurn + Self.row("turn_context", context) + afterTurn, to: file)
    }

    func payload(
        session: UUID? = nil, agent: UUID? = nil, turn: UUID? = nil,
        path: String? = nil, mode: String = "default"
    ) -> Data {
        var fields = [
            "hook_event_name": "PermissionRequest", "permission_mode": mode,
            "session_id": (session ?? thread).uuidString, "turn_id": (turn ?? self.turn).uuidString,
            "transcript_path": path ?? file.path, "tool_input": "private-command-sentinel",
        ]
        fields["agent_id"] = agent?.uuidString
        return try! JSONSerialization.data(withJSONObject: fields)
    }

    func resolve(payload: Data? = nil) -> CodexApprovalRouting {
        CodexApprovalRoutingResolver.resolve(payload ?? self.payload(), sessionsDirectory: sessions)
    }
}
