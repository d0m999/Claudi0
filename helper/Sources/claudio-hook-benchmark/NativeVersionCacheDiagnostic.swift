import ClaudioCore
import Foundation

final class SignatureCounter: HostVersionSignatureValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var elapsed: UInt64 = 0
    func accepts(host: HostID, executable: URL) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        let start = DispatchTime.now().uptimeNanoseconds
        let accepted = SystemHostVersionSignatureValidator().accepts(
            host: host, executable: executable)
        let duration = DispatchTime.now().uptimeNanoseconds - start
        lock.lock(); elapsed += duration; lock.unlock()
        return accepted
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var nanoseconds: UInt64 { lock.lock(); defer { lock.unlock() }; return elapsed }
}

/// Real installed binaries are read/probed, but every cache byte lives in a fresh temporary
/// directory. Never calls hook, launches playback, connects a host or inspects user receipts.
func runNativeVersionCacheDiagnostic(samples: Int) throws {
    struct Row: Encodable {
        let evidence = "native-version-component-only"
        let host: String
        let mode: String
        let sample: Int
        let nanoseconds: UInt64
        let probeCalls: Int
        let signatureCalls: Int
        let version: String
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-native-version-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locator = HostExecutableLocator.standard()
    let encoder = JSONEncoder()
    for host in [HostID.claudeCode, .codex] {
        let runner = ObservedRunner(
            base: SystemCommandRunner(environmentOverrides: ["PATH": locator.executableSearchPath]))
        let signature = SignatureCounter()
        let resolver = HostVersionResolver(
            cacheDirectory: root.appendingPathComponent(host.rawValue),
            executableLocator: locator, commandRunner: runner, signatureValidator: signature)
        let uncached = HostVersionResolver(executableLocator: locator, commandRunner: runner)
        var previous: String?
        let cases: [(String, Int)] =
            [("cold-fill", 0)]
            + (0..<samples).flatMap { sample in
                let modes =
                    (UInt64(sample) &+ 0xC1A0D10) % 2 == 0
                    ? ["probe-only", "hit", "force"] : ["force", "hit", "probe-only"]
                return modes.map { ($0, sample) }
            }
        for (mode, sample) in cases {
            let probes = runner.snapshot.count, signatures = signature.calls
            let start = DispatchTime.now().uptimeNanoseconds
            let version =
                mode == "cold-fill"
                ? resolver.refresh(host).version
                : (mode == "probe-only" ? uncached : resolver).resolve(
                    host, mode: mode == "force" ? .forceProbe : .reuseValidated)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            try require(
                version != nil && (previous == nil || previous == version),
                "native version unavailable or changed")
            let probeDelta = runner.snapshot.count - probes,
                signatureDelta = signature.calls - signatures
            try require(
                probeDelta == (mode == "hit" ? 0 : 1),
                "native cache did not follow expected probe branch")
            try require(
                signatureDelta == (mode == "cold-fill" ? 1 : 0),
                "native signature branch mismatch")
            print(
                String(
                    decoding: try encoder.encode(
                        Row(
                            host: host.rawValue, mode: mode, sample: sample,
                            nanoseconds: elapsed, probeCalls: probeDelta,
                            signatureCalls: signatureDelta, version: version!)), as: UTF8.self))
            previous = version
        }
    }
}
