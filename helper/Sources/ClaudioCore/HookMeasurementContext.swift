import Foundation

/// Opt-in, invocation-local measurement. No paths, payloads, logging or persistence.
/// Spans are inclusive and may nest; consumers must not add them to infer total time.
public final class HookMeasurementContext: @unchecked Sendable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case inputAuthorization, versionResolution, activity, workspaceAndSound
        case playbackLock, playerStart, currentReceipt, historyArchive, historyPrune, notice
        case handling
    }

    public enum Result: String, Codable, Sendable {
        case completed, accepted, rejectedAuthorization, rejectedBinding, rejectedPayload
        case rejectedInstallation, rejectedVersion, played, muted, debounced, notReady,
            playbackFailed
        case activityCommitted, activityDeferred, activityFailed
        case receiptPublished, historyPublished, noticeSent, noticeDropped, lockBusy, lockFailed
    }

    public struct Record: Codable, Sendable, Equatable {
        public let stage: Stage
        public let result: Result
        public let nanoseconds: UInt64?
    }

    @TaskLocal public static var current: HookMeasurementContext?
    private let lock = NSLock()
    private var records: [Record] = []
    private var dropped = 0
    public init() {}

    public var snapshot: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public var droppedRecordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// The disabled path reads no clock and allocates no record.
    public static func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        guard let context = current else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            context.append(stage, .completed, DispatchTime.now().uptimeNanoseconds - start)
        }
        return try body()
    }

    public static func record(_ stage: Stage, _ result: Result) {
        current?.append(stage, result, nil)
    }

    private func append(_ stage: Stage, _ result: Result, _ duration: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        guard records.count < 1024 else { dropped += 1; return }
        records.append(Record(stage: stage, result: result, nanoseconds: duration))
    }
}
