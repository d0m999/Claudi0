import ClaudioCore
import Darwin
import Foundation

@MainActor
func runHostHookReceiptPruningSuites() {
    for count in [19, 20, 21, 25] {
        suite("Receipt pruning: \(count) regular files after archive") {
            withTempDirectory { root in
                do {
                    let fixture = try ReceiptPruningFixture(root: root)
                    for index in 0..<(count - 1) {
                        try fixture.seed(
                            "legacy-\(100 - index).json",
                            timestamp: fixture.now.addingTimeInterval(Double(index - 100)),
                            modified: fixture.now.addingTimeInterval(Double(100 - index)))
                    }
                    expect(fixture.storeCurrent() == .success(.written), "store must succeed")
                    let names = try fixture.names()
                    let expectedSeeds = Set(
                        (max(0, count - 20)..<(count - 1)).map {
                            "legacy-\(100 - $0).json"
                        })
                    expect(
                        names.filter { $0.hasPrefix("legacy-") } == expectedSeeds,
                        "retention must follow content time, not filename or mtime")
                    expect(names.count == min(count, 20), "retain at most 20 regular files")
                    let snapshot = fixture.store.receiptHistorySnapshot(host: .workBuddy)
                    expect(snapshot.state == .available, "history must remain readable")
                    expect(snapshot.receipts.count == min(count, 20), "API retention must agree")
                    try fixture.expectCurrentAndArchive()
                } catch {
                    expect(false, "fixture failed: \(error)")
                }
            }
        }
    }

    for count in [20, 21] {
        suite("Receipt pruning: damaged JSON and no-follow at \(count)") {
            withTempDirectory { root in
                do {
                    let fixture = try ReceiptPruningFixture(root: root)
                    for index in 0..<(count - 2) {
                        try fixture.seed(
                            "valid-\(index).json",
                            timestamp: fixture.now.addingTimeInterval(Double(index - 100)))
                    }
                    let damaged = fixture.directory.appendingPathComponent("damaged.json")
                    try Data("not JSON".utf8).write(to: damaged)
                    let outside = root.appendingPathComponent("outside.json")
                    let sentinel = Data("owned synthetic link target".utf8)
                    try sentinel.write(to: outside)
                    let link = fixture.directory.appendingPathComponent("link.json")
                    try FileManager.default.createSymbolicLink(
                        at: link, withDestinationURL: outside)
                    let nested = fixture.directory.appendingPathComponent("directory.json")
                    try FileManager.default.createDirectory(
                        at: nested, withIntermediateDirectories: false)
                    let hidden = fixture.directory.appendingPathComponent(".hidden.json")
                    try sentinel.write(to: hidden)
                    expect(fixture.storeCurrent() == .success(.written), "store must succeed")
                    expect(
                        FileManager.default.fileExists(atPath: damaged.path) == (count == 20),
                        "damaged JSON stays below limit; overflow evicts its distantPast time")
                    var status = stat()
                    expect(
                        lstat(link.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK,
                        "symlink must remain a link")
                    expect(
                        try Data(contentsOf: outside) == sentinel, "link target bytes must remain")
                    expect(try Data(contentsOf: hidden) == sentinel, "hidden files stay untouched")
                    expect(
                        FileManager.default.fileExists(atPath: nested.path),
                        "directories stay untouched")
                    let snapshot = fixture.store.receiptHistorySnapshot(host: .workBuddy)
                    expect(snapshot.receipts.count == count - 1, "valid receipts stay intact")
                    expect(
                        snapshot.state == .damaged(skippedItemCount: count == 20 ? 4 : 3),
                        "damage accounting must retain ignored directory/link/hidden entries")
                } catch {
                    expect(false, "fixture failed: \(error)")
                }
            }
        }
    }

    suite("Receipt pruning: expiry uses mtime independently of content time") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                let cutoff = fixture.now.addingTimeInterval(-HostHookReceiptStore.historyRetention)
                try fixture.seed(
                    "expired-future-event.json", timestamp: fixture.now.addingTimeInterval(100),
                    modified: cutoff.addingTimeInterval(-60))
                try fixture.seed(
                    "retained-old-event.json", timestamp: cutoff.addingTimeInterval(-100),
                    modified: cutoff.addingTimeInterval(60))
                // This mtime is exactly 30 days before fixture setup. It is strictly older
                // than the store's later cutoff; the +60s fixture covers the other side.
                try fixture.seed("boundary.json", timestamp: fixture.now, modified: cutoff)
                expect(fixture.storeCurrent() == .success(.written), "store must succeed")
                let names = try fixture.names()
                expect(
                    !names.contains("expired-future-event.json"),
                    "future content cannot extend retention")
                expect(!names.contains("boundary.json"), "elapsed 30-day boundary must expire")
                expect(
                    names.contains("retained-old-event.json"),
                    "old content cannot shorten mtime retention")
                expect(
                    names.count == 2, "only current archive and unexpired old-content file remain")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: overflow preserves sub-microsecond content precision") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                let seconds = floor(fixture.now.timeIntervalSince1970) - 100
                let low = seconds.nextUp
                let high = low.nextUp
                expect(
                    low < high && floor(low * 1_000_000) == floor(high * 1_000_000),
                    "fixture must differ within the same filename microsecond")
                try fixture.seed(
                    "9999999999999999-low.json", timestamp: Date(timeIntervalSince1970: low),
                    modified: fixture.now.addingTimeInterval(500))
                try fixture.seed(
                    "old-high.json", timestamp: Date(timeIntervalSince1970: high),
                    modified: fixture.now.addingTimeInterval(-500))
                for index in 0..<18 {
                    try fixture.seed(
                        "newer-\(index).json",
                        timestamp: fixture.now.addingTimeInterval(Double(index - 50)))
                }
                expect(fixture.storeCurrent() == .success(.written), "store must succeed")
                let names = try fixture.names()
                expect(
                    !names.contains("9999999999999999-low.json"),
                    "lower content time must be evicted")
                expect(
                    names.contains("old-high.json"), "higher precision must beat mtime and filename"
                )
                expect(names.count == 20, "overflow retains exactly 20")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: stale installation and both locks forbid archive changes") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                try fixture.seed("keep.json", timestamp: fixture.now)
                let before = try fixture.names()
                let stale = fixture.receipt(installationID: UUID())
                expect(
                    fixture.store.store(stale, scopeFingerprint: { "pruning-fixture" })
                        == .failure(.staleInstallation),
                    "old installation must reject before archive")
                guard
                    let eventLock = fixture.store.lockFile(
                        host: .workBuddy, nativeEvent: "UserPromptSubmit")
                else {
                    expect(false, "event lock must exist")
                    return
                }
                for path in [
                    eventLock.path, fixture.store.installationLockFile(host: .workBuddy).path,
                ] {
                    let locked = withNonBlockingLock(path: path) {
                        fixture.storeCurrent()
                    }
                    if case .ran(let result) = locked {
                        expect(
                            result == .failure(.lockBusy), "contended locks must stay nonblocking")
                    } else {
                        expect(false, "fixture must acquire its own lock")
                    }
                }
                expect(try fixture.names() == before, "rejections cannot create or prune history")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: clear holds installation lock and preserves current receipt") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                expect(
                    fixture.storeCurrent() == .success(.written), "initial publication must succeed"
                )
                let store = fixture.store
                let receipt = fixture.receipt()
                let concurrentResult = ReceiptPruningConcurrentResult()
                let completed = DispatchSemaphore(value: 0)
                let result = store.clearReceiptHistory(
                    hosts: [.workBuddy],
                    beforeStaging: { _ in
                        DispatchQueue.global().async {
                            concurrentResult.set(
                                store.store(receipt, scopeFingerprint: { "pruning-fixture" }))
                            completed.signal()
                        }
                        expect(
                            completed.wait(timeout: .now() + 5) == .success,
                            "concurrent store must finish while clear owns installation lock")
                        expect(
                            concurrentResult.value() == .failure(.lockBusy),
                            "store during clear cannot enter archive")
                    })
                if case .success = result {} else { expect(false, "clear must succeed") }
                expect(
                    fixture.store.receiptHistory(host: .workBuddy).isEmpty, "clear removes history")
                guard
                    let current = fixture.store.receiptFile(
                        host: .workBuddy, nativeEvent: "UserPromptSubmit")
                else {
                    expect(false, "current path must exist")
                    return
                }
                expect(
                    FileManager.default.fileExists(atPath: current.path),
                    "clear keeps stable current receipt")
                expect(
                    fixture.storeCurrent() == .success(.written),
                    "store after clear republishes archive")
                expect(try fixture.names().count == 1, "new archive is the only retained history")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: removal failure stays explicit after both publications") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                let cutoff = fixture.now.addingTimeInterval(-HostHookReceiptStore.historyRetention)
                try fixture.seed(
                    "immutable-expired.json", timestamp: fixture.now,
                    modified: cutoff.addingTimeInterval(-60))
                let blocked = fixture.directory.appendingPathComponent("immutable-expired.json")
                guard chflags(blocked.path, UInt32(UF_IMMUTABLE)) == 0 else {
                    expect(false, "fixture must establish immutable removal failure")
                    return
                }
                defer {
                    expect(chflags(blocked.path, 0) == 0, "fixture must remove its immutable flag")
                }
                if case .failure(.writeFailure) = fixture.storeCurrent() {
                } else {
                    expect(false, "prune failure must not be reported as written")
                }
                expect(
                    try fixture.names().count == 2,
                    "failed expiry keeps expired file and new archive")
                try fixture.expectCurrentAndArchive()
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: multiple expiries preserve ordered partial failure") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                let cutoff = fixture.now.addingTimeInterval(-HostHookReceiptStore.historyRetention)
                // The immutable item sorts before the removable item by content time.
                try fixture.seed(
                    "block-first.json", timestamp: fixture.now.addingTimeInterval(100),
                    modified: cutoff.addingTimeInterval(-60))
                try fixture.seed(
                    "keep-after-failure.json", timestamp: fixture.now.addingTimeInterval(-100),
                    modified: cutoff.addingTimeInterval(-60))
                let blocked = fixture.directory.appendingPathComponent("block-first.json")
                guard chflags(blocked.path, UInt32(UF_IMMUTABLE)) == 0 else {
                    expect(false, "fixture must establish immutable removal failure")
                    return
                }
                defer { expect(chflags(blocked.path, 0) == 0, "fixture must clear immutable flag") }
                if case .failure(.writeFailure) = fixture.storeCurrent() {
                } else {
                    expect(false, "ordered removal must fail explicitly")
                }
                expect(
                    try fixture.names().count == 3,
                    "failure on newest expired item must preserve both expired files and new archive"
                )
                expect(
                    try fixture.names().contains("keep-after-failure.json"),
                    "later expiry must stay untouched after the first failure")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }

    suite("Receipt pruning: archive failure keeps current publication and reports failure") {
        withTempDirectory { root in
            do {
                let fixture = try ReceiptPruningFixture(root: root)
                try FileManager.default.removeItem(at: fixture.directory)
                try Data("blocks archive directory".utf8).write(to: fixture.directory)
                if case .failure(.directoryCreationFailure) = fixture.storeCurrent() {
                } else {
                    expect(false, "archive directory failure must keep its original error")
                }
                guard
                    let current = fixture.store.receiptFile(
                        host: .workBuddy, nativeEvent: "UserPromptSubmit")
                else {
                    expect(false, "current path must exist")
                    return
                }
                expect(
                    FileManager.default.fileExists(atPath: current.path),
                    "first durable publication stays committed")
                expect(
                    try Data(contentsOf: fixture.directory)
                        == Data("blocks archive directory".utf8),
                    "failure cannot replace the blocking file")
            } catch {
                expect(false, "fixture failed: \(error)")
            }
        }
    }
}

@MainActor
private struct ReceiptPruningFixture {
    let store: HostHookReceiptStore
    let installationID = UUID()
    let now = Date()
    let directory: URL

    init(root: URL) throws {
        store = HostHookReceiptStore(
            receiptsRoot: root.appendingPathComponent("receipts"),
            locksRoot: root.appendingPathComponent("locks"))
        directory = store.historyRoot.appendingPathComponent(HostSurfaceID.workBuddy.rawValue)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard
            case .success = store.activate(
                host: .workBuddy, installationID: installationID,
                scopeFingerprint: "pruning-fixture")
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func receipt(installationID: UUID? = nil) -> HostHookReceipt {
        HostHookReceipt(
            installationID: installationID ?? self.installationID, host: .workBuddy,
            nativeEvent: "UserPromptSubmit", semanticEvent: .taskStart,
            timestamp: now, playbackResult: .played)
    }

    func storeCurrent() -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        store.store(receipt(), scopeFingerprint: { "pruning-fixture" })
    }

    func seed(_ name: String, timestamp: Date, modified: Date? = nil) throws {
        let object: [String: Any] = [
            "schema": 2, "installation_id": installationID.uuidString,
            "host": "workbuddy",
            "binding_id": HostCapabilityCatalog.binding(
                host: .workBuddy, nativeEvent: "UserPromptSubmit")!.id.rawValue,
            "native_event": "UserPromptSubmit", "semantic_event": "task_start",
            "timestamp": timestamp.timeIntervalSince1970, "playback_result": "played",
        ]
        let file = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: modified ?? now],
            ofItemAtPath: file.path)
    }

    func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    func expectCurrentAndArchive() throws {
        guard let current = store.receiptFile(host: .workBuddy, nativeEvent: "UserPromptSubmit")
        else {
            expect(false, "current path must exist")
            return
        }
        let currentData = try Data(contentsOf: current)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let archive = try entries.first { try Data(contentsOf: $0) == currentData }
        expect(archive != nil, "archive must exist independently of current receipt")
        if let archive {
            expect(
                try Data(contentsOf: archive) == currentData,
                "both publications must contain the same receipt")
            for file in [current, archive] {
                let mode =
                    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                    as? NSNumber
                expect(mode?.intValue == 0o600, "durable publications remain private")
            }
        }
    }
}

private final class ReceiptPruningConcurrentResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError>?

    func set(_ result: Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }

    func value() -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
