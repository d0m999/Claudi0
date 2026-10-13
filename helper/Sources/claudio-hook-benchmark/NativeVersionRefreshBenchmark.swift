import ClaudioCore
import Foundation

/// Refresh is version-only work, independent of receipt history. One measured refresh feeds
/// two complete hooks with separate business roots and a shared private temporary version cache.
func runNativeVersionRefreshBenchmark(
    samples: Int, warmup: Int, rounds: Int, selectedHost: String
) throws {
    struct Row: Encodable {
        let evidence = "native-explicit-refresh-and-isolated-hook"
        let host: String
        let refreshKind: String
        let round: Int
        let pair: Int
        let nanoseconds: UInt64
        let probeCalls: Int
        let signatureCalls: Int
        let signatureNanoseconds: UInt64
        let status: String
        let followingHooks: [Sample]
    }
    let hosts = [HostID.claudeCode, .codex].filter {
        selectedHost == "all" || $0.rawValue == selectedHost
    }
    try require(!hosts.isEmpty, "invalid refresh host")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-explicit-refresh-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for round in 0..<rounds {
        var fixtures: [String: Fixture] = [:]
        for host in hosts {
            for kind in ["empty", "replace"] {
                for scenario in ["full-empty", "full-steady"] {
                    fixtures["\(host.rawValue)/\(kind)/\(scenario)"] = try autoreleasepool {
                        try Fixture(
                            root: root.appendingPathComponent(
                                "\(round)/\(host.rawValue)/\(kind)/\(scenario)"),
                            scenario: scenario, mode: "native-cold", host: host)
                    }
                }
                if kind == "replace" {
                    let probe = Probe(
                        locator: .standard(), instant: false,
                        root: root.appendingPathComponent(
                            "\(round)/\(host.rawValue)/\(kind)/shared"),
                        cacheMode: "native-hit", host: host, native: true)
                    try require(
                        probe.resolver!.refresh(host).status == .published,
                        "replace refresh fixture must start with an observation")
                }
            }
        }
        let coordinates = hosts.flatMap { host in ["empty", "replace"].map { (host, $0) } }
        for pair in -warmup..<samples {
            let forward = (UInt64(pair + warmup + round) &+ 0xC1A0D10) % 2 == 0
            for (host, kind) in forward ? coordinates : Array(coordinates.reversed()) {
                try autoreleasepool {
                    let shared = root.appendingPathComponent(
                        "\(round)/\(host.rawValue)/\(kind)/shared")
                    let cache = shared.appendingPathComponent("version-cache")
                    if kind == "empty" && FileManager.default.fileExists(atPath: cache.path) {
                        try FileManager.default.removeItem(at: cache)
                    }
                    let probe = Probe(
                        locator: .standard(), instant: false,
                        root: shared, cacheMode: "native-hit", host: host, native: true)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let refreshed = autoreleasepool { probe.resolver!.refresh(host) }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    try require(
                        refreshed.status == .published && refreshed.version != nil
                            && probe.runner.snapshot.count == 1 && probe.signature.calls == 1,
                        "explicit native refresh did not strictly publish")
                    var hits: [Sample] = []
                    for scenario in forward
                        ? ["full-empty", "full-steady"] : ["full-steady", "full-empty"]
                    {
                        let hit = try fixtures["\(host.rawValue)/\(kind)/\(scenario)"]!.run(
                            observer: false, round: round, pair: pair, position: 0,
                            probeMode: "native-hit", versionCacheRoot: shared)
                        try require(
                            hit.probeCalls == 0 && hit.signatureCalls == 0
                                && hit.accepted == 1 && hit.receipts == 1 && hit.archives == 1
                                && hit.playerStarts == 1 && hit.notices == 1 && hit.activity == 1,
                            "strict refresh did not yield a correct complete hook hit")
                        hits.append(hit)
                    }
                    if pair >= 0 {
                        let row = Row(
                            host: host.rawValue, refreshKind: kind, round: round, pair: pair,
                            nanoseconds: elapsed, probeCalls: 1, signatureCalls: 1,
                            signatureNanoseconds: probe.signature.nanoseconds,
                            status: refreshed.status.rawValue, followingHooks: hits)
                        print(String(decoding: try encoder.encode(row), as: UTF8.self))
                    }
                }
            }
        }
    }
}
