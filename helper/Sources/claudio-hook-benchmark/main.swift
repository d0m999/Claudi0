import ClaudioCore
import Darwin
import Foundation

// This driver exercises Core with synthetic audio/notice endpoints. It is not the CLI.
struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
final class Effects: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var notices = 0
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        starts += 1
        return true
    }
    func send(_ notice: HostEventNotice) -> EventNoticeSendOutcome {
        lock.lock(); defer { lock.unlock() }
        notices += 1
        return .sent
    }
    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, notices)
    }
}
struct InstantRunner: CommandRunning {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        .completed(exitCode: 0, stdout: "benchmark-version\n")
    }
}
final class ObservedRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let base: any CommandRunning
    private var results: [CommandRunResult] = []
    init(base: any CommandRunning) { self.base = base }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        let result = base.run(
            executablePath: executablePath, arguments: arguments, timeout: timeout)
        lock.lock(); results.append(result); lock.unlock()
        return result
    }
    var snapshot: [CommandRunResult] {
        lock.lock(); defer { lock.unlock() }; return results
    }
}
// Invocation-local version probe; persistent cache and signature checks are absent.
final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var stored: String?
    let locator: HostExecutableLocator
    let runner: ObservedRunner
    init(locator: HostExecutableLocator, instant: Bool) {
        self.locator = locator
        let base: any CommandRunning =
            instant
            ? InstantRunner()
            : SystemCommandRunner(environmentOverrides: ["PATH": locator.executableSearchPath])
        runner = ObservedRunner(base: base)
    }
    func value() -> String? {
        lock.lock(); defer { lock.unlock() }
        if !resolved {
            stored = HostActivationScope.claudeCode(
                executableLocator: locator, commandRunner: runner)
            resolved = true
        }
        return stored
    }
}
struct Sample: Encodable {
    let schema = 1
    let evidence: String
    let host: String
    let scenario: String
    let probe: String
    let observer: Bool
    let round: Int
    let pair: Int
    let position: Int
    let nanoseconds: UInt64
    let accepted: Int
    let playback: String
    let playerStarts: Int
    let receipts: Int
    let archives: Int
    let notices: Int
    let activity: Int
    let probeCalls: Int
    let probeResult: String
    let stages: [HookMeasurementContext.Record]
}
let scenarioNames = [
    "full-empty", "full-steady", "muted", "debounced", "not-ready",
    "authorization-off", "gui-exited", "stale-installation", "lock-busy",
    "workspace-plain", "workspace-git", "git-damaged",
]

final class Fixture {
    let root: URL
    let scenario: String
    let mode: String
    let host: HostID
    let nativeEvent = "UserPromptSubmit"
    let id = UUID()
    let effects = Effects()
    let store: HostHookReceiptStore
    let activity: LocalActivitySummaryStore
    let authorization: HostEventAuthorization
    let locator: HostExecutableLocator
    let scope: String
    var heldLock: FileLock?
    var history: URL { store.historyRoot.appendingPathComponent(host.rawValue) }
    init(root: URL, scenario: String, mode: String, host: HostID = .claudeCode) throws {
        self.root = root; self.scenario = scenario; self.mode = mode; self.host = host
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = HostHookReceiptStore(
            receiptsRoot: root.appendingPathComponent("receipts"),
            locksRoot: root.appendingPathComponent("receipt-locks"))
        activity = LocalActivitySummaryStore(
            summaryFile: root.appendingPathComponent("activity.json"),
            lockFile: root.appendingPathComponent("activity.lock"),
            pendingDirectory: root.appendingPathComponent("activity-pending"))
        let config = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs/test")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try Data(
            "{\"id\":\"test\",\"name\":\"Test\",\"author\":\"Benchmark\",\"version\":\"1\",\"events\":{\"task_start\":\"sound.mp3\",\"stop\":\"sound.mp3\",\"notification\":\"sound.mp3\",\"subagent_stop\":\"sound.mp3\",\"stop_failure\":\"sound.mp3\"}}"
                .utf8
        )
        .write(to: packs.appendingPathComponent("manifest.json"), options: .atomic)
        try Data("synthetic audio; never played".utf8).write(
            to: packs.appendingPathComponent("sound.mp3"), options: .atomic)
        var configuration = ClaudioConfig(
            selectedPack: scenario == "not-ready" ? "absent" : "test",
            eventsEnabled: ["task_start": scenario != "muted"])
        let cwd = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        if scenario == "workspace-git" || scenario == "git-damaged" {
            let result = SystemCommandRunner().run(
                executablePath: "/usr/bin/git", arguments: ["init", "-q", cwd.path], timeout: 2)
            guard case .completed(0, _) = result else {
                throw Failure(message: "git fixture initialization")
            }
        }
        if scenario.hasPrefix("workspace-") || scenario == "git-damaged" {
            let directory = try WorkspaceDirectoryResolver.resolve(cwd.path).get()
            configuration.workspaceRules = [
                WorkspaceSoundRule(
                    directory: directory, surfaces: [host.surfaceID],
                    profile: WorkspaceSoundProfile(selectedPack: "test", volume: 0))
            ]
            if scenario == "git-damaged" {
                try FileManager.default.removeItem(at: cwd.appendingPathComponent(".git"))
                try Data("gitdir: /nonexistent/benchmark-git\n".utf8).write(
                    to: cwd.appendingPathComponent(".git"), options: .atomic)
            }
        }
        try JSONEncoder().encode(configuration).write(to: config, options: .atomic)
        let intents = HostIntegrationIntentStore(
            configFile: config, lockFile: root.appendingPathComponent("config.lock"))
        _ = try intents.setEnabled(
            surface: host.surfaceID, enabled: scenario != "authorization-off"
        )
        .get()
        let runs = HostGUIRunRegistry(
            file: root.appendingPathComponent("gui-run.json"),
            authorizationLockFile: intents.authorizationLockFile)
        let run = try runs.register().get()
        if scenario == "gui-exited" { _ = runs.revoke(runID: run.runID) }
        authorization = HostEventAuthorization(intents: intents, runs: runs)
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = tools.appendingPathComponent("claude")
        let delay = mode == "delayed" ? "/bin/sleep 0.3\n" : ""
        let script =
            mode == "timeout"
            ? "#!/bin/sh\nexec /usr/bin/perl -e '$SIG{TERM}=\"IGNORE\"; sleep 5'\n"
            : "#!/bin/sh\n\(delay)printf 'benchmark-version\\n'\n"
        try Data(script.utf8).write(to: tool, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        locator = mode == "real" ? .standard() : HostExecutableLocator(searchDirectories: [tools])
        let resolvedScope: String?
        if mode == "real" {
            resolvedScope = Probe(locator: locator, instant: false).value()
        } else {
            resolvedScope = HostActivationScope.fingerprint(
                host: host, hostVersion: "benchmark-version")
        }
        guard let scope = resolvedScope else { throw Failure(message: "host version unavailable") }
        self.scope = scope
        _ = try store.activate(host: host, installationID: id, scopeFingerprint: scope).get()
        if scenario != "full-empty" {
            for offset in 0..<20 {
                let receipt = HostHookReceipt(
                    installationID: id, host: host, nativeEvent: nativeEvent,
                    semanticEvent: .taskStart,
                    timestamp: Date().addingTimeInterval(Double(offset) - 30),
                    playbackResult: .muted)
                _ = try store.store(
                    receipt, expectedScopeFingerprint: scope, scopeFingerprint: { scope }
                ).get()
            }
        }
        if scenario == "lock-busy" {
            let held = FileLock(path: root.appendingPathComponent("play.lock").path)
            try require(held.attemptLock() == .acquired, "lock fixture")
            heldLock = held
        }
    }
    func activityCount() -> UInt64 {
        guard case .ready(let document) = activity.read().state else { return 0 }
        return document.buckets.reduce(0) { $0 + $1.count(host: host, event: .taskStart) }
    }
    func run(
        observer: Bool, round: Int, pair: Int, position: Int, contract: Bool = false
    ) throws
        -> Sample
    {
        let mode = self.mode
        // All fixture preparation and result validation are outside the timed interval.
        let now = Date()
        let state = root.appendingPathComponent("task-start.state")
        if scenario == "debounced" {
            try Data(String(now.timeIntervalSince1970).utf8).write(to: state, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: state)
        }
        if scenario == "full-empty" { try? FileManager.default.removeItem(at: history) }
        let beforeFiles = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
        let beforeEffects = effects.counts
        let beforeActivity = activityCount()
        let beforeReceipt = try? Data(
            contentsOf: store.receiptFile(host: host, nativeEvent: nativeEvent)!)
        let payload = try JSONSerialization.data(withJSONObject: [
            "cwd": root.appendingPathComponent("workspace").path
        ])
        let probe = Probe(locator: locator, instant: mode == "instant")
        let play = PlayEnvironment(
            surfaceID: host.surfaceID, afplayPath: "/synthetic/afplay",
            lockFile: root.appendingPathComponent("play.lock"),
            configFile: root.appendingPathComponent("config.json"),
            userPacksDirectory: root.appendingPathComponent("packs"),
            systemSoundDirectory: root.appendingPathComponent("system-sounds"),
            spawner: effects, debounceStateFile: root.appendingPathComponent("play.state"),
            now: { now },
            logFile: root.appendingPathComponent("log"),
            logLockFile: root.appendingPathComponent("log.lock"))
        let environment = HostHookEnvironment(
            host: host, authorization: authorization,
            playEnvironment: play, receiptStore: store, activityStore: activity,
            eventNoticeChannel: HostEventNoticeChannel(
                sourcePayload: payload, receiverEpoch: UUID(),
                sender: { [effects] in effects.send($0) }),
            scopeFingerprint: { probe.value() }, now: { now })
        let context = observer ? HookMeasurementContext() : nil
        let start = contract ? 0 : DispatchTime.now().uptimeNanoseconds
        let outcome = autoreleasepool {
            HookMeasurementContext.$current.withValue(context) {
                handleHostHook(
                    host: host, nativeEvent: nativeEvent,
                    installationID: scenario == "stale-installation" ? UUID() : id,
                    environment: environment)
            }
        }
        let duration = contract ? 0 : DispatchTime.now().uptimeNanoseconds - start
        let rejected =
            mode == "timeout"
            || ["authorization-off", "gui-exited", "stale-installation"].contains(scenario)
        let authorized = !["authorization-off", "gui-exited"].contains(scenario)
        let probeResults = probe.runner.snapshot
        try require(
            probeResults.count
                == (authorized ? 1 : 0),
            "version probe count mismatch")
        let probeResult: String
        if !authorized {
            probeResult = "not-invoked"
            try require(outcome == nil, "authorization rejection returned an accepted outcome")
        } else if mode == "timeout" {
            try require(
                probeResults == [.timedOut], "timeout fixture did not confirm child cleanup")
            probeResult = "timed-out"
        } else {
            guard case .completed(0, _) = probeResults[0] else {
                throw Failure(message: "successful version probe required")
            }
            probeResult = "completed"
        }
        let expected: HostHookPlaybackResult =
            switch scenario {
            case "muted": .muted
            case "debounced", "lock-busy": .debounced
            case "not-ready", "git-damaged", "stale-installation": .notReady
            default: .played
            }
        let receipt = try? Data(
            contentsOf: store.receiptFile(host: host, nativeEvent: nativeEvent)!)
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
        let starts = effects.counts.0 - beforeEffects.0
        let notices = effects.counts.1 - beforeEffects.1
        let archives = files.subtracting(beforeFiles).count
        let activities = activityCount() - beforeActivity
        try require(activities == (rejected ? 0 : 1), "activity disk count mismatch")
        try require(context?.droppedRecordCount ?? 0 == 0, "measurement overflow")
        if rejected {
            try require(
                starts == 0 && notices == 0 && receipt == beforeReceipt && files == beforeFiles,
                "rejection produced effects")
            try require(outcome?.receiptWritten != true, "rejection published receipt")
        } else {
            try require(
                outcome?.playbackResult == expected && outcome?.receiptWritten == true,
                "unexpected playback/receipt in \(scenario)")
            try require(outcome?.activityRecordOutcome == .committed, "activity not committed")
            try require(
                starts == (expected == .played ? 1 : 0) && notices == 1 && archives == 1,
                "side-effect count mismatch")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            let decoded = try decoder.decode(HostHookReceipt.self, from: receipt!)
            try require(
                decoded.installationID == id && decoded.playbackResult == expected,
                "receipt identity/result mismatch")
            try require(
                decoded.timestamp.timeIntervalSince1970 == now.timeIntervalSince1970,
                "receipt epoch precision mismatch")
            try require(
                files.count == (scenario == "full-empty" ? 1 : 20), "history retention changed")
        }
        if observer {
            let accepted = context!.snapshot.filter { $0.result == .accepted }.count
            try require(accepted == (rejected ? 0 : 1), "observer acceptance count mismatch")
            try require(
                context!.snapshot.filter { $0.result == .receiptPublished }.count
                    == (rejected ? 0 : 1), "observer receipt count mismatch")
            if rejected {
                let reason: HookMeasurementContext.Result =
                    !authorized
                    ? .rejectedAuthorization
                    : mode == "timeout"
                        ? .rejectedVersion : .rejectedInstallation
                try require(
                    context!.snapshot.filter { $0.result == reason }.count == 1,
                    "observer rejection reason mismatch")
            }
        }
        return Sample(
            evidence: "core-isolated",
            host: host.rawValue, scenario: scenario, probe: mode, observer: observer, round: round,
            pair: pair,
            position: position,
            nanoseconds: duration, accepted: rejected ? 0 : 1,
            playback: rejected ? "rejected" : expected.rawValue, playerStarts: starts,
            receipts: rejected ? 0 : 1, archives: archives, notices: notices,
            activity: Int(activities),
            probeCalls: probeResults.count,
            probeResult: probeResult,
            stages: context?.snapshot ?? [])
    }
}
func runContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-benchmark-contract-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var branches: [String: String] = [:]
    var verified = 0
    for scenario in scenarioNames {
        let fixture = try Fixture(
            root: root.appendingPathComponent(scenario), scenario: scenario, mode: "instant")
        for (position, observer) in [false, true].enumerated() {
            let row = try fixture.run(
                observer: observer, round: 0, pair: 0, position: position, contract: true)
            try require(row.nanoseconds == 0, "contract must not collect total durations")
            branches[scenario] = row.playback
            verified += 1
        }
    }
    print(
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "evidence": "synthetic-branch-contract", "cases": verified,
                    "branches": branches,
                    "performanceMeasured": false, "realHostCallbacks": false, "audioPlayed": false,
                ], options: .sortedKeys), as: UTF8.self))
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--contract"] { try runContract(); return }
    if arguments.first == "--fingerprint", arguments.count == 3,
        let host = HostID(rawValue: arguments[1]),
        let value = HostActivationScope.fingerprint(host: host, hostVersion: arguments[2])
    {
        print(value); return
    }
    let allowed = Set(["--samples", "--warmup", "--rounds", "--probe", "--scenario"])
    try require(arguments.count.isMultiple(of: 2), "invalid arguments")
    var options: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        try require(allowed.contains(key) && options[key] == nil, "invalid arguments")
        options[key] = arguments[index + 1]
    }
    let count = Int(options["--samples"] ?? "100") ?? 0
    let warmup = Int(options["--warmup"] ?? "10") ?? -1
    let rounds = Int(options["--rounds"] ?? "3") ?? 0
    let mode = options["--probe"] ?? "normal"
    let selected = options["--scenario"] ?? "all"
    try require(count > 0 && warmup >= 0 && rounds > 0, "invalid sample configuration")
    try require(
        ["instant", "normal", "delayed", "real", "compare", "timeout"].contains(mode),
        "invalid probe")
    try require(selected == "all" || scenarioNames.contains(selected), "invalid scenario")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-benchmark-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let seed: UInt64 = 0xC1A0D10
    for scenario in selected == "all" ? scenarioNames : [selected] {
        for round in 0..<rounds {
            let modes = mode == "compare" ? ["normal", "instant", "delayed", "real"] : [mode]
            var fixtures: [String: Fixture] = [:]
            for value in modes {
                fixtures[value] = try autoreleasepool {
                    try Fixture(
                        root: root.appendingPathComponent("\(scenario)-\(round)-\(value)"),
                        scenario: scenario, mode: value)
                }
            }
            for pair in -warmup..<count {
                let first = (UInt64(pair + warmup + round) &+ seed) % 2 == 0
                for mode in first ? modes : modes.reversed() {
                    for (position, enabled) in [first, !first].enumerated() {
                        try autoreleasepool {
                            let sample = try fixtures[mode]!.run(
                                observer: enabled, round: round, pair: pair, position: position)
                            if pair >= 0 {
                                print(String(decoding: try encoder.encode(sample), as: UTF8.self))
                            }
                        }
                    }
                }
            }
        }
    }
}
do { try main() } catch {
    let message = (error as? Failure)?.message ?? "fixture setup or validation failed"
    FileHandle.standardError.write(Data("benchmark failed: \(message)\n".utf8)); exit(1)
}
