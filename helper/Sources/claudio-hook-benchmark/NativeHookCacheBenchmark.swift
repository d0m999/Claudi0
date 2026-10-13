import ClaudioCore
import Foundation

/// Complete handleHostHook calls with real installed version probes and Security validation.
/// All mutable state belongs to Fixture's temporary root; audio and notices are simulated.
func runNativeHookCacheBenchmark(
    samples: Int, warmup: Int, rounds: Int, scenario: String, selectedHost: String
) throws {
    let hosts = [HostID.claudeCode, .codex].filter {
        selectedHost == "all" || $0.rawValue == selectedHost
    }
    try require(!hosts.isEmpty, "invalid native benchmark host")
    try require(scenario == "all" || scenarioNames.contains(scenario), "invalid native scenario")
    let scenarios = scenario == "all" ? ["full-empty", "full-steady"] : [scenario]
    let modes = [
        "native-bypass", "native-cold", "native-hit", "native-expired", "native-force",
        "native-failed", "native-identity", "native-unknown",
    ]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-native-hook-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let seed: UInt64 = 0xC1A0D10
    for host in hosts {
        for scenario in scenarios {
            for round in 0..<rounds {
                var fixtures: [String: Fixture] = [:]
                for mode in modes {
                    fixtures[mode] = try autoreleasepool {
                        try Fixture(
                            root: root.appendingPathComponent(
                                "\(host.rawValue)-\(scenario)-\(round)-\(mode)"),
                            scenario: scenario, mode: mode, host: host)
                    }
                }
                for pair in -warmup..<samples {
                    let forward = (UInt64(pair + warmup + round) &+ seed) % 2 == 0
                    for mode in forward ? modes : Array(modes.reversed()) {
                        for (position, observer) in [forward, !forward].enumerated() {
                            // The production helper exits after one event. Drain temporary
                            // Foundation/Security objects at that boundary in this long-lived driver.
                            try autoreleasepool {
                                let row = try fixtures[mode]!.run(
                                    observer: observer, round: round, pair: pair, position: position
                                )
                                if pair >= 0 {
                                    print(String(decoding: try encoder.encode(row), as: UTF8.self))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
