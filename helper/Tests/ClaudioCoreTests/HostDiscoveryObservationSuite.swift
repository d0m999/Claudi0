import ClaudioCore
import Darwin
import Foundation

private let observationVersion = "2.1.282 (fixture)"
private let observationSuccess = CommandRunResult.completed(
    exitCode: 0, stdout: observationVersion)
private let observationHosts: [HostID] = [.claudeCode, .codex]

/// All mutable state is guarded by the lock, including the response sequence.
private final class ObservationRunner: CommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let path: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var responses = [observationSuccess]
    private var responseIndex = 0
    private var invocations: [Invocation] = []

    func respond(with values: [CommandRunResult]) {
        precondition(!values.isEmpty)
        lock.lock()
        defer { lock.unlock() }
        responses = values
        responseIndex = 0
        invocations = []
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(.init(path: executablePath, arguments: arguments, timeout: timeout))
        let result = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        return result
    }

    var calls: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

/// Holds the first probe until a second probe enters, proving genuine overlap.
private final class ObservationOverlapRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let firstCanReturn = DispatchSemaphore(value: 0)
    private var entered = 0
    private var overlapped = false
    private var invocationCount = 0

    var didOverlap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overlapped
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        lock.lock()
        invocationCount += 1
        entered += 1
        let arrival = entered
        lock.unlock()

        if arrival == 1 {
            let signaled = firstCanReturn.wait(timeout: .now() + 5) == .success
            lock.lock()
            if signaled { overlapped = true }
            lock.unlock()
        } else if arrival == 2 {
            firstCanReturn.signal()
        }
        return observationSuccess
    }
}

private struct ObservationFixture: Sendable {
    let root: URL

    var claudioRoot: URL { root.appendingPathComponent(".claudio") }
    var binary: String { claudioRoot.appendingPathComponent("bin/claudio").path }
    var locator: HostExecutableLocator {
        .init(searchDirectories: [root.appendingPathComponent("bin")])
    }
    var receipts: HostHookReceiptStore {
        .init(
            receiptsRoot: claudioRoot.appendingPathComponent("receipts"),
            locksRoot: claudioRoot.appendingPathComponent("receipt-locks"),
            installationsRoot: claudioRoot.appendingPathComponent("installations"),
            installationLocksRoot: claudioRoot.appendingPathComponent("installation-locks"))
    }

    func file(_ host: HostID) -> URL {
        root.appendingPathComponent(host.rawValue)
            .appendingPathComponent(host == .codex ? "hooks.json" : "settings.json")
    }

    func call(_ host: HostID) -> URL {
        root.appendingPathComponent(host == .claudeCode ? "bin/claude" : "bin/codex")
    }

    @MainActor
    func prepare() {
        writeFixture("fixture helper", to: URL(fileURLWithPath: binary))
        for host in observationHosts {
            let target = root.appendingPathComponent("programs/\(host.rawValue)")
            writeFixture("#!/bin/sh\nprintf '2.1.282 (fixture)\\n'\n", to: target)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: target.path)
            try! FileManager.default.createDirectory(
                at: call(host).deletingLastPathComponent(), withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(
                atPath: call(host).path, withDestinationPath: target.path)
        }
    }

    func adapter(_ host: HostID, runner: any CommandRunning) -> any HostIntegrationAdapter {
        let observe: @Sendable () -> HostDiscoveryObservation = {
            HostDiscovery.observeCLI(host, locator: locator, runner: runner)
        }
        let lock = claudioRoot.appendingPathComponent("\(host.rawValue).lock")
        switch host {
        case .claudeCode:
            return ClaudeCodeIntegrationAdapter(
                environment: .init(
                    settingsFile: file(host), lockFile: lock, claudioBinaryPath: binary,
                    claudioRoot: claudioRoot.path, receiptStore: receipts, observeHost: observe))
        case .codex:
            return CodexIntegrationAdapter(
                environment: .init(
                    hooksFile: file(host), lockFile: lock,
                    configFile: root.appendingPathComponent("codex/config.toml"),
                    legacyNotifyWrapper: claudioRoot.appendingPathComponent("bin/codex-notify"),
                    claudioBinaryPath: binary, claudioRoot: claudioRoot.path,
                    receiptStore: receipts, observeHost: observe))
        default: preconditionFailure("CLI observation fixture only supports Claude/Codex")
        }
    }

    func doctor(
        claude: any CommandRunning, codex: any CommandRunning
    ) -> DoctorIntegrationsEnvironment {
        .init(
            claudeSettingsFile: file(.claudeCode), codexHooksFile: file(.codex),
            workBuddySettingsFile: file(.workBuddy), claudioRoot: claudioRoot.path,
            claudioBinaryPath: binary, receiptStore: receipts,
            observeClaude: {
                HostDiscovery.observeCLI(.claudeCode, locator: locator, runner: claude)
            },
            observeCodex: { HostDiscovery.observeCLI(.codex, locator: locator, runner: codex) },
            workBuddyAvailability: { .notInstalled }, workBuddyScopeFingerprint: { nil },
            additionalHosts: [])
    }
}

private struct ObservationDiskEntry: Equatable {
    let mode: mode_t
    let contents: Data
}

/// lstat preserves link identity; fixture links are never followed for this read-only check.
private func observationDiskState(_ root: URL) -> [String: ObservationDiskEntry] {
    var entries: [String: ObservationDiskEntry] = [:]
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator {
        var info = stat()
        precondition(lstat(url.path, &info) == 0)
        let contents: Data
        switch info.st_mode & S_IFMT {
        case S_IFREG: contents = try! Data(contentsOf: url)
        case S_IFLNK:
            contents = Data(
                try! FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        default: contents = Data()
        }
        entries[String(url.path.dropFirst(root.path.count))] = .init(
            mode: info.st_mode, contents: contents)
    }
    return entries
}

@MainActor
private func withObservationFixture(_ body: (ObservationFixture) async -> Void) async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-observation-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ObservationFixture(root: root)
    fixture.prepare()
    await body(fixture)
}

@MainActor
func runHostDiscoveryObservationSuites() async {
    await asyncSuite("CLI observation: one live probe per inspection, without disk mutation") {
        await withObservationFixture { fixture in
            for host in observationHosts {
                let runner = ObservationRunner()
                let adapter = fixture.adapter(host, runner: runner)
                let missing = await adapter.inspect(runtime: .ready)
                expect(
                    missing.configuration == .notConfigured, "\(host) fixture starts unconfigured")
                expect(runner.calls.count == 1, "\(host) unconfigured inspection probes once")
                runner.respond(with: [observationSuccess])
                guard case .success(let connected) = await adapter.connect(runtime: .ready),
                    connected.configuration == .configured
                else { expect(false, "\(host) connection fixture"); continue }
                expect(
                    runner.calls.count == 3,
                    "\(host) connect keeps two preflights plus fresh inspect")

                runner.respond(with: [observationSuccess])
                let before = observationDiskState(fixture.root)
                let first = await adapter.inspect(runtime: .ready)
                let second = await adapter.inspect(runtime: .ready)
                expect(
                    first == second && first.configuration == .configured, "\(host) stable snapshot"
                )
                expect(
                    runner.calls.count == 2,
                    "\(host) two inspections require exactly two live probes")
                expect(
                    runner.calls.allSatisfy {
                        $0
                            == .init(
                                path: fixture.call(host).path, arguments: ["--version"], timeout: 1)
                    }, "\(host) preserves original shim path, arguments and deadline")
                expect(
                    observationDiskState(fixture.root) == before,
                    "\(host) inspection preserves disk bytes/modes")

                let overlap = ObservationOverlapRunner()
                let concurrentAdapter = fixture.adapter(host, runner: overlap)
                let left = Task.detached { await concurrentAdapter.inspect(runtime: .ready) }
                let right = Task.detached { await concurrentAdapter.inspect(runtime: .ready) }
                let snapshots = await [left.value, right.value]
                expect(
                    snapshots.allSatisfy { $0 == first }, "\(host) concurrent inspection results")
                expect(overlap.didOverlap, "\(host) concurrent inspections actually overlap")
                expect(
                    overlap.calls == 2,
                    "\(host) concurrent inspections never share observations")

                writeFixture("{broken", to: fixture.file(host))
                runner.respond(with: [observationSuccess])
                let malformed = await adapter.inspect(runtime: .ready)
                if case .unreadable = malformed.configuration {
                } else {
                    expect(false, "\(host) malformed configuration remains unreadable")
                }
                expect(
                    runner.calls.count == 1,
                    "\(host) malformed configuration still probes only once")
                try! FileManager.default.removeItem(at: fixture.call(host))
                runner.respond(with: [observationSuccess])
                let absent = await adapter.inspect(runtime: .ready)
                expect(
                    absent.availability == .notInstalled && runner.calls.isEmpty,
                    "\(host) missing executable: zero probes")
            }
        }
    }

    await asyncSuite(
        "CLI observation: failures do not retry or reuse success; later checks recover"
    ) {
        await withObservationFixture { fixture in
            for host in observationHosts {
                let runner = ObservationRunner()
                let adapter = fixture.adapter(host, runner: runner)
                guard case .success(let connected) = await adapter.connect(runtime: .ready),
                    let installationID = connected.installationID,
                    let scope = fixture.receipts.currentInstallationScopeFingerprint(host: host),
                    let nativeEvent = HostCapabilityCatalog.binding(host: host, event: .taskStart)?
                        .nativeEvent
                else {
                    expect(false, "\(host) connection fixture"); continue
                }
                let receipt = HostHookReceipt(
                    installationID: installationID, host: host, nativeEvent: nativeEvent,
                    semanticEvent: .taskStart, timestamp: Date(), playbackResult: .played)
                expect(
                    fixture.receipts.store(
                        receipt, expectedScopeFingerprint: scope, scopeFingerprint: { scope })
                        == .success(.written), "\(host) current receipt fixture")
                let active = await adapter.inspect(runtime: .ready)
                expect(
                    active.latestReceipt != nil, "\(host) fixture has current activation evidence")
                let failures: [CommandRunResult] = [
                    .timedOut, .launchFailed, .cleanupFailed(pid: 123),
                    .completed(exitCode: 1, stdout: observationVersion),
                    .completed(exitCode: 0, stdout: " \n\t"),
                    .completed(exitCode: 0, stdout: String(repeating: "x", count: 257)),
                ]
                for failure in failures {
                    runner.respond(with: [failure, observationSuccess])
                    let before = observationDiskState(fixture.root)
                    let failed = await adapter.inspect(runtime: .ready)
                    expect(
                        failed.availability.unavailabilityReason != nil,
                        "\(host) failed version is unavailable")
                    expect(
                        failed.configuration != .configured && failed.latestReceipt == nil,
                        "\(host) no stale scope/evidence")
                    expect(runner.calls.count == 1, "\(host) no immediate retry")
                    let recovered = await adapter.inspect(runtime: .ready)
                    expect(
                        recovered.configuration == .configured,
                        "\(host) next inspection can recover")
                    expect(runner.calls.count == 2, "\(host) recovery performs its own probe")
                    expect(
                        observationDiskState(fixture.root) == before,
                        "\(host) failed/recovered checks remain read-only")
                }

                runner.respond(with: [.completed(exitCode: 0, stdout: "2.2.0 (fixture)")])
                let oldID = fixture.receipts.currentInstallationID(host: host)
                let changed = await adapter.inspect(runtime: .ready)
                if case .conflict = changed.configuration {
                } else {
                    expect(false, "\(host) changed version invalidates old installation")
                }
                expect(
                    changed.latestReceipt == nil, "\(host) changed version invalidates old receipt")
                guard case .success(let repaired) = await adapter.connect(runtime: .ready) else {
                    expect(false, "\(host) explicit repair"); continue
                }
                expect(
                    repaired.configuration == .configured && repaired.installationID != oldID,
                    "\(host) repair publishes new generation")
            }
        }
    }

    await asyncSuite(
        "CLI observation: separate discovery/scope qualification and publication lease"
    ) {
        await withObservationFixture { fixture in
            for host in observationHosts {
                let runner = ObservationRunner()
                let cases: [(String, Bool, Bool)] = [
                    (" \n2.1.282  (fixture)\t", true, true),
                    ("not-a-version", false, true),
                    ("1.0.0 " + String(repeating: "x", count: 246), true, true),
                    ("1.0.0 " + String(repeating: "x", count: 247), true, host == .claudeCode),
                    ("1.0.0 " + String(repeating: "x", count: 250), true, host == .claudeCode),
                    ("1.0.0 " + String(repeating: "x", count: 251), false, false),
                ]
                for (output, available, hasScope) in cases {
                    runner.respond(with: [.completed(exitCode: 0, stdout: output)])
                    let observed = HostDiscovery.observeCLI(
                        host, locator: fixture.locator, runner: runner)
                    expect(
                        (observed.availability == .available) == available,
                        "\(host) discovery qualification: \(output.utf8.count) bytes")
                    expect(
                        (observed.scopeFingerprint != nil) == hasScope,
                        "\(host) scope qualification: \(output.utf8.count) bytes")
                    expect(runner.calls.count == 1, "\(host) qualification shares one probe")
                    if output.hasPrefix(" \n") {
                        let version =
                            host == .codex ? "cli=\(observationVersion)" : observationVersion
                        expect(
                            observed.scopeFingerprint
                                == HostActivationScope.fingerprint(host: host, hostVersion: version),
                            "\(host) full scope bytes and Codex prefix preserved")
                    }
                }
                runner.respond(with: [observationSuccess])
                let context = HostPublicationContext.unconditional(
                    lockFile: fixture.root.appendingPathComponent("authorization.lock"))
                expect(context.acquire() == .allowed, "fixture publication lease")
                HostPublicationContext.$current.withValue(context) {
                    let observed = HostDiscovery.observeCLI(
                        host, locator: fixture.locator, runner: runner)
                    expect(
                        observed.availability != .available && observed.scopeFingerprint == nil,
                        "\(host) lease fails closed")
                    expect(runner.calls.isEmpty, "\(host) no subprocess under publication lease")
                }
                context.release()
            }
            let runner = ObservationRunner()
            let unsupported = HostDiscovery.observeCLI(
                .workBuddy, locator: fixture.locator, runner: runner)
            expect(
                unsupported.availability == .notInstalled && unsupported.scopeFingerprint == nil
                    && runner.calls.isEmpty, "non-CLI observation never probes")
        }
    }

    await asyncSuite("CLI observation: connection completion always observes after publication") {
        await withObservationFixture { fixture in
            for host in observationHosts {
                let runner = ObservationRunner()
                let adapter = fixture.adapter(host, runner: runner)
                runner.respond(with: [.timedOut, observationSuccess])
                let rejected = await adapter.connect(runtime: .ready)
                if case .failure(.hostUnavailable) = rejected {
                } else {
                    expect(false, "\(host) failed preflight refuses connection")
                }
                expect(runner.calls.count == 1, "\(host) preflight does not retry")
                expect(
                    !FileManager.default.fileExists(atPath: fixture.file(host).path),
                    "\(host) failed preflight does not write configuration")
                expect(
                    fixture.receipts.currentInstallationID(host: host) == nil,
                    "\(host) failed preflight does not activate")

                for completion in [
                    CommandRunResult.timedOut, .completed(exitCode: 0, stdout: "2.2.0 (fixture)"),
                ] {
                    runner.respond(with: [observationSuccess, observationSuccess, completion])
                    guard case .success(let snapshot) = await adapter.connect(runtime: .ready)
                    else {
                        expect(false, "\(host) successful write returns completion snapshot");
                        continue
                    }
                    expect(runner.calls.count == 3, "\(host) completion must re-probe")
                    expect(
                        snapshot.configuration != .configured,
                        "\(host) completion does not reuse preflight facts")
                }
            }
        }
    }

    await asyncSuite(
        "CLI observation: doctor forwards one observation per host and isolates failures"
    ) {
        await withObservationFixture { fixture in
            let claude = ObservationRunner()
            let codex = ObservationRunner()
            for (host, runner) in [(HostID.claudeCode, claude), (.codex, codex)] {
                guard
                    case .success = await fixture.adapter(host, runner: runner).connect(
                        runtime: .ready)
                else {
                    expect(false, "\(host) doctor connection fixture"); return
                }
                runner.respond(with: [observationSuccess])
            }
            let environment = fixture.doctor(claude: claude, codex: codex)
            let before = observationDiskState(fixture.root)
            let healthy = hostIntegrationDoctorResults(environment: environment)
            expect(
                claude.calls.count == 1 && codex.calls.count == 1,
                "doctor integration probes each CLI exactly once")
            expect(
                observationDiskState(fixture.root) == before,
                "doctor integration checks remain read-only")
            claude.respond(with: [.timedOut, observationSuccess])
            codex.respond(with: [observationSuccess])
            let failed = hostIntegrationDoctorResults(environment: environment)
            expect(
                claude.calls.count == 1 && codex.calls.count == 1, "doctor failure does not retry")
            expect(healthy.count == failed.count, "doctor failure preserves all host rows")
            expect(
                zip(healthy, failed).filter { $0 != $1 }.count == 1,
                "one failed host changes only its own row")

            claude.respond(with: [observationSuccess])
            codex.respond(with: [observationSuccess])
            let compatibility = ObservationRunner()
            _ = runDoctorChecks(
                environment: .init(
                    afplayPath: fixture.call(.claudeCode).path,
                    settingsFile: fixture.file(.claudeCode),
                    configFile: fixture.claudioRoot.appendingPathComponent("config.json"),
                    userPacksDirectory: fixture.claudioRoot.appendingPathComponent("packs"),
                    bundledPacksDirectory: nil,
                    logFile: fixture.claudioRoot.appendingPathComponent("claudio.log"),
                    claudioBinaryPath: fixture.binary, commandRunner: compatibility,
                    integrations: environment))
            expect(
                claude.calls.count == 1 && codex.calls.count == 1,
                "full doctor still performs one integration probe per CLI")
            expect(
                compatibility.calls.count == 1
                    && compatibility.calls.first?.arguments == ["claude", "--version"]
                    && compatibility.calls.first?.timeout == 2,
                "full doctor keeps its independent legacy compatibility probe")
        }
    }
}
