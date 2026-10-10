import Foundation

/// Bytes the daemon has to notice without running a terminal emulator on the PTY read.
public enum PtyScanEvent: Equatable, Sendable {
    case bell
    case osc(code: Int, body: String, sequenceLength: Int)
    case cursorKeys(application: Bool)
    case bracketedPaste(Bool)
    case keypad(application: Bool)
    case kittyPush(UInt8)
    case kittyPop(Int)
    case kittySet(flags: UInt8, mode: Int)
    /// RIS (`ESC c`). Resets program status and the keyboard-mode mirror.
    case ris
}
public struct AnchoredPtyScanEvent: Equatable, Sendable {
    public var event: PtyScanEvent
    /// The first byte after the event, in the stable terminal stream epoch.
    public var endSequence: UInt64
}

/// Keyboard-mode mirror tracked from the same bytes `PtyStreamScanner` sees.
public struct KeyboardModeMirror: Equatable, Sendable, Codable {
    public var cursorKeysApplication = false
    public var keypadApplication = false
    public var bracketedPaste = false
    public var kittyStack: [UInt8] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case cursorKeysApplication, keypadApplication, kittyStack, bracketedPaste }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cursorKeysApplication = try values.decode(Bool.self, forKey: .cursorKeysApplication)
        keypadApplication = try values.decode(Bool.self, forKey: .keypadApplication)
        kittyStack = try values.decode([UInt8].self, forKey: .kittyStack)
        bracketedPaste = try values.decodeIfPresent(Bool.self, forKey: .bracketedPaste) ?? false
        guard kittyStack.count <= 32 else { throw DecodingError.dataCorruptedError(forKey: .kittyStack, in: values, debugDescription: "Keyboard stack exceeds its bounded depth.") }
    }

    public var kittyFlags: UInt8 { kittyStack.last ?? 0 }

    public var terminalModes: TerminalModes {
        var modes = TerminalModes()
        modes.cursorKeysApplication = cursorKeysApplication
        modes.keypadApplication = keypadApplication
        modes.bracketedPaste = bracketedPaste
        modes.kittyKeyboardStack = kittyStack
        return modes
    }

    public mutating func apply(_ event: PtyScanEvent) {
        switch event {
        case let .bracketedPaste(enabled): bracketedPaste = enabled
        case let .cursorKeys(application):
            cursorKeysApplication = application
        case let .keypad(application):
            keypadApplication = application
        case let .kittyPush(flags):
            if kittyStack.count < 32 { kittyStack.append(flags) }
        case let .kittyPop(count):
            let n = max(1, count)
            kittyStack.removeLast(min(n, kittyStack.count))
        case let .kittySet(flags, mode):
            let current = kittyStack.last ?? 0
            let next: UInt8
            switch mode {
            case 2: next = current | flags
            case 3: next = current & ~flags
            default: next = flags
            }
            if kittyStack.isEmpty { kittyStack.append(next) }
            else { kittyStack[kittyStack.count - 1] = next }
        case .bell, .osc:
            break
        case .ris:
            self = KeyboardModeMirror()
        }
    }
}

/// Linear scan of PTY output. State threads across chunks. OSC bodies are capped at the
/// program-status sequence limit so a hostile stream cannot grow the buffer.
public struct PtyStreamScanner: Equatable, Sendable, Codable {
    public enum Phase: Equatable, Sendable, Codable {
        case ground
        case esc
        case csi
        case osc
        case oscEsc
        case string
        case stringEsc
    }

    public var phase: Phase = .ground
    public var buffer: [UInt8] = []
    public var length = 0
    public var overflow = false

    private static let interestingOSC: Set<Int> = [0, 2, 7, 9, 52, 133, 777, 7501]
    private static let maxBuffer = ProgramStatusRevision.maxSequenceBytes

    public init() {}

    public mutating func scan(_ data: Data) -> [PtyScanEvent] {
        var events: [PtyScanEvent] = []
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                // Ordinary output cannot change monitoring state. Avoid allocating/copying
                // an empty event array for every printable byte on the delivery queue.
                if phase == .ground, byte != 0x1B, byte != 0x07 { continue }
                let emitted = feed(byte)
                if !emitted.isEmpty { events.append(contentsOf: emitted) }
            }
        }
        return events
    }
    public mutating func scanAnchored(_ data: Data, sequence: UInt64) -> [AnchoredPtyScanEvent] {
        var events: [AnchoredPtyScanEvent] = []
        visit(data, sequence: sequence) { events.append($0) }
        return events
    }
    public mutating func visit(_ data: Data, sequence: UInt64 = 0, receive: (AnchoredPtyScanEvent) -> Void) {
        data.withUnsafeBytes { raw in
            for (offset, byte) in raw.bindMemory(to: UInt8.self).enumerated() {
                if phase == .ground, byte != 0x1B, byte != 0x07 { continue }
                for event in feed(byte) {
                    receive(AnchoredPtyScanEvent(event: event, endSequence: sequence + UInt64(offset) + 1))
                }
            }
        }
    }

    private mutating func feed(_ byte: UInt8) -> [PtyScanEvent] {
        switch phase {
        case .ground:
            if byte == 0x1B { phase = .esc }
            else if byte == 0x07 { return [.bell] }
        case .esc:
            switch byte {
            case 0x5B: // CSI
                phase = .csi
                buffer.removeAll(keepingCapacity: true)
            case 0x5D: // OSC
                beginOSC()
            case 0x50, 0x5F, 0x5E, 0x58: // DCS APC PM SOS
                phase = .string
            case 0x3D:
                phase = .ground
                return [.keypad(application: true)]
            case 0x3E:
                phase = .ground
                return [.keypad(application: false)]
            case 0x1B:
                phase = .esc
            case 0x07:
                phase = .ground
                return [.bell]
            case 0x63: // RIS, ESC c
                phase = .ground
                return [.ris]
            default:
                phase = .ground
            }
        case .csi:
            if byte == 0x1B {
                phase = .esc
                return []
            }
            if buffer.count < 64 { buffer.append(byte) }
            if (0x40 ... 0x7E).contains(byte) {
                let events = finishCSI()
                buffer.removeAll(keepingCapacity: true)
                phase = .ground
                return events
            }
        case .osc:
            if byte == 0x07 {
                return finishOSC(terminator: 1)
            }
            if byte == 0x1B {
                phase = .oscEsc
                return []
            }
            if byte == 0x18 || byte == 0x1A {
                phase = .ground
                buffer.removeAll(keepingCapacity: true)
                return []
            }
            length += 1
            if length > ProgramStatusRevision.maxSequenceBytes { overflow = true }
            if !overflow, buffer.count < Self.maxBuffer { buffer.append(byte) }
        case .oscEsc:
            if byte == 0x5C || byte == 0x07 { return finishOSC(terminator: 2) }
            if byte == 0x18 || byte == 0x1A { phase = .ground; buffer.removeAll(keepingCapacity: true); return [] }
            if byte == 0x1B { length += 1; if length > ProgramStatusRevision.maxSequenceBytes { overflow = true }; return [] }
            phase = .osc
            length += 2
            if !overflow, buffer.count + 2 <= Self.maxBuffer { buffer.append(0x1B) }
            if length > ProgramStatusRevision.maxSequenceBytes { overflow = true }
            if !overflow, buffer.count < Self.maxBuffer { buffer.append(byte) }
        case .string:
            if byte == 0x1B { phase = .stringEsc }
            else if byte == 0x18 || byte == 0x1A { phase = .ground }
        case .stringEsc:
            if byte == 0x5C || byte == 0x18 || byte == 0x1A { phase = .ground }
            else if byte != 0x1B { phase = .string }
        }
        return []
    }

    private mutating func beginOSC() {
        phase = .osc
        buffer.removeAll(keepingCapacity: true)
        length = 2 // ESC ]
        overflow = false
    }

    private mutating func finishOSC(terminator: Int) -> [PtyScanEvent] {
        length += terminator
        let sequenceLength = overflow ? ProgramStatusRevision.maxSequenceBytes + 1 : length
        let bytes = buffer
        buffer.removeAll(keepingCapacity: true)
        phase = .ground
        guard let parsed = Self.parseOSC(bytes), Self.interestingOSC.contains(parsed.code) else { return [] }
        return [.osc(code: parsed.code, body: parsed.body, sequenceLength: sequenceLength)]
    }

    private static func parseOSC(_ bytes: [UInt8]) -> (code: Int, body: String)? {
        guard let semi = bytes.firstIndex(of: 0x3B) else { return nil }
        let codeBytes = bytes[..<semi]
        guard !codeBytes.isEmpty, codeBytes.count <= 4,
              !(codeBytes.count > 1 && codeBytes.first == 0x30) else { return nil }
        var code = 0
        for byte in codeBytes {
            guard (0x30 ... 0x39).contains(byte) else { return nil }
            code = code * 10 + Int(byte - 0x30)
        }
        let body = String(bytes: bytes[(semi + 1)...], encoding: .utf8) ?? ""
        return (code, body)
    }

    private func finishCSI() -> [PtyScanEvent] {
        guard let final = buffer.last else { return [] }
        let head = buffer.dropLast()
        guard let marker = head.first, marker == 0x3F || marker == 0x3E || marker == 0x3C || marker == 0x3D else {
            return []
        }
        let params = head.dropFirst().split(separator: 0x3B).map { chunk -> Int in
            Int(String(bytes: chunk, encoding: .utf8) ?? "") ?? 0
        }
        switch (marker, final) {
        case (0x3F, 0x68), (0x3F, 0x6C): // DECCKM among private modes
            var events: [PtyScanEvent] = []
            if params.contains(1) { events.append(.cursorKeys(application: final == 0x68)) }
            if params.contains(2004) { events.append(.bracketedPaste(final == 0x68)) }
            return events
        case (0x3E, 0x75):
            return [.kittyPush(UInt8(truncatingIfNeeded: params.first ?? 0))]
        case (0x3C, 0x75):
            return [.kittyPop(max(1, params.first ?? 1))]
        case (0x3D, 0x75):
            return [.kittySet(flags: UInt8(truncatingIfNeeded: params.first ?? 0), mode: params.count > 1 ? params[1] : 1)]
        default:
            return []
        }
    }
}

extension ProgramStatusBook {
    /// OSC 133 `D` / `D;<code>` — the shell-integration command-finished report.
    public static func commandExitCode(_ body: String) -> Int? {
        guard body == "D" || body.hasPrefix("D;") else { return nil }
        if body == "D" { return 0 }
        let field = body.dropFirst(2).split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return Int(field)
    }

    /// Apply one scanner event. Returns a query reply when the program asked `OSC 7501 ; ?`.
    public mutating func apply(scan event: PtyScanEvent) -> String? {
        if case .ris = event {
            reset()
            return nil
        }
        guard case let .osc(code, body, sequenceLength) = event else { return nil }
        switch code {
        case 7501:
            if apply(body: body, sequenceLength: sequenceLength) == .query {
                return ProgramStatusRevision.queryReply
            }
        case 133 where body == "A" || body.hasPrefix("A;"):
            dropEphemeral()
        case 9:
            if let report = Self.progressReport(body) { applyOSC94(report) }
        default:
            break
        }
        return nil
    }

    private static func progressReport(_ payload: String) -> TerminalProgressReport? {
        guard payload == "4" || payload.hasPrefix("4;") else { return nil }
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let raw = Int(parts[1]),
              let state = TerminalProgressReport.State(rawValue: raw) else { return nil }
        let value = parts.count >= 3 ? Int(parts[2]).map { max(0, min(100, $0)) } : nil
        return TerminalProgressReport(state: state, value: value)
    }
}
