import CryptoKit
import Darwin
import Foundation

/// Development-only incremental reader for one explicitly selected file. Call on one serial
/// queue, away from MainActor. Any read/format/budget fault retires this run; callers must start a
/// new reader at EOF after privacy suspension or failure. No raw record is written anywhere.
public final class CodexRolloutObservationReader {
    public static let maximumReadBytes = 64 * 1024
    public static let maximumLineBytes = 32 * 1024
    public static let maximumEventsPerPoll = 32
    public static let maximumRequestIdentities = 256
    public static let partialLineTimeout: TimeInterval = 2

    public let runID: UUID
    public let target: CodexRolloutObservationTarget
    public private(set) var failure: CodexQuestionObservationFailure?
    public var pendingByteCount: Int { pending.count }
    public var rememberedRequestCount: Int { seen.count }

    private var descriptor: Int32 = -1
    private let device: dev_t
    private let inode: ino_t
    private let startedAt: Date
    private var offset: off_t
    private var pending = Data()
    private var partialStartedUptime: TimeInterval?
    private var discardsInitialFragment: Bool
    private var seen: Set<String> = []
    private var anchor: SHA256.Digest?
    private var anchorLength = 0
    private let dateFormatter = ISO8601DateFormatter()
    private let wholeSecondDateFormatter = ISO8601DateFormatter()

    public init(
        target: CodexRolloutObservationTarget, runID: UUID, startedAt: Date = Date()
    ) throws {
        guard startedAt.timeIntervalSince1970.isFinite,
            let before = Self.metadata(target.fileURL.path)
        else { throw CodexQuestionObservationFailure.unavailable }
        let opened = Darwin.open(
            target.fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard opened >= 0 else { throw CodexQuestionObservationFailure.unavailable }
        var metadata = stat()
        guard fstat(opened, &metadata) == 0, Self.accepts(metadata),
            before.st_dev == metadata.st_dev, before.st_ino == metadata.st_ino
        else {
            Darwin.close(opened)
            throw CodexQuestionObservationFailure.unavailable
        }
        // Inspect one framing byte only; do not parse session history or its final record.
        var lastByte: UInt8 = 10
        if metadata.st_size > 0 {
            guard pread(opened, &lastByte, 1, metadata.st_size - 1) == 1 else {
                Darwin.close(opened)
                throw CodexQuestionObservationFailure.unavailable
            }
        }
        self.target = target
        self.runID = runID
        self.startedAt = startedAt
        device = metadata.st_dev
        inode = metadata.st_ino
        offset = metadata.st_size
        descriptor = opened
        discardsInitialFragment = lastByte != 10
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondDateFormatter.formatOptions = [.withInternetDateTime]
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    public func stop() { retire(.inactive) }

    public func poll(
        now: Date = Date(), observedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Result<[CodexQuestionObservation], CodexQuestionObservationFailure> {
        guard descriptor >= 0 else { return .failure(failure ?? .inactive) }
        do {
            guard now.timeIntervalSince1970.isFinite, observedUptime.isFinite,
                observedUptime > 0
            else { throw CodexQuestionObservationFailure.invalidRecord }
            if let partialStartedUptime,
                observedUptime - partialStartedUptime > Self.partialLineTimeout
                    || observedUptime < partialStartedUptime
            {
                throw CodexQuestionObservationFailure.partialLineExpired
            }
            let metadata = try currentMetadata()
            let available = metadata.st_size - offset
            guard available <= Self.maximumReadBytes else {
                throw CodexQuestionObservationFailure.backlogExceeded
            }
            try verifyAnchor()
            guard available > 0 else { return .success([]) }

            var bytes = [UInt8](repeating: 0, count: Int(available))
            let bytesRead = bytes.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, offset)
            }
            guard bytesRead == bytes.count else {
                throw CodexQuestionObservationFailure.replacedOrTruncated
            }
            offset += off_t(bytesRead)
            // A small digest of bytes first seen in this run detects truncate/regrow and
            // overwrite across polls without keeping or rereading historical records.
            anchorLength = min(64, bytes.count)
            anchor = SHA256.hash(data: Data(bytes.suffix(anchorLength)))

            var observations: [CodexQuestionObservation] = []
            var lines = 0
            for byte in bytes {
                if discardsInitialFragment {
                    if byte == 10 { discardsInitialFragment = false }
                    continue
                }
                if byte == 10 {
                    lines += 1
                    guard lines <= 512 else {
                        throw CodexQuestionObservationFailure.eventLimitExceeded
                    }
                    if let observation = try parseLine(now: now, observedUptime: observedUptime) {
                        observations.append(observation)
                        guard observations.count <= Self.maximumEventsPerPoll else {
                            throw CodexQuestionObservationFailure.eventLimitExceeded
                        }
                    }
                    pending.removeAll(keepingCapacity: false)
                    partialStartedUptime = nil
                } else {
                    guard pending.count < Self.maximumLineBytes else {
                        throw CodexQuestionObservationFailure.lineTooLarge
                    }
                    if pending.isEmpty { partialStartedUptime = observedUptime }
                    pending.append(byte)
                }
            }
            _ = try currentMetadata()
            try verifyAnchor()
            return .success(observations)
        } catch let failure as CodexQuestionObservationFailure {
            retire(failure)
            return .failure(failure)
        } catch {
            retire(.invalidRecord)
            return .failure(.invalidRecord)
        }
    }

    private func parseLine(
        now: Date, observedUptime: TimeInterval
    ) throws -> CodexQuestionObservation? {
        var parser = CodexQuestionObservationJSON(pending)
        let record = try parser.parse()
        guard record.rootType == "response_item", record.payload["type"] == "function_call"
        else { return nil }
        guard let name = record.payload["name"],
            let tool = CodexQuestionObservation.Tool(rawValue: name)
        else { return nil }
        // Namespace aliases and tool prefixes are deliberately not guessed. This accepted
        // shape is a versioned prototype, not a claim about every current Codex client.
        guard record.payload["namespace"] == nil || record.payload["namespace"] == "functions",
            let requestID = record.payload["call_id"], Self.isRequestIdentity(requestID),
            let timestamp = record.timestamp,
            let occurredAt = dateFormatter.date(from: timestamp)
                ?? wholeSecondDateFormatter.date(from: timestamp)
        else { throw CodexQuestionObservationFailure.invalidRecord }
        guard occurredAt >= startedAt, occurredAt <= now.addingTimeInterval(1) else { return nil }
        guard !seen.contains(requestID) else { return nil }
        guard seen.count < Self.maximumRequestIdentities else {
            throw CodexQuestionObservationFailure.identityCapacityExceeded
        }
        seen.insert(requestID)
        return CodexQuestionObservation(
            runID: runID, sessionID: target.sessionID, requestID: requestID, tool: tool,
            occurredAt: occurredAt, observedUptime: observedUptime)
    }

    private static func isRequestIdentity(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 256
            && bytes.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            }
    }

    private func currentMetadata() throws -> stat {
        guard let pathMetadata = Self.metadata(target.fileURL.path) else {
            throw CodexQuestionObservationFailure.unavailable
        }
        var fileMetadata = stat()
        guard fstat(descriptor, &fileMetadata) == 0, Self.accepts(fileMetadata) else {
            throw CodexQuestionObservationFailure.unavailable
        }
        guard pathMetadata.st_dev == device, pathMetadata.st_ino == inode,
            fileMetadata.st_dev == device, fileMetadata.st_ino == inode,
            fileMetadata.st_size >= offset
        else { throw CodexQuestionObservationFailure.replacedOrTruncated }
        return fileMetadata
    }

    private static func metadata(_ path: String) -> stat? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, accepts(metadata) else { return nil }
        return metadata
    }

    private static func accepts(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == geteuid()
            && metadata.st_mode & S_IRUSR != 0 && metadata.st_size >= 0
    }

    private func verifyAnchor() throws {
        guard let anchor else { return }
        var bytes = [UInt8](repeating: 0, count: anchorLength)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, offset - off_t(anchorLength))
        }
        guard count == anchorLength, SHA256.hash(data: Data(bytes)) == anchor else {
            throw CodexQuestionObservationFailure.replacedOrTruncated
        }
    }

    private func retire(_ reason: CodexQuestionObservationFailure) {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        failure = reason
        pending.removeAll(keepingCapacity: false)
        partialStartedUptime = nil
        seen.removeAll(keepingCapacity: false)
        anchor = nil
        anchorLength = 0
    }
}
