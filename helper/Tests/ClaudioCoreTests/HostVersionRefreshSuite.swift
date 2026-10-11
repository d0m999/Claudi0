import ClaudioCore
import Foundation

// Used synchronously by the signer on this test's thread, never shared concurrently.
private final class RefreshTestLock: @unchecked Sendable {
    let value: FileLock
    init(_ path: String) { value = FileLock(path: path) }
}

private final class RefreshControl: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func cancel() { lock.lock(); current = false; lock.unlock() }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
}

private final class RefreshSigner: HostVersionSignatureValidating, @unchecked Sendable {
    let action: @Sendable () -> Bool
    init(_ action: @escaping @Sendable () -> Bool) { self.action = action }
    func accepts(host: HostID, executable: URL) -> Bool { action() }
}

private final class RefreshResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: HostVersionRefreshResult?
    func set(_ value: HostVersionRefreshResult) { lock.lock(); result = value; lock.unlock() }
    var value: HostVersionRefreshResult? { lock.lock(); defer { lock.unlock() }; return result }
}

private func refreshResolver(
    _ f: VersionTestFixture, runner: VersionTestRunner? = nil,
    signer: (any HostVersionSignatureValidating)? = nil
) -> HostVersionResolver {
    .init(
        cacheDirectory: f.cache, homeDirectory: f.root, executableLocator: f.locator,
        commandRunner: runner ?? f.runner, signatureValidator: signer ?? f.signer,
        now: { f.clock.value })
}

@MainActor
func runHostVersionRefreshSuites() {
    suite("version refresh: ordinary misses and diagnostics never sign or create cache") {
        for host in [HostID.claudeCode, .codex] {
            withTempDirectory { root in
                let f = VersionTestFixture(root, host: host)
                for mode in [
                    HostVersionResolutionMode.reuseValidated, .reuseValidated, .forceProbe,
                ] {
                    expect(f.resolve(mode) != nil, "uncached real probe remains usable")
                }
                expect(
                    f.runner.calls.count == 3 && f.signer.calls == 0,
                    "each miss/forced probe runs once with zero signing")
                expect(
                    !FileManager.default.fileExists(atPath: f.cache.path),
                    "ordinary probes never create cache directory or locks")
                let disabled = HostVersionResolver(
                    homeDirectory: root, executableLocator: f.locator, commandRunner: f.runner,
                    signatureValidator: f.signer)
                expect(
                    disabled.refresh(host).status == .disabled && f.runner.calls.count == 4
                        && f.signer.calls == 0, "disabled refresh is just a real probe")
            }
        }
    }
    suite("version refresh: expiry misses never refill or renew; signing time counts toward TTL") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            expect(f.refresh().status == .published, "strict explicit refresh publishes")
            let original = try! Data(contentsOf: f.file)
            f.clock.advance(599)
            expect(f.resolve() != nil && f.runner.calls.count == 1, "qualified hit before expiry")
            f.clock.advance(1)
            expect(
                f.resolve() != nil && f.resolve() != nil && f.runner.calls.count == 3
                    && f.signer.calls == 1 && (try? Data(contentsOf: f.file)) == original,
                "expired observation causes repeated probes, no signing or TTL renewal")
            let slow = RefreshSigner {
                f.clock.advance(600); return true
            }
            let result = refreshResolver(f, signer: slow).refresh(.claudeCode)
            expect(
                result.status == .expired && result.version != nil,
                "signature duration cannot extend observation lifetime")
            let calls = f.runner.calls.count
            expect(
                f.resolve() != nil && f.runner.calls.count == calls + 1,
                "expired explicit refresh leaves no reusable observation")
        }
    }
    suite("version refresh: cancellation, upgrades and failed probe revoke replaced observation") {
        for change in [
            "probe-failure", "probe-cancel", "signature-cancel", "probe-upgrade",
            "signature-upgrade",
        ] {
            withTempDirectory { root in
                let f = VersionTestFixture(root)
                expect(f.refresh().status == .published, "prime existing observation")
                let control = RefreshControl()
                if change == "probe-failure" { f.runner.result = .timedOut }
                if change == "probe-cancel" { f.runner.action = { control.cancel() } }
                if change == "probe-upgrade" {
                    f.runner.action = { try! Data("changed".utf8).write(to: f.target) }
                }
                let signer = RefreshSigner {
                    if change == "signature-cancel" { control.cancel() }
                    if change == "signature-upgrade" {
                        try! Data("changed".utf8).write(to: f.target)
                    }
                    return true
                }
                let result = refreshResolver(f, signer: signer).refresh(
                    .claudeCode,
                    isCurrent: { control.isCurrent })
                let expected: HostVersionRefreshStatus =
                    change == "probe-failure"
                    ? .probeFailed
                    : change.hasSuffix("cancel") ? .cancelled : .identityChanged
                expect(
                    result.status == expected && result.version == nil,
                    "\(change) rejects obsolete/cancelled result")
                f.runner.action = nil
                f.runner.result = .completed(exitCode: 0, stdout: "2.1.282 (Claude Code)")
                let calls = f.runner.calls.count
                expect(
                    f.resolve() != nil && f.runner.calls.count == calls + 1,
                    "\(change) cannot leave old observation usable")
            }
        }
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            expect(
                f.resolver().refresh(.claudeCode, isCurrent: { false }).status == .cancelled
                    && f.runner.calls.isEmpty && f.signer.calls == 0
                    && !FileManager.default.fileExists(atPath: f.cache.path),
                "pre-cancel skips all side effects")
            let context = HostPublicationContext.unconditional(
                lockFile: root.appendingPathComponent("lease"))
            expect(context.acquire() == .allowed, "hold publication lease")
            HostPublicationContext.$current.withValue(context) {
                expect(
                    f.refresh().status == .publicationLeaseHeld && f.runner.calls.isEmpty,
                    "refresh never probes inside event publication lease")
            }
            context.release()
        }
    }
    suite("version refresh: publication failure preserves a successful probe result") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let writeLock = RefreshTestLock(f.cache.appendingPathComponent("claude-code.lock").path)
            let signer = RefreshSigner {
                _ = writeLock.value.attemptLock()
                return true
            }
            let result = refreshResolver(f, signer: signer).refresh(.claudeCode)
            expect(
                result.status == .busy && result.version != nil && f.runner.calls.count == 1,
                "busy publication returns successful version without claiming cache success")
            writeLock.value.unlock()
            let calls = f.runner.calls.count
            expect(
                f.resolve() != nil && f.runner.calls.count == calls + 1,
                "failed publication cannot manufacture a hit")
        }
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let signer = RefreshSigner {
                let operation = f.cache.appendingPathComponent("claude-code.refresh.lock")
                try! FileManager.default.removeItem(at: operation)
                try! Data().write(to: operation)
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: operation.path)
                return true
            }
            expect(
                refreshResolver(f, signer: signer).refresh(.claudeCode).status == .identityChanged,
                "replacing operation lock prevents late publication")
        }
    }
    suite("version refresh: late failed miss cannot delete a newer successful refresh") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            _ = f.refresh()
            f.clock.advance(-1)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let failed = VersionTestRunner()
            failed.result = .timedOut
            failed.action = {
                entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
            let stale = refreshResolver(f, runner: failed)
            DispatchQueue.global().async {
                _ = stale.resolve(.claudeCode, mode: .reuseValidated)
                finished.signal()
            }
            expect(entered.wait(timeout: .now() + 5) == .success, "expired miss entered probe")
            f.clock.advance(1)
            expect(
                f.refresh().status == .published,
                "newer refresh publishes at identical original clocks")
            release.signal()
            expect(finished.wait(timeout: .now() + 5) == .success, "late failed probe completed")
            let calls = f.runner.calls.count
            expect(
                f.resolve() != nil && f.runner.calls.count == calls,
                "late failure revokes only the exact observation it saw")
        }
    }
    suite("version refresh: nonblocking operation lock spans probe; write lock remains free") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let box = RefreshResultBox()
            f.runner.action = {
                entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
            let resolver = f.resolver()
            DispatchQueue.global().async {
                box.set(resolver.refresh(.claudeCode)); finished.signal()
            }
            expect(entered.wait(timeout: .now() + 5) == .success, "refresh entered probe")
            let start = DispatchTime.now().uptimeNanoseconds
            expect(
                f.refresh().status == .busy && f.runner.calls.count == 1,
                "concurrent refresh skips instead of duplicating probe")
            expect(
                DispatchTime.now().uptimeNanoseconds - start < 500_000_000,
                "refresh contention is nonblocking")
            let write = FileLock(path: f.cache.appendingPathComponent("claude-code.lock").path)
            expect(write.attemptLock() == .acquired, "short cache write lock is free during probe")
            write.unlock()
            release.signal()
            expect(
                finished.wait(timeout: .now() + 5) == .success && box.value?.status == .published,
                "sole refresh publishes")
            let calls = f.runner.calls.count
            expect(f.resolve() != nil && f.runner.calls.count == calls, "post-refresh safe hit")
        }
    }
    suite("version refresh: signature work leaves write lock free and hosts independent") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let other = VersionTestFixture(root.appendingPathComponent("other"), host: .codex)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let signer = RefreshSigner {
                entered.signal(); _ = release.wait(timeout: .now() + 5); return true
            }
            let resolver = refreshResolver(f, signer: signer)
            let box = RefreshResultBox()
            DispatchQueue.global().async {
                box.set(resolver.refresh(.claudeCode)); finished.signal()
            }
            expect(
                entered.wait(timeout: .now() + 5) == .success,
                "refresh entered signature validation")
            expect(
                f.refresh().status == .busy && f.runner.calls.count == 1,
                "operation lock spans signature validation")
            let write = FileLock(path: f.cache.appendingPathComponent("claude-code.lock").path)
            expect(
                write.attemptLock() == .acquired,
                "short write lock is free during signature validation")
            write.unlock()
            expect(
                other.resolver(cache: f.cache).refresh(.codex).status == .ineligible
                    && other.runner.calls == [other.call.path] && other.signer.calls == 0,
                "ineligible Codex probes independently while Claude signs")
            release.signal()
            expect(
                finished.wait(timeout: .now() + 5) == .success && box.value?.status == .published,
                "strict signature completion publishes")
        }
    }
    suite("version refresh: refusal to revoke must skip probe and signature") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            _ = f.refresh()
            let before = try! Data(contentsOf: f.file)
            let held = FileLock(path: f.cache.appendingPathComponent("claude-code.lock").path)
            expect(held.attemptLock() == .acquired, "hold revocation lock")
            expect(
                f.refresh().status == .busy && f.runner.calls.count == 1 && f.signer.calls == 1,
                "revocation contention skips all slow work")
            expect(
                (try? Data(contentsOf: f.file)) == before, "skipped refresh does not change cache")
            held.unlock()
        }
    }
    suite("version refresh: process exit after revocation leaves no unverified observation") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            _ = f.refresh()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "--host-version-cache-child", root.path, f.host.rawValue, "hold-refresh",
            ]
            process.standardOutput = FileHandle.nullDevice;
            process.standardError = FileHandle.nullDevice
            try! process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("entered").path)
                && Date() < deadline && process.isRunning
            { Thread.sleep(forTimeInterval: 0.01) }
            expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path),
                "child revoked old observation before blocking probe")
            process.terminate(); process.waitUntilExit()
            let calls = f.runner.calls.count
            expect(
                f.resolve() != nil && f.runner.calls.count == calls + 1,
                "terminated refresh cannot expose old or unvalidated observation")
            f.runner.action = nil
            expect(f.refresh().status == .published, "process exit releases operation lock")
        }
    }
    suite("version refresh: independent processes serialize refresh and reuse observation") {
        withTempDirectory { root in
            let f = VersionTestFixture(root)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "--host-version-cache-child", root.path, f.host.rawValue, "hold-refresh",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            try! process.run()
            let release = root.appendingPathComponent("release")
            defer { try? Data().write(to: release); if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("entered").path)
                && Date() < deadline && process.isRunning
            { Thread.sleep(forTimeInterval: 0.01) }
            expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path),
                "child holds refresh operation")
            expect(
                f.refresh().status == .busy && f.runner.calls.isEmpty && f.signer.calls == 0,
                "cross-process contender performs no slow work")
            try! Data().write(to: release)
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            expect(
                process.terminationStatus == 0
                    && result?["refreshStatus"] as? String == "published",
                "child publishes strict refresh")
            // Child uses actual monotonic/wall clocks, so the parent must use the same clock basis.
            let live = HostVersionResolver(
                cacheDirectory: f.cache, homeDirectory: root,
                executableLocator: f.locator, commandRunner: f.runner, signatureValidator: f.signer)
            expect(
                live.resolve(.claudeCode, mode: .reuseValidated) != nil && f.runner.calls.isEmpty,
                "independent process safely hits without probe")
        }
    }
}
