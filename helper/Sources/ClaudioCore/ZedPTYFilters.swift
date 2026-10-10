import Foundation

/// The outer PTY owns focus reports. All other keyboard bytes remain the child's input.
public struct ZedPTYInputFilter {
    private var stream = PTYVTStream()
    private var pasting = false
    public init() {}

    public mutating func consume(_ data: Data, forwardFocus: Bool)
        -> (bytes: Data, focus: [Bool], hasInput: Bool)
    {
        var bytes = Data(), focus: [Bool] = []
        var hasInput = false
        var pasting = self.pasting
        stream.consume(data) { token, control in
            guard control else { bytes.append(token); hasInput = true; return }
            if token == Data("\u{1B}[200~".utf8) { pasting = true }
            if token == Data("\u{1B}[201~".utf8) { pasting = false }
            if !pasting, token == Data("\u{1B}[I".utf8) || token == Data("\u{1B}[O".utf8) {
                focus.append(token.last == 0x49)
                if forwardFocus { bytes.append(token) }
            } else {
                bytes.append(token)
                hasInput = true
            }
        }
        self.pasting = pasting
        return (bytes, focus, hasInput)
    }

    public mutating func finish() -> Data { stream.finish() }
    public var hasPending: Bool { stream.hasPending }
    public mutating func flushPending() -> Data { stream.flushPending() }
}

/// Virtualizes only DEC private mode 1004 so a child TUI cannot turn off the bridge's reports.
/// Color, OSC, mouse, bracketed paste and all unrelated terminal protocols pass through.
public struct ZedPTYOutputFilter {
    private var stream = PTYVTStream()
    public private(set) var childWantsFocus = false
    private var savedChildFocus: Bool?
    public init() {}

    public mutating func consume(_ data: Data) -> (bytes: Data, reply: Data) {
        var bytes = Data(), reply = Data()
        var childWantsFocus = self.childWantsFocus
        var savedChildFocus = self.savedChildFocus
        stream.consume(data) { token, control in
            guard control else { bytes.append(token); return }
            if token == Data("\u{1B}c".utf8) || token == Data("\u{1B}[!p".utf8) {
                childWantsFocus = false
                savedChildFocus = nil
                bytes.append(token); bytes.append(Data("\u{1B}[?1004h".utf8))
            } else if token.starts(with: [0x1B, 0x5B, 0x3F]),
                [0x68, 0x6C, 0x73, 0x72].contains(token.last!)
                    || token.suffix(2) == Data("$p".utf8),
                let parameters = String(
                    data: token.dropFirst(3).dropLast(token.last == 0x70 ? 2 : 1), encoding: .ascii),
                parameters.utf8.allSatisfy({ (48...57).contains($0) || $0 == 59 })
            {
                let modes = parameters.split(separator: ";", omittingEmptySubsequences: false)
                guard modes.contains(where: { UInt32($0) == 1004 }) else {
                    bytes.append(token); return
                }
                switch token.last {
                case 0x68: childWantsFocus = true
                case 0x6C: childWantsFocus = false
                case 0x73: savedChildFocus = childWantsFocus
                case 0x72: if let savedChildFocus { childWantsFocus = savedChildFocus }
                case 0x70: reply.append(Data("\u{1B}[?1004;\(childWantsFocus ? 1 : 2)$y".utf8))
                default: break
                }
                let remaining = modes.filter { UInt32($0) != 1004 }
                if !remaining.isEmpty {
                    bytes.append(Data("\u{1B}[?\(remaining.joined(separator: ";"))".utf8))
                    if token.last == 0x70 { bytes.append(0x24) }
                    bytes.append(token.last!)
                }
            } else {
                bytes.append(token)
            }
        }
        self.childWantsFocus = childWantsFocus
        self.savedChildFocus = savedChildFocus
        return (bytes, reply)
    }

    public mutating func finish() -> Data { stream.finish() }
    public var hasPending: Bool { stream.hasPending }
    public mutating func flushPending() -> Data { stream.flushPending() }
}

/// Bounded VT tokenizer. Control strings stream without interpretation or retained payloads.
private struct PTYVTStream {
    private var pending = Data()
    private var opaque: UInt8?
    private var opaqueEscape = false
    var hasPending: Bool { !pending.isEmpty }

    mutating func flushPending() -> Data {
        let result = pending
        pending.removeAll()
        return result
    }

    mutating func consume(_ data: Data, emit: (Data, Bool) -> Void) {
        var ordinary = Data()
        func flush() {
            if !ordinary.isEmpty {
                emit(ordinary, false); ordinary.removeAll(keepingCapacity: true)
            }
        }
        for byte in data {
            if let opaque {
                ordinary.append(byte)
                if (opaque == 0x5D && byte == 7) || (opaqueEscape && byte == 0x5C) {
                    self.opaque = nil
                }
                opaqueEscape = byte == 0x1B
                continue
            }
            if pending.isEmpty {
                if byte == 0x1B { flush(); pending.append(byte) } else { ordinary.append(byte) }
            } else if pending.count == 1 {
                if byte == 0x5B {
                    pending.append(byte)
                } else if byte == 0x1B {
                    ordinary.append(0x1B)
                } else {
                    pending.append(byte)
                    if [0x5D, 0x50, 0x5F, 0x5E, 0x58].contains(byte) {
                        opaque = byte; opaqueEscape = false
                    }
                    flush(); emit(pending, byte == 0x63); pending.removeAll(keepingCapacity: true)
                }
            } else {
                pending.append(byte)
                if (0x40...0x7E).contains(byte) || !(0x20...0x3F).contains(byte)
                    || pending.count >= 256
                {
                    flush(); emit(pending, (0x40...0x7E).contains(byte))
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        flush()
    }

    mutating func finish() -> Data {
        let result = pending
        pending.removeAll(); opaque = nil; opaqueEscape = false
        return result
    }
}
