import ClaudioCore
import ClaudioHookInput
import Foundation

@MainActor
func runCodexApprovalRoutingSuites() {
    suite("Codex approval: same-turn reviewer changes cannot qualify a frozen rollout snapshot") {
        for initialReviewer in ["user", "auto_review"] {
            withTempDirectory { root in
                let fixture = ApprovalFixture(root: root)
                fixture.write(reviewer: initialReviewer)
                let payload = fixture.payload()
                let id = UUID()
                let spawner = HostHookRunnerSpawner()
                let collector = HostEventNoticeCollector()
                let environment = makeHostHookRunnerEnvironment(
                    root: root.appendingPathComponent("helper"), host: .codex,
                    spawner: spawner, fixtureIsReady: true, activeInstallationID: id,
                    sourcePayload: payload,
                    eventNoticeChannel: HostEventNoticeChannel(
                        sourcePayload: payload, receiverEpoch: UUID(),
                        sender: {
                            collector.append($0); return .sent
                        }),
                    codexApprovalRouting: {
                        CodexApprovalRoutingResolver.resolve(
                            $0, sessionsDirectory: fixture.sessions)
                    })

                // turn/settings/update changes only in-memory step settings. Both callbacks
                // carry the same hook fields and frozen turn_context in either switch direction.
                for phase in ["before turn/settings/update", "after turn/settings/update"] {
                    expect(
                        environment.codexApprovalRouting(payload) == .unavailable,
                        "\(initialReviewer) snapshot cannot prove the request reviewer \(phase)")
                    let result = handleHostHook(
                        host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                        environment: environment)
                    expect(
                        result?.playbackResult == .muted && result?.receiptWritten == true,
                        "unconfirmed routing preserves a silent callback receipt \(phase)")
                }
                expect(
                    spawner.callCount == 0 && collector.values.isEmpty,
                    "neither switch direction may qualify a reminder from the initial reviewer")
            }
        }
    }

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

    suite("Codex approval: silent routes do not consume the next confirmed human request") {
        for silentRouting in [CodexApprovalRouting.automatic, .unavailable] {
            withTempDirectory { root in
                let fixture = ApprovalFixture(root: root)
                fixture.write(reviewer: "user")
                let activity = LocalActivitySummaryStore(
                    summaryFile: root.appendingPathComponent("activity/summary.json"),
                    lockFile: root.appendingPathComponent("activity/summary.lock"),
                    pendingDirectory: root.appendingPathComponent("activity/pending"))
                let id = UUID()
                let spawner = HostHookRunnerSpawner()
                let collector = HostEventNoticeCollector()
                @MainActor
                func environment(routing: CodexApprovalRouting) -> HostHookEnvironment {
                    makeHostHookRunnerEnvironment(
                        root: root.appendingPathComponent("helper"), host: .codex,
                        spawner: spawner, fixtureIsReady: true, activeInstallationID: id,
                        sourcePayload: fixture.payload(),
                        eventNoticeChannel: HostEventNoticeChannel(
                            sourcePayload: fixture.payload(), receiverEpoch: UUID(),
                            sender: {
                                collector.append($0); return .sent
                            }),
                        activityStore: activity, codexApprovalRouting: { _ in routing })
                }
                let silent = environment(routing: silentRouting)
                for _ in 0..<9 {
                    let result = handleHostHook(
                        host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                        environment: silent)
                    expect(
                        result?.playbackResult == .muted && result?.receiptWritten == true,
                        "automatic or unconfirmed routing retains only its silent receipt")
                    expect(
                        result?.activityRecordOutcome == .committed,
                        "actual callback activity is preserved")
                }
                expect(
                    spawner.callCount == 0 && collector.values.isEmpty,
                    "silent routing creates neither audio nor banner")
                expect(
                    !FileManager.default.fileExists(
                        atPath: silent.playEnvironment.debounceStateFile.path),
                    "silent routing does not reserve the playback debounce slot")

                // This injects confirmed request evidence at the Core seam. The current host
                // adapter cannot supply .user; changing a rollout snapshot must never do so.
                let confirmed = environment(routing: .user)
                let manual = handleHostHook(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                    environment: confirmed)
                expect(
                    manual?.playbackResult == .played && manual?.receiptWritten == true,
                    "the next confirmed human request is not consumed by silent-route debounce")
                expect(
                    spawner.callCount == 1 && collector.values.count == 1,
                    "confirmed human approval retains sound and one banner")
                expect(
                    collector.values.first?.reason == .permission,
                    "normal permission reason is preserved")
                if case .ready(let summary) = activity.read(now: confirmed.now()).state {
                    expect(
                        summary.buckets.reduce(0) {
                            $0 + $1.count(host: .codex, event: .notification)
                        }
                            == 10,
                        "activity counts callbacks independently from reminder eligibility")
                } else {
                    expect(false, "activity summary remains readable")
                }
                let receipt = confirmed.receiptStore.receiptFile(
                    host: .codex, nativeEvent: "PermissionRequest")!
                let persisted =
                    (try! String(contentsOf: receipt, encoding: .utf8))
                    + ((try? String(contentsOf: confirmed.playEnvironment.logFile, encoding: .utf8))
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
    }

    suite("Codex approval: neither settings records nor child identity prove a request reviewer") {
        withTempDirectory { root in
            let fixture = ApprovalFixture(root: root)
            for initialReviewer in ["user", "auto_review"] {
                let settings = ApprovalFixture.row(
                    "event_msg",
                    [
                        "type": "thread_settings_applied",
                        "thread_id": fixture.thread.uuidString,
                        "thread_settings": ["approvals_reviewer": initialReviewer],
                    ])
                fixture.write(reviewer: initialReviewer, afterTurn: settings)
                expect(
                    fixture.resolve() == .unavailable,
                    "even matching settings cannot prove the reviewer captured for this request")
                expect(
                    fixture.resolve(
                        payload: fixture.payload(session: UUID(), agent: fixture.thread))
                        == .unavailable,
                    "matching child identity does not make initial settings authoritative")
            }
            let production = systemHostHookEnvironment(
                for: .codex, sourcePayload: fixture.payload(),
                codexApprovalRouting: { CodexApprovalRoutingResolver.resolve($0) })
            expect(
                production.codexApprovalRouting(production.sourcePayload) == .unavailable,
                "the production factory preserves the adapter's unconfirmed routing")
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
    func write(reviewer: String, afterTurn: String = "") {
        writeFixture(
            Self.row("session_meta", ["id": thread.uuidString])
                + Self.row(
                    "turn_context", ["turn_id": turn.uuidString, "approvals_reviewer": reviewer])
                + afterTurn, to: file)
    }

    func payload(session: UUID? = nil, agent: UUID? = nil) -> Data {
        var fields: [String: Any] = [
            "hook_event_name": "PermissionRequest", "permission_mode": "default",
            "session_id": (session ?? thread).uuidString, "turn_id": turn.uuidString,
            "transcript_path": file.path, "cwd": sessions.path, "model": "fixture-model",
            "tool_name": "Bash", "tool_input": ["command": "private-command-sentinel"],
        ]
        fields["agent_id"] = agent?.uuidString
        return try! JSONSerialization.data(withJSONObject: fields)
    }

    func resolve(payload: Data? = nil) -> CodexApprovalRouting {
        CodexApprovalRoutingResolver.resolve(payload ?? self.payload(), sessionsDirectory: sessions)
    }
}
