import ClaudioCore
import Darwin
import Foundation

/// Read-only component diagnosis. Never handles a hook or opens user receipt/activity stores.
/// CPU counters cover this process (including workers), not Security service CPU or the child.
func runNativeSignatureDiagnostic(samples: Int) throws {
    struct Usage {
        let user: Double
        let system: Double
        let majorFaults: Int
        let blockInputs: Int
        init() {
            var value = rusage()
            precondition(getrusage(RUSAGE_SELF, &value) == 0)
            user = Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1e6
            system = Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1e6
            majorFaults = Int(value.ru_majflt)
            blockInputs = Int(value.ru_inblock)
        }
    }
    struct Row: Encodable {
        let evidence = "native-signature-component-diagnosis"
        let host: String
        let mode: String
        let sample: Int
        let wallMS: Double
        let userMS: Double
        let systemMS: Double
        let majorFaults: Int
        let blockInputs: Int
        let accepted: Bool
    }
    let locator = HostExecutableLocator.standard()
    let runner = SystemCommandRunner(
        environmentOverrides: ["PATH": locator.executableSearchPath])
    let validator = SystemHostVersionSignatureValidator()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for host in [HostID.claudeCode, .codex] {
        guard let call = locator.executablePath(command: host == .claudeCode ? "claude" : "codex")
        else { throw Failure(message: "native executable missing") }
        let target = URL(fileURLWithPath: call).resolvingSymlinksInPath().standardizedFileURL
        for sample in 0..<samples {
            let modes = sample % 2 == 0 ? ["direct", "after-probe"] : ["after-probe", "direct"]
            for mode in modes {
                // The real version process is outside the signature timer, matching the resolver.
                if mode == "after-probe" {
                    let result = runner.run(
                        executablePath: call, arguments: ["--version"], timeout: 1)
                    guard case .completed(0, let output) = result, !output.isEmpty else {
                        throw Failure(message: "native version probe failed")
                    }
                }
                let before = Usage()
                let start = DispatchTime.now().uptimeNanoseconds
                let accepted = autoreleasepool {
                    validator.accepts(host: host, executable: target)
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                let after = Usage()
                try require(accepted, "native signature rejected")
                print(
                    String(
                        decoding: try encoder.encode(
                            Row(
                                host: host.rawValue, mode: mode, sample: sample,
                                wallMS: Double(elapsed) / 1e6,
                                userMS: (after.user - before.user) * 1e3,
                                systemMS: (after.system - before.system) * 1e3,
                                majorFaults: after.majorFaults - before.majorFaults,
                                blockInputs: after.blockInputs - before.blockInputs,
                                accepted: accepted)),
                        as: UTF8.self))
                fflush(stdout)
            }
        }
    }
}
