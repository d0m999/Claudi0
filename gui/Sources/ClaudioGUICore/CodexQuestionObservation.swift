import Foundation

/// This development source has no installation, activation, receipt, activity or directory claim.
/// A rollout function call is an intention; it never proves that a question reached the client.
public struct CodexQuestionObservation: Sendable, Equatable {
    public enum Provenance: String, Sendable {
        case developmentRolloutV1 = "development_codex_rollout_v1"
    }

    public enum Kind: Sendable {
        case callIntention
    }

    public enum Tool: String, Sendable, CaseIterable {
        case synchronous = "request_user_input"
        case asynchronous = "request_user_input_async"
    }

    public let runID: UUID
    public let sessionID: String
    public let requestID: String
    public let tool: Tool
    public let occurredAt: Date
    public let observedUptime: TimeInterval
    public let provenance: Provenance = .developmentRolloutV1
    public let kind: Kind = .callIntention

    public init(
        runID: UUID, sessionID: String, requestID: String, tool: Tool,
        occurredAt: Date, observedUptime: TimeInterval
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.requestID = requestID
        self.tool = tool
        self.occurredAt = occurredAt
        self.observedUptime = observedUptime
    }
}

public enum CodexQuestionObservationFailure: String, Error, Sendable, Equatable {
    case invalidTarget
    case unavailable
    case replacedOrTruncated
    case backlogExceeded
    case lineTooLarge
    case partialLineExpired
    case invalidRecord
    case eventLimitExceeded
    case identityCapacityExceeded
    case inactive
}

/// An explicit file and its filename identity are required. There is no directory discovery or
/// historical session-meta scan. The filename association is development evidence only.
public struct CodexRolloutObservationTarget: Sendable, Equatable {
    public let fileURL: URL
    public let sessionID: String

    public init?(fileURL: URL, sessionID: String) {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/"),
            let identity = UUID(uuidString: sessionID)
        else { return nil }
        let canonicalID = identity.uuidString.lowercased()
        let name = fileURL.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix("-\(canonicalID).jsonl") else {
            return nil
        }
        self.fileURL = fileURL.standardizedFileURL
        self.sessionID = canonicalID
    }

    /// The flag is deliberately separate from the path. Release builds do not open an observer.
    public static func developmentEnvironment(
        _ environment: [String: String]
    ) -> Self? {
        #if DEBUG
        guard environment["CLAUDIO_DEV_CODEX_QUESTION_OBSERVER"] == "1",
            let path = environment["CLAUDIO_DEV_CODEX_ROLLOUT_PATH"],
            let sessionID = environment["CLAUDIO_DEV_CODEX_SESSION_ID"], path.hasPrefix("/")
        else { return nil }
        return Self(fileURL: URL(fileURLWithPath: path), sessionID: sessionID)
        #else
        return nil
        #endif
    }
}

struct CodexQuestionObservationRecord {
    let rootType: String?
    let timestamp: String?
    let payload: [String: String]
}

/// A selective JSON reader: only schema/identity strings are decoded. Arguments, questions,
/// answers and all other values are syntax checked and skipped without creating value objects.
/// Raw bytes live only in the bounded line buffer while a complete line is being processed.
struct CodexQuestionObservationJSON {
    private enum ObjectScope { case root, payload, ignored }
    private let bytes: [UInt8]
    private var index = 0
    private var root: [String: String] = [:]
    private var payload: [String: String] = [:]

    init(_ data: Data) { bytes = Array(data) }

    mutating func parse() throws -> CodexQuestionObservationRecord {
        try object(scope: .root, depth: 0)
        whitespace()
        guard index == bytes.count else { throw CodexQuestionObservationFailure.invalidRecord }
        return CodexQuestionObservationRecord(
            rootType: root["type"], timestamp: root["timestamp"], payload: payload)
    }

    private mutating func object(scope: ObjectScope, depth: Int) throws {
        guard depth <= 24 else { throw CodexQuestionObservationFailure.invalidRecord }
        try consume(123)
        whitespace()
        if take(125) { return }
        var keys: Set<String> = []
        while true {
            let key = try string(capture: true, maximumBytes: 128)!
            guard keys.count < 256, keys.insert(key).inserted else {
                throw CodexQuestionObservationFailure.invalidRecord
            }
            try consume(58)
            switch scope {
            case .root where key == "payload":
                try object(scope: .payload, depth: depth + 1)
            case .root where key == "type" || key == "timestamp":
                root[key] = try string(capture: true, maximumBytes: 256)
            case .payload where ["type", "name", "call_id"].contains(key):
                whitespace()
                if peek == 34 {
                    payload[key] = try string(capture: true, maximumBytes: 512)
                } else {
                    try value(depth: depth + 1)
                }
            case .payload where key == "namespace":
                whitespace()
                if peek == 110 {
                    try literal([110, 117, 108, 108])
                } else {
                    payload[key] = try string(capture: true, maximumBytes: 256)
                }
            default:
                try value(depth: depth + 1)
            }
            whitespace()
            if take(125) { return }
            try consume(44)
        }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 24 else { throw CodexQuestionObservationFailure.invalidRecord }
        whitespace()
        switch peek {
        case 123: try object(scope: .ignored, depth: depth)
        case 91:
            index += 1
            whitespace()
            if take(93) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if take(93) { return }
                try consume(44)
            }
        case 34: _ = try string(capture: false)
        case 116: try literal([116, 114, 117, 101])
        case 102: try literal([102, 97, 108, 115, 101])
        case 110: try literal([110, 117, 108, 108])
        default: try number()
        }
    }

    private mutating func string(capture: Bool, maximumBytes: Int = Int.max) throws -> String? {
        whitespace()
        let start = index
        try consume(34)
        while let byte = peek {
            guard index - start <= maximumBytes + (maximumBytes == Int.max ? 0 : 2) else {
                throw CodexQuestionObservationFailure.invalidRecord
            }
            index += 1
            if byte == 34 {
                guard capture else { return nil }
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            guard byte >= 32 else { throw CodexQuestionObservationFailure.invalidRecord }
            if byte == 92 {
                guard let escaped = peek else {
                    throw CodexQuestionObservationFailure.invalidRecord
                }
                index += 1
                if escaped == 117 {
                    let scalar = try unicodeEscape()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard take(92), take(117),
                            (0xDC00...0xDFFF).contains(try unicodeEscape())
                        else { throw CodexQuestionObservationFailure.invalidRecord }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw CodexQuestionObservationFailure.invalidRecord
                    }
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) {
                    throw CodexQuestionObservationFailure.invalidRecord
                }
            } else if byte >= 128 {
                let continuationCount: Int
                let secondRange: ClosedRange<UInt8>
                switch byte {
                case 0xC2...0xDF: continuationCount = 1; secondRange = 0x80...0xBF
                case 0xE0: continuationCount = 2; secondRange = 0xA0...0xBF
                case 0xE1...0xEC, 0xEE...0xEF:
                    continuationCount = 2; secondRange = 0x80...0xBF
                case 0xED: continuationCount = 2; secondRange = 0x80...0x9F
                case 0xF0: continuationCount = 3; secondRange = 0x90...0xBF
                case 0xF1...0xF3: continuationCount = 3; secondRange = 0x80...0xBF
                case 0xF4: continuationCount = 3; secondRange = 0x80...0x8F
                default: throw CodexQuestionObservationFailure.invalidRecord
                }
                for position in 0..<continuationCount {
                    guard let next = peek,
                        (position == 0 ? secondRange : 0x80...0xBF).contains(next)
                    else { throw CodexQuestionObservationFailure.invalidRecord }
                    index += 1
                }
            }
        }
        throw CodexQuestionObservationFailure.invalidRecord
    }

    private mutating func unicodeEscape() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = peek else { throw CodexQuestionObservationFailure.invalidRecord }
            let value: UInt32
            switch byte {
            case 48...57: value = UInt32(byte - 48)
            case 65...70: value = UInt32(byte - 55)
            case 97...102: value = UInt32(byte - 87)
            default: throw CodexQuestionObservationFailure.invalidRecord
            }
            result = result * 16 + value
            index += 1
        }
        return result
    }

    private mutating func number() throws {
        _ = take(45)
        if !take(48) {
            guard let first = peek, (49...57).contains(first) else {
                throw CodexQuestionObservationFailure.invalidRecord
            }
            index += 1
            while let digit = peek, (48...57).contains(digit) { index += 1 }
        }
        if take(46) { try digits() }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            try digits()
        }
    }

    private mutating func digits() throws {
        let start = index
        while let digit = peek, (48...57).contains(digit) { index += 1 }
        guard index > start else { throw CodexQuestionObservationFailure.invalidRecord }
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        for byte in expected {
            guard take(byte) else { throw CodexQuestionObservationFailure.invalidRecord }
        }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard take(byte) else { throw CodexQuestionObservationFailure.invalidRecord }
    }

    private mutating func whitespace() {
        while let byte = peek, [9, 10, 13, 32].contains(byte) { index += 1 }
    }
}
