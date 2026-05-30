import Foundation

/// Receives high-level events decoded by `VTParser`. The emulator implements this;
/// the parser knows only escape syntax, never screen semantics.
protocol VTParserHandler: AnyObject {
    /// A printable Unicode scalar (UTF-8 already decoded).
    func parserPrint(_ scalar: UInt32)
    /// A C0/C1 control byte to execute (BS, HT, LF, CR, BEL, …).
    func parserExecute(_ control: UInt8)
    /// A final CSI byte with its decoded parameters, intermediate bytes, and whether a
    /// private-parameter introducer (`<` `=` `>` `?`) was present — a private-use sequence
    /// (DEC modes, XTMODKEYS, …) that standard functions like SGR are never part of, so the
    /// handler can refuse to misread it. Parameters are grouped: the outer array is
    /// semicolon-separated parameters; each inner array holds that parameter's
    /// colon-separated sub-parameters (e.g. `4:3` → `[[4, 3]]`, `1;31` → `[[1], [31]]`).
    /// `privateMarker` is the actual private-introducer byte (`<` `=` `>` `?`) when `isPrivate`,
    /// so handlers can distinguish e.g. the Kitty-keyboard verbs `CSI > u` / `< u` / `= u` /
    /// `? u`, which differ only by introducer. nil when not a private sequence.
    func parserCSI(final: UInt8, params: [[Int]], intermediates: [UInt8], isPrivate: Bool, privateMarker: UInt8?)
    /// A final ESC byte (non-CSI) with any intermediate bytes (e.g. `ESC ( B`, `ESC M`).
    func parserESC(final: UInt8, intermediates: [UInt8])
    /// A complete OSC string payload (without the introducer or terminator).
    func parserOSC(_ data: [UInt8])
}

/// A streaming VT100/VT220/xterm parser based on the canonical VT500 state machine
/// (Paul Williams). It is byte-oriented with an inline UTF-8 decoder in the ground
/// state, and dispatches structured events to a `VTParserHandler`.
///
/// Scope: ground/escape/CSI (with colon sub-parameters, e.g. `4:3`)/OSC, plus
/// DCS/PM/APC/SOS string *consumption* (their payloads are skipped until the string
/// terminator). Acting on DCS device-control payloads is tracked as a follow-up.
final class VTParser {
    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case stringConsume // DCS/PM/APC/SOS: skip payload until ST
    }

    private weak var handler: VTParserHandler?
    private var state: State = .ground

    // CSI accumulation. Parameters are grouped (semicolon-separated), each holding its
    // colon-separated sub-parameters. `currentGroup` accumulates the in-progress group
    // and `currentNumber` the in-progress digits.
    private var paramGroups: [[Int]] = []
    private var currentGroup: [Int] = []
    private var currentNumber: Int? = nil
    private var intermediates: [UInt8] = []
    private var csiPrivate = false
    /// The private-introducer byte (`<` `=` `>` `?`) when `csiPrivate`; nil otherwise.
    private var csiPrivateMarker: UInt8?
    private var csiOverflow = false

    // OSC / string accumulation
    private var oscBuffer: [UInt8] = []
    /// Set when an ESC is seen inside an OSC/DCS/PM/APC/SOS string, so the next byte can
    /// be tested for the `\` that completes a String Terminator (`ESC \`).
    private var sawESCInString = false

    // UTF-8 decoding (ground state)
    private var utf8Remaining = 0
    private var utf8Accumulator: UInt32 = 0
    private var utf8Min: UInt32 = 0

    private let maxParams = 32
    /// Hard caps so a hostile/buggy stream can't grow these buffers without bound (a memory
    /// DoS via the daemon→app pipe). Real sequences are tiny; 8 intermediates is far above
    /// xterm's 2, and 1 MiB bounds even a large OSC 52 clipboard payload. Past the cap we keep
    /// consuming the (malformed/oversized) sequence but stop accumulating.
    private let maxIntermediates = 8
    private let maxOSCBytes = 1 << 20

    /// Append an intermediate byte, dropping anything past the cap.
    private func appendIntermediate(_ byte: UInt8) {
        if intermediates.count < maxIntermediates { intermediates.append(byte) }
    }

    init(handler: VTParserHandler) {
        self.handler = handler
    }

    func reset() {
        state = .ground
        clearCSI()
        oscBuffer.removeAll(keepingCapacity: true)
        sawESCInString = false
        utf8Remaining = 0
    }

    func feed(_ bytes: [UInt8]) {
        for b in bytes { feed(b) }
    }

    func feed(_ data: Data) {
        for b in data { feed(b) }
    }

    // MARK: - Core dispatch

    private func feed(_ byte: UInt8) {
        switch state {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .escapeIntermediate: escapeIntermediate(byte)
        case .csiEntry: csiEntry(byte)
        case .csiParam: csiParam(byte)
        case .csiIntermediate: csiIntermediate(byte)
        case .csiIgnore: csiIgnore(byte)
        case .oscString: oscString(byte)
        case .stringConsume: stringConsume(byte)
        }
    }

    // MARK: - Ground (printable + C0 + UTF-8)

    private func ground(_ byte: UInt8) {
        // Mid-UTF-8 sequence?
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Accumulator = (utf8Accumulator << 6) | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                if utf8Remaining == 0 {
                    emitScalar(utf8Accumulator >= utf8Min ? utf8Accumulator : 0xFFFD)
                }
                return
            }
            // Invalid continuation: emit replacement, then reprocess this byte fresh.
            emitScalar(0xFFFD)
            utf8Remaining = 0
            ground(byte)
            return
        }

        if byte == 0x1B { // ESC
            enterEscape()
            return
        }
        if byte < 0x20 || byte == 0x7F { // C0 controls (and DEL)
            handler?.parserExecute(byte)
            return
        }
        if byte < 0x80 { // ASCII printable
            emitScalar(UInt32(byte))
            return
        }

        // Start of a UTF-8 multi-byte sequence.
        if byte & 0xE0 == 0xC0 {
            utf8Remaining = 1; utf8Accumulator = UInt32(byte & 0x1F); utf8Min = 0x80
        } else if byte & 0xF0 == 0xE0 {
            utf8Remaining = 2; utf8Accumulator = UInt32(byte & 0x0F); utf8Min = 0x800
        } else if byte & 0xF8 == 0xF0 {
            utf8Remaining = 3; utf8Accumulator = UInt32(byte & 0x07); utf8Min = 0x10000
        } else {
            emitScalar(0xFFFD) // invalid leading byte
        }
    }

    private func emitScalar(_ value: UInt32) {
        // Reject surrogate range and out-of-range scalars.
        if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF {
            handler?.parserPrint(0xFFFD)
        } else {
            handler?.parserPrint(value)
        }
    }

    // MARK: - Escape

    private func enterEscape() {
        state = .escape
        clearCSI()
    }

    private func escape(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            // Another ESC restarts the sequence.
            clearCSI()
        case 0x5B: // '['
            state = .csiEntry
        case 0x5D: // ']'
            oscBuffer.removeAll(keepingCapacity: true)
            state = .oscString
        case 0x50, 0x58, 0x5E, 0x5F: // DCS 'P', SOS 'X', PM '^', APC '_'
            state = .stringConsume
        case 0x20 ... 0x2F: // intermediate
            appendIntermediate(byte)
            state = .escapeIntermediate
        case 0x30 ... 0x7E: // final
            handler?.parserESC(final: byte, intermediates: intermediates)
            state = .ground
        default:
            // C0 control inside ESC: execute and stay.
            if byte < 0x20 { handler?.parserExecute(byte) } else { state = .ground }
        }
    }

    private func escapeIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x30 ... 0x7E:
            handler?.parserESC(final: byte, intermediates: intermediates)
            state = .ground
        default:
            if byte < 0x20 { handler?.parserExecute(byte) } else { state = .ground }
        }
    }

    // MARK: - CSI

    private func csiEntry(_ byte: UInt8) {
        switch byte {
        case 0x30 ... 0x39: // digit
            pushDigit(byte); state = .csiParam
        case 0x3B: // ';' — next parameter
            pushParamSeparator(); state = .csiParam
        case 0x3A: // ':' — next sub-parameter of the current parameter
            pushSubparamSeparator(); state = .csiParam
        case 0x3C ... 0x3F: // private-parameter introducers  <  =  >  ?
            // ANY of these marks the whole CSI as a private-use sequence (DEC modes `?…h/l`,
            // XTMODKEYS `>…m`, XTVERSION `>…q`, etc.). SGR and other standard functions are
            // never private, so the handler must not treat e.g. `\e[>4;1m` as SGR `4;1m`.
            csiPrivate = true
            csiPrivateMarker = byte
            state = .csiParam
        case 0x20 ... 0x2F: // intermediate
            appendIntermediate(byte); state = .csiIntermediate
        case 0x40 ... 0x7E: // final
            dispatchCSI(byte)
        case 0x7F:
            break // ignore DEL
        default:
            if byte < 0x20 { handler?.parserExecute(byte) } else { state = .csiIgnore }
        }
    }

    private func csiParam(_ byte: UInt8) {
        switch byte {
        case 0x30 ... 0x39:
            pushDigit(byte)
        case 0x3B:
            pushParamSeparator()
        case 0x3A:
            pushSubparamSeparator()
        case 0x3C ... 0x3F:
            state = .csiIgnore // private marker after params is malformed
        case 0x20 ... 0x2F:
            appendIntermediate(byte); state = .csiIntermediate
        case 0x40 ... 0x7E:
            dispatchCSI(byte)
        case 0x7F:
            break
        default:
            if byte < 0x20 { handler?.parserExecute(byte) } else { state = .csiIgnore }
        }
    }

    private func csiIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x40 ... 0x7E:
            dispatchCSI(byte)
        case 0x7F:
            break
        default:
            if byte < 0x20 { handler?.parserExecute(byte) } else { state = .csiIgnore }
        }
    }

    private func csiIgnore(_ byte: UInt8) {
        // Stay until a final byte ends the (malformed) sequence.
        if (0x40 ... 0x7E).contains(byte) {
            state = .ground
            clearCSI()
        } else if byte < 0x20 {
            handler?.parserExecute(byte)
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        finalizeCurrentGroup()
        if !csiOverflow {
            handler?.parserCSI(
                final: final,
                params: paramGroups,
                intermediates: intermediates,
                isPrivate: csiPrivate,
                privateMarker: csiPrivateMarker
            )
        }
        state = .ground
        clearCSI()
    }

    private func pushDigit(_ byte: UInt8) {
        let digit = Int(byte - 0x30)
        let value = (currentNumber ?? 0) * 10 + digit
        if value > 65_535 { csiOverflow = true; return }
        currentNumber = value
    }

    /// End the current sub-parameter (`:`), staying within the same parameter group.
    private func pushSubparamSeparator() {
        currentGroup.append(currentNumber ?? 0)
        currentNumber = nil
    }

    /// End the current parameter (`;`), opening a new group.
    private func pushParamSeparator() {
        currentGroup.append(currentNumber ?? 0)
        currentNumber = nil
        appendGroup(currentGroup)
        currentGroup = []
    }

    /// Flush the in-progress number + group at dispatch time so a trailing parameter is
    /// always emitted (e.g. `CSI m` → `[[0]]`, matching the prior flat `[0]`).
    private func finalizeCurrentGroup() {
        currentGroup.append(currentNumber ?? 0)
        currentNumber = nil
        appendGroup(currentGroup)
        currentGroup = []
    }

    private func appendGroup(_ group: [Int]) {
        if paramGroups.count >= maxParams { csiOverflow = true; return }
        paramGroups.append(group)
    }

    private func clearCSI() {
        paramGroups.removeAll(keepingCapacity: true)
        currentGroup.removeAll(keepingCapacity: true)
        currentNumber = nil
        intermediates.removeAll(keepingCapacity: true)
        csiPrivate = false
        csiPrivateMarker = nil
        csiOverflow = false
    }

    // MARK: - OSC

    private func oscString(_ byte: UInt8) {
        // A preceding ESC means we may be looking at an ST (`ESC \`).
        if sawESCInString {
            sawESCInString = false
            if byte == 0x5C { // backslash → ST terminates the string
                handler?.parserOSC(oscBuffer)
                oscBuffer.removeAll(keepingCapacity: true)
                state = .ground
                return
            }
            // A lone ESC inside OSC aborts the string and reprocesses from ground.
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
            feedFromGround(byte)
            return
        }
        switch byte {
        case 0x07: // BEL terminates OSC
            handler?.parserOSC(oscBuffer)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
        case 0x1B:
            sawESCInString = true
        default:
            if oscBuffer.count < maxOSCBytes { oscBuffer.append(byte) }
        }
    }

    // MARK: - DCS / PM / APC / SOS payload consumption

    /// Skip the payload of a device-control / privacy / application-program string
    /// until its String Terminator (`ESC \`) or BEL. Phase 1 does not act on these.
    private func stringConsume(_ byte: UInt8) {
        if sawESCInString {
            sawESCInString = false
            if byte == 0x5C { state = .ground; return }
            state = .ground
            feedFromGround(byte)
            return
        }
        switch byte {
        case 0x07:
            state = .ground
        case 0x1B:
            sawESCInString = true
        default:
            break
        }
    }

    /// Reprocess a byte as if freshly arriving in the ground state. Used when a string
    /// state aborts on an unexpected ESC sequence.
    private func feedFromGround(_ byte: UInt8) {
        state = .ground
        feed(byte)
    }
}
