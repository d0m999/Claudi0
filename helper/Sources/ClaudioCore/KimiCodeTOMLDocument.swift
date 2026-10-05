import Foundation

/// A bounded, conservative TOML reader for surgical hook edits. It preserves the original Data;
/// unsupported syntax is an explicit error, never a reason to reserialize or guess ownership.
/// Strings (including multiline), arrays, inline tables, dotted/quoted keys and numeric values
/// are accepted. Date/time values and nested array tables are deliberately rejected for now.
struct KimiCodeTOMLDocument {
    enum Value {
        case string(String)
        case integer(Int)
        case other
    }

    struct Hook {
        let start: Int
        var end: Int
        var fields: [String: Value]
    }

    struct Comment {
        let start: Int
        let end: Int
        let text: String
    }

    let hooks: [Hook]
    let comments: [Comment]

    init(data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parse()
        hooks = parser.hooks
        comments = parser.comments
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var hooks: [Hook] = []
        var comments: [Comment] = []
        var section: [String] = []
        var activeHook: Int?
        var keys: Set<String> = []
        var tables: Set<String> = []
        var dottedTables: Set<String> = []
        var arrayCounts: [String: Int] = [:]

        mutating func parse() throws {
            guard bytes.count <= 1 << 20, String(bytes: bytes, encoding: .utf8) != nil,
                !bytes.contains(where: { ($0 < 32 && ![9, 10, 13].contains($0)) || $0 == 127 })
            else { throw rejected() }
            for position in bytes.indices where bytes[position] == 13 {
                guard position + 1 < bytes.count, bytes[position + 1] == 10 else {
                    throw rejected()
                }
            }
            while index < bytes.count {
                skipSpaceAndComments()
                if index == bytes.count { break }
                if bytes[index] == 91 {
                    let start = index
                    if let activeHook { hooks[activeHook].end = start }
                    self.activeHook = nil
                    index += 1
                    let array = take(91)
                    let path = try keyPath()
                    spaces()
                    try require(93)
                    if array { try require(93) }
                    try endOfStatement()
                    guard !path.isEmpty else { throw rejected() }
                    if path.first == "hooks" {
                        guard array, path == ["hooks"] else { throw rejected() }
                        hooks.append(Hook(start: start, end: bytes.count, fields: [:]))
                        activeHook = hooks.count - 1
                    }
                    let token = identity(path)
                    guard !dottedTables.contains(token),
                        !keys.contains(where: { token == $0 || token.hasPrefix($0 + "\u{0}") })
                    else { throw rejected() }
                    if array {
                        // Nested array-table context is outside this editor's proven grammar.
                        guard !arrayCounts.keys.contains(where: { token.hasPrefix($0 + "\u{0}") }),
                            !tables.contains(token), !keys.contains(token)
                        else { throw rejected() }
                        arrayCounts[token, default: 0] += 1
                        section = path + ["#\(arrayCounts[token]!)"]
                    } else {
                        guard !tables.contains(token), !keys.contains(token),
                            !arrayCounts.keys.contains(where: {
                                token == $0 || token.hasPrefix($0 + "\u{0}")
                            })
                        else { throw rejected() }
                        tables.insert(token)
                        section = path
                    }
                } else {
                    let path = try keyPath()
                    spaces()
                    try require(61)
                    let value = try parseValue(depth: 0)
                    try endOfStatement()
                    guard !(section.isEmpty && path.first == "hooks") else { throw rejected() }
                    let fullPath = section + path
                    let token = identity(fullPath)
                    guard !keys.contains(token), !tables.contains(token),
                        !tables.contains(where: { $0.hasPrefix(token + "\u{0}") }),
                        !arrayCounts.keys.contains(where: {
                            $0 == token || $0.hasPrefix(token + "\u{0}")
                        }),
                        !keys.contains(where: {
                            token.hasPrefix($0 + "\u{0}") || $0.hasPrefix(token + "\u{0}")
                        })
                    else { throw rejected() }
                    keys.insert(token)
                    if path.count > 1 {
                        for count in 1..<path.count {
                            dottedTables.insert(identity(section + path.prefix(count)))
                        }
                    }
                    if let activeHook {
                        guard path.count == 1,
                            ["event", "matcher", "command", "timeout"]
                                .contains(path[0])
                        else { throw rejected() }
                        hooks[activeHook].fields[path[0]] = value
                    }
                }
            }
            // The host's hook schema is strict. A broken third-party hook is not safe to edit.
            for hook in hooks {
                guard case .string(let event) = hook.fields["event"],
                    [
                        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
                        "PermissionResult", "UserPromptSubmit", "UserPromptQueued", "TurnStarted",
                        "Stop", "StopFailure", "Interrupt", "SessionStart", "SessionEnd",
                        "SessionHeartbeat", "SubagentStart", "SubagentStop", "TaskStarted",
                        "PreCompact", "PostCompact", "Notification",
                    ].contains(event),
                    case .string(let command) = hook.fields["command"], !command.isEmpty
                else { throw rejected() }
                if let matcher = hook.fields["matcher"] {
                    guard case .string(let pattern) = matcher,
                        (try? NSRegularExpression(pattern: pattern)) != nil
                    else { throw rejected() }
                }
                if let timeout = hook.fields["timeout"] {
                    guard case .integer(let seconds) = timeout, (1...600).contains(seconds)
                    else { throw rejected() }
                }
            }
        }

        func identity(_ path: [String]) -> String { path.joined(separator: "\u{0}") }

        mutating func keyPath() throws -> [String] {
            var path: [String] = []
            repeat {
                spaces()
                let key: String
                if peek == 34 || peek == 39 {
                    key = try string(multilineAllowed: false)
                } else {
                    let start = index
                    while let byte = peek,
                        (65...90).contains(byte) || (97...122).contains(byte)
                            || (48...57).contains(byte) || byte == 45 || byte == 95
                    { index += 1 }
                    guard index > start else { throw rejected() }
                    key = String(decoding: bytes[start..<index], as: UTF8.self)
                }
                guard !key.contains("\u{0}") else { throw rejected() }
                path.append(key)
                spaces()
            } while take(46)
            return path
        }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth < 32 else { throw rejected() }
            spaces()
            if peek == 34 || peek == 39 { return .string(try string(multilineAllowed: true)) }
            if take(91) {
                skipSpaceAndComments()
                if take(93) { return .other }
                while true {
                    _ = try parseValue(depth: depth + 1)
                    skipSpaceAndComments()
                    if take(93) { return .other }
                    try require(44)
                    skipSpaceAndComments()
                    if take(93) { return .other }
                }
            }
            if take(123) {
                spaces()
                var localKeys: Set<String> = []
                if take(125) { return .other }
                while true {
                    let token = identity(try keyPath())
                    guard localKeys.insert(token).inserted,
                        !localKeys.contains(where: {
                            $0 != token
                                && (token.hasPrefix($0 + "\u{0}") || $0.hasPrefix(token + "\u{0}"))
                        })
                    else { throw rejected() }
                    try require(61)
                    _ = try parseValue(depth: depth + 1)
                    spaces()
                    if take(125) { return .other }
                    try require(44)
                    spaces()
                    guard peek != 125 else { throw rejected() }
                }
            }
            let start = index
            while let byte = peek, ![9, 10, 13, 32, 35, 44, 93, 125].contains(byte) { index += 1 }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            if ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(raw) {
                return .other
            }
            let integer = "^[+-]?(0|[1-9](?:_?[0-9])*)$"
            if raw.range(of: integer, options: .regularExpression) != nil,
                let number = Int(raw.replacingOccurrences(of: "_", with: ""))
            {
                return .integer(number)
            }
            let based = "^0(?:x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*|o[0-7](?:_?[0-7])*|b[01](?:_?[01])*)$"
            let float =
                "^[+-]?(?:0|[1-9](?:_?[0-9])*)(?:\\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?|[eE][+-]?[0-9](?:_?[0-9])*)$"
            guard
                raw.range(of: based, options: .regularExpression) != nil
                    || raw.range(of: float, options: .regularExpression) != nil
            else { throw rejected() }
            return .other
        }

        mutating func string(multilineAllowed: Bool) throws -> String {
            guard let quote = peek else { throw rejected() }
            index += 1
            let multiline =
                index + 1 < bytes.count && bytes[index] == quote && bytes[index + 1] == quote
            if multiline {
                guard multilineAllowed else { throw rejected() }
                index += 2
                if take(13) { try require(10) } else { _ = take(10) }
            }
            var result = Data()
            while let byte = peek {
                if byte == quote {
                    if !multiline { index += 1; return String(decoding: result, as: UTF8.self) }
                    if index + 2 < bytes.count && bytes[index + 1] == quote
                        && bytes[index + 2] == quote
                    {
                        index += 3
                        guard peek != quote else { throw rejected() }
                        return String(decoding: result, as: UTF8.self)
                    }
                }
                if byte == 92 && quote == 34 {
                    index += 1
                    if multiline, let next = peek, [9, 10, 13, 32].contains(next) {
                        let start = index
                        while let next = peek, [9, 10, 13, 32].contains(next) { index += 1 }
                        guard bytes[start..<index].contains(10) else { throw rejected() }
                        continue
                    }
                    guard let escape = peek else { throw rejected() }
                    index += 1
                    let escapes: [UInt8: UInt8] = [
                        34: 34, 92: 92, 98: 8, 116: 9, 110: 10, 102: 12, 114: 13,
                    ]
                    if let decoded = escapes[escape] { result.append(decoded); continue }
                    guard escape == 117 || escape == 85 else { throw rejected() }
                    let count = escape == 117 ? 4 : 8
                    guard index + count <= bytes.count else { throw rejected() }
                    let hex = String(decoding: bytes[index..<index + count], as: UTF8.self)
                    guard hex.allSatisfy(\.isHexDigit), let number = UInt32(hex, radix: 16),
                        let scalar = UnicodeScalar(number)
                    else { throw rejected() }
                    result.append(contentsOf: String(scalar).utf8)
                    index += count
                } else {
                    guard byte != 127,
                        byte >= 32 || byte == 9 || (multiline && (byte == 10 || byte == 13))
                    else { throw rejected() }
                    if byte == 13 {
                        guard index + 1 < bytes.count, bytes[index + 1] == 10 else {
                            throw rejected()
                        }
                    }
                    result.append(byte)
                    index += 1
                }
            }
            throw rejected()
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        mutating func require(_ byte: UInt8) throws {
            guard take(byte) else { throw rejected() }
        }

        mutating func spaces() {
            while peek == 9 || peek == 32 { index += 1 }
        }

        mutating func comment() {
            let start = index
            while let byte = peek, byte != 10 { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            _ = take(10)
            comments.append(Comment(start: start, end: index, text: text))
        }

        mutating func skipSpaceAndComments() {
            while index < bytes.count {
                spaces()
                if peek == 35 {
                    comment()
                } else if take(10) {
                    continue
                } else if peek == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 {
                    index += 2
                } else {
                    break
                }
            }
        }

        mutating func endOfStatement() throws {
            spaces()
            if peek == 35 { comment(); return }
            if take(13) { try require(10); return }
            guard take(10) || peek == nil else { throw rejected() }
        }

        func rejected() -> ConfigFileTransactionError {
            .mutationRejected(reason: "Kimi Code TOML 无法安全解析（语法、重复字段或不支持的结构），原文件保持不变")
        }
    }
}
