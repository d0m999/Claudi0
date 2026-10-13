import ClaudioCore
import Darwin
import Foundation

// Component failure diagnostic, deliberately separate from handleHostHook and CLI evidence.
// Existing CommandRunning/directoryResolver seams control timeouts without changing Git identity.
private final class TimeoutGitRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        let timeout: TimeInterval
        let result: CommandRunResult
        let trace: URL
    }
    private let lock = NSLock()
    private var calls: [Call] = []
    let root: URL
    init(root: URL) { self.root = root }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        lock.lock(); defer { lock.unlock() }
        guard executablePath == "/usr/bin/env",
            arguments.prefix(5) == [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1",
                "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0",
            ], arguments.contains("--git-common-dir"), arguments.contains("--show-toplevel")
        else { return .launchFailed }
        let trace = root.appendingPathComponent("child-\(calls.count)")
        let script =
            "$SIG{TERM}='IGNORE'; open(F,'>',$ARGV[0]) or die; print F $$; close F; sleep 5"
        let result = SystemCommandRunner().run(
            executablePath: "/usr/bin/perl", arguments: ["-e", script, trace.path],
            timeout: timeout)
        calls.append(Call(timeout: timeout, result: result, trace: trace))
        return result
    }
    func validate() throws {
        try require(calls.map(\.timeout) == [0.5, 2.0], "Git timeout/retry count changed")
        for call in calls {
            try require(call.result == .timedOut, "Git timeout cleanup did not succeed")
            let value = try String(contentsOf: call.trace, encoding: .utf8)
            guard let pid = Int32(value) else {
                throw Failure(message: "missing Git child identity")
            }
            errno = 0
            try require(kill(pid, 0) == -1 && errno == ESRCH, "Git timed-out child remains alive")
        }
    }
}

private struct GitTimeoutSample: Encodable {
    let evidence = "core-component-failure-diagnostic"
    let boundary = "version-resolution-plus-workspace-profile; not hook or CLI"
    let observer: Bool
    let round: Int
    let pair: Int
    let nanoseconds: UInt64
    let versionProbeCalls = 1
    let gitProbeCalls = 2
    let gitTimeouts = [0.5, 2.0]
    let versionFixtureDelaySeconds = 0.9
    let versionFixtureElapsedNanoseconds: UInt64
    let childrenReaped = true
    let workspaceFailedClosed = true
    let stages: [HookMeasurementContext.Record]
}

func runGitTimeoutDiagnostic(samples: Int, warmup: Int, rounds: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-git-timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = root.appendingPathComponent("tools")
    let cwd = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: cwd.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let tool = tools.appendingPathComponent("claude")
    // Single-process fixture avoids a shell/sleep descendant. Its monotonic trace lets
    // failures distinguish injected delay from launch/wait behavior. Not a host layout.
    let versionTrace = root.appendingPathComponent("version-trace")
    try Data(
        """
        #!/usr/bin/perl
        use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
        open(F, '>', '\(versionTrace.path)') or die;
        print F clock_gettime(CLOCK_MONOTONIC), "\\n"; close F;
        sleep 0.9;
        open(F, '>>', '\(versionTrace.path)') or die;
        print F clock_gettime(CLOCK_MONOTONIC), "\\n"; close F;
        print "benchmark-version\\n";

        """.utf8
    ).write(to: tool, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
    // Newly created scripts can enter user code hundreds of milliseconds after run().
    // Keep this untimed fixture preparation distinct from the real 1s probe below.
    try require(
        SystemCommandRunner().run(executablePath: tool.path, arguments: ["--version"], timeout: 2)
            == .completed(exitCode: 0, stdout: "benchmark-version\n"),
        "version fixture preparation failed")
    let locator = HostExecutableLocator(searchDirectories: [tools])
    var config = ClaudioConfig(selectedPack: "default")
    config.workspaceRules = [
        WorkspaceSoundRule(
            directory: WorkspaceDirectory(
                kind: .git, path: cwd.path,
                commonGitDirectory: cwd.appendingPathComponent(".git").path),
            surfaces: [.claudeCode],
            profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0))
    ]
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for round in 0..<rounds {
        for pair in -warmup..<samples {
            let first = (UInt64(pair + warmup + round) &+ 0xC1A0D10) % 2 == 0
            for observer in [first, !first] {
                let version = ObservedRunner(base: SystemCommandRunner())
                let git = TimeoutGitRunner(root: root)
                let context = observer ? HookMeasurementContext() : nil
                let started = DispatchTime.now().uptimeNanoseconds
                let result = HookMeasurementContext.$current.withValue(context) {
                    let scope = HostActivationScope.claudeCode(
                        executableLocator: locator, commandRunner: version)
                    guard scope != nil else {
                        return (
                            scope,
                            Result<ResolvedSoundProfile, WorkspaceSoundError>.failure(.invalidRule)
                        )
                    }
                    let profile = HookMeasurementContext.measure(.workspaceAndSound) {
                        config.resolveSoundProfile(for: .claudeCode, cwd: cwd.path) {
                            WorkspaceDirectoryResolver.resolve($0, commandRunner: git)
                        }
                    }
                    return (scope, profile)
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                try require(version.snapshot.count == 1, "version call count changed")
                guard result.0 != nil else {
                    let reason: String
                    switch version.snapshot[0] {
                    case .completed(let code, let output):
                        reason = "exit=\(code); output-bytes=\(output.utf8.count)"
                    case .timedOut: reason = "timed-out"
                    case .cleanupFailed: reason = "cleanup-failed"
                    case .launchFailed: reason = "launch-failed"
                    }
                    let traceLines =
                        (try? String(contentsOf: versionTrace, encoding: .utf8))?
                        .split(separator: "\n").count ?? 0
                    throw Failure(
                        message:
                            "near-deadline version failed: \(reason); trace-lines=\(traceLines)")
                }
                try require(
                    result.1 == .failure(.invalidRule), "Git failure selected a fallback profile")
                let trace = try String(contentsOf: versionTrace, encoding: .utf8)
                    .split(separator: "\n").compactMap { Double($0) }
                try require(
                    trace.count == 2 && trace[1] >= trace[0], "version fixture trace invalid")
                try git.validate()
                try require(
                    context?.droppedRecordCount ?? 0 == 0, "Git diagnostic observer overflow")
                if pair >= 0 {
                    let sample = GitTimeoutSample(
                        observer: observer, round: round, pair: pair, nanoseconds: elapsed,
                        versionFixtureElapsedNanoseconds: UInt64(
                            (trace[1] - trace[0]) * 1_000_000_000),
                        stages: context?.snapshot ?? [])
                    print(String(decoding: try encoder.encode(sample), as: UTF8.self))
                }
            }
        }
    }
}
