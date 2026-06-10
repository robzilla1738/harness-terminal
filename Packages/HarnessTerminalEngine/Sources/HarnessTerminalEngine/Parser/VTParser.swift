import Foundation

/// A borrowed, non-escaping view over a CSI sequence's decoded parameters, handed to
/// `VTParserHandler.parserCSI`. Parameters are semicolon-separated *groups*; each group holds its
/// colon-separated sub-parameters, stored flattened in `values` with `starts[g]` marking where
/// group `g` begins. Valid only for the duration of the `parserCSI` call — it wraps the parser's
/// reused buffers (no per-sequence allocation), so it must not be stored or escape the call.
struct CSIParams {
    /// All sub-parameter values, flattened across groups.
    let values: UnsafeBufferPointer<Int>
    /// Start index in `values` of each semicolon-separated group; `starts.count` is the group count.
    let starts: UnsafeBufferPointer<Int>

    /// Number of semicolon-separated parameter groups (`CSI m` → 1, `CSI 1;31 m` → 2).
    var count: Int { starts.count }

    /// Number of colon sub-parameters in group `g` (e.g. `4:3` → 2).
    @inline(__always)
    func subCount(_ g: Int) -> Int {
        guard g >= 0, g < starts.count else { return 0 }
        let lo = starts[g]
        let hi = (g + 1 < starts.count) ? starts[g + 1] : values.count
        return hi - lo
    }

    /// Sub-parameter `sub` of group `g`, or `defaultValue` if absent.
    @inline(__always)
    func sub(_ g: Int, _ sub: Int, default defaultValue: Int = 0) -> Int {
        guard g >= 0, g < starts.count else { return defaultValue }
        let lo = starts[g]
        let hi = (g + 1 < starts.count) ? starts[g + 1] : values.count
        let idx = lo + sub
        guard sub >= 0, idx < hi else { return defaultValue }
        return values[idx]
    }

    /// First sub-parameter of group `g` (the flattened value most control functions use), or 0.
    @inline(__always)
    func first(_ g: Int) -> Int { sub(g, 0) }
}

/// Receives high-level events decoded by `VTParser`. The emulator implements this;
/// the parser knows only escape syntax, never screen semantics.
protocol VTParserHandler: AnyObject {
    /// A printable Unicode scalar (UTF-8 already decoded).
    func parserPrint(_ scalar: UInt32)
    /// A contiguous run of printable ASCII bytes (each `0x20...0x7E`) decoded in the ground state,
    /// to be printed in order. Exactly equivalent to calling `parserPrint(UInt32(b))` for each
    /// byte, but lets the handler write the whole run in one pass. The buffer is borrowed: it is
    /// valid only for the duration of the call and must not escape.
    func parserPrintRun(_ bytes: UnsafeBufferPointer<UInt8>)
    /// A contiguous run of already-decoded printable Unicode scalars (ASCII + well-formed UTF-8)
    /// decoded in the ground state, to be printed in order. Exactly equivalent to calling
    /// `parserPrint(cp)` for each, but lets the handler write the whole run in one pass after the
    /// parser has amortized the UTF-8 decode + per-byte dispatch. The buffer is borrowed: valid only
    /// for the duration of the call and must not escape.
    func parserPrintCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>)
    /// A C0/C1 control byte to execute (BS, HT, LF, CR, BEL, …).
    func parserExecute(_ control: UInt8)
    /// A final CSI byte with its decoded parameters, intermediate bytes, and whether a
    /// private-parameter introducer (`<` `=` `>` `?`) was present — a private-use sequence
    /// (DEC modes, XTMODKEYS, …) that standard functions like SGR are never part of, so the
    /// handler can refuse to misread it. Parameters arrive as a `CSIParams` borrowed view over the
    /// parser's reused storage: semicolon-separated groups, each holding its colon-separated
    /// sub-parameters (e.g. `4:3` → one group `[4, 3]`, `1;31` → two groups `[1]`, `[31]`). The
    /// view is valid **only for the duration of this call** and must not escape (it wraps borrowed
    /// buffers — same contract as `parserPrintRun`), so the parser never allocates per sequence.
    /// `privateMarker` is the actual private-introducer byte (`<` `=` `>` `?`) when `isPrivate`,
    /// so handlers can distinguish e.g. the Kitty-keyboard verbs `CSI > u` / `< u` / `= u` /
    /// `? u`, which differ only by introducer. nil when not a private sequence.
    func parserCSI(final: UInt8, params: CSIParams, intermediates: [UInt8], isPrivate: Bool, privateMarker: UInt8?)
    /// A final ESC byte (non-CSI) with any intermediate bytes (e.g. `ESC ( B`, `ESC M`).
    func parserESC(final: UInt8, intermediates: [UInt8])
    /// A complete OSC string payload (without the introducer or terminator).
    func parserOSC(_ data: [UInt8])
    /// A complete DCS string payload (without the `ESC P` introducer or `ST`), e.g. Sixel.
    func parserDCS(_ data: [UInt8])
    /// A complete APC string payload (without the `ESC _` introducer or `ST`), e.g. the Kitty
    /// graphics protocol.
    func parserAPC(_ data: [UInt8])
}

extension VTParserHandler {
    /// Default: replay the run one scalar at a time, so a run is equivalent to repeated printing
    /// by construction. Handlers that care about throughput override this.
    func parserPrintRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { parserPrint(UInt32(b)) }
    }

    /// Default: replay the run one scalar at a time, so a codepoint run is equivalent to repeated
    /// printing by construction. Handlers that care about throughput override this.
    func parserPrintCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        for cp in codepoints { parserPrint(cp) }
    }
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
        case stringConsume // PM/SOS: skip payload until ST
        case stringCapture // DCS/APC: capture payload (Sixel, Kitty graphics) until ST
    }

    private enum StringKind { case dcs, apc }

    /// The event sink. Held `unowned` (not `weak`): the emulator owns the parser and is the only
    /// `VTParserHandler`, so the handler always outlives every `feed`. `unowned` drops the per-emit
    /// ARC weak-load + the optional-chain branch on the byte hot path (the parser emits a print /
    /// execute / CSI for nearly every input byte), and lets the optimizer devirtualize the witness
    /// call. The parser never escapes the emulator and is never fed after the emulator deinits, so
    /// the non-optional reference is strictly correct.
    private unowned let handler: VTParserHandler
    private var state: State = .ground

    // CSI accumulation, allocation-free across sequences. Parameters are grouped
    // (semicolon-separated), each holding its colon-separated sub-parameters. Sub-parameter values
    // are stored flattened in `paramValues`; `groupStarts[g]` marks where group `g` begins. Both are
    // reused via `removeAll(keepingCapacity: true)` so a flood of SGR sequences never allocates.
    // `currentNumber` accumulates the in-progress digits.
    private var paramValues: [Int] = []
    private var groupStarts: [Int] = []
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

    /// Reused decode buffer for the bulk printable (ASCII + UTF-8) run path — never allocated per
    /// run (cleared with `removeAll(keepingCapacity: true)`), matching the allocation-free contract
    /// of the CSI/OSC buffers.
    private var codepointScratch: [UInt32] = []

    /// Runtime kill-switch for the bulk codepoint run path (`HARNESS_DISABLE_BULK_UTF8=1` to fall
    /// back to the proven per-byte scalar decode). Read once at process start. The bulk path is
    /// proven byte-identical by `CodepointRunFastPathTests`; this exists purely as a no-rebuild
    /// escape hatch.
    static let bulkCodepointRunEnabled =
        ProcessInfo.processInfo.environment["HARNESS_DISABLE_BULK_UTF8"] == nil

    private let maxParams = 32
    /// Bounds the flattened sub-parameter store so a hostile colon-flood (`CSI 1:1:1:…`) can't grow
    /// it without bound. Far above any legitimate sequence (truecolor `38:2:cs:r:g:b` is 6).
    private let maxParamValues = 128
    /// Hard caps so a hostile/buggy stream can't grow these buffers without bound (a memory
    /// DoS via the daemon→app pipe). Real sequences are tiny; 8 intermediates is far above
    /// xterm's 2, and 1 MiB bounds even a large OSC 52 clipboard payload. Past the cap we keep
    /// consuming the (malformed/oversized) sequence but stop accumulating.
    private let maxIntermediates = 8
    private let maxOSCBytes = 1 << 20
    /// OSC 1337 (iTerm2 inline images) can be large; only that OSC gets the bigger budget so the
    /// OSC-52 clipboard DoS bound (`maxOSCBytes`) stays tight for everything else.
    private let maxOSCImageBytes = 32 << 20
    /// DCS/APC image payloads (Sixel, Kitty graphics) — bounded; past the cap we keep consuming
    /// but stop accumulating (the sequence is malformed/oversized).
    private let maxImageStringBytes = 32 << 20
    private var stringKind: StringKind = .dcs
    private var stringBuffer: [UInt8] = []

    #if DEBUG
    /// Debug-only tripwire for the parser's single-threaded contract (see the `feed` docs). Set
    /// across a public `feed`/`feedScalarwise` call and asserted to be clear on entry, so any
    /// concurrent feed from a second thread — or a handler that synchronously re-enters `feed` —
    /// traps loudly in debug instead of corrupting parser state. Compiled out of release builds:
    /// the contract is enforced by the caller (the GUI confines all feeds to one per-surface
    /// serial queue), so this never touches the shipping hot path.
    private var isFeeding = false
    #endif

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
        stringBuffer.removeAll(keepingCapacity: true)
        sawESCInString = false
        utf8Remaining = 0
    }

    /// Feed a chunk of bytes to the parser.
    ///
    /// **Not thread-safe and not reentrant.** The parser holds mutable state and hands the
    /// handler borrowed `UnsafeBufferPointer` views (CSI params, print runs) that are only valid
    /// for the duration of the synchronous call — so all feeds, plus any access to the screen the
    /// handler mutates, must be serialized by the caller. The GUI confines this to one
    /// per-surface serial queue (`SurfaceEmulatorState` in HarnessTerminalKit); a handler must
    /// never synchronously re-enter `feed`. Violations trap in debug via `isFeeding`.
    func feed(_ bytes: [UInt8]) {
        #if DEBUG
        assert(!isFeeding, "VTParser.feed is not reentrant or thread-safe — serialize feeds on one queue")
        isFeeding = true
        defer { isFeeding = false }
        #endif
        bytes.withUnsafeBufferPointer { feedBuffer($0) }
    }

    /// See `feed(_ bytes:)` for the single-threaded, non-reentrant contract.
    func feed(_ data: Data) {
        #if DEBUG
        assert(!isFeeding, "VTParser.feed is not reentrant or thread-safe — serialize feeds on one queue")
        isFeeding = true
        defer { isFeeding = false }
        #endif
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            feedBuffer(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    /// Test/reference seam: drive every byte through the per-byte scalar path, bypassing the
    /// printable-ASCII run fast path. Used by tests to prove the run path is byte-for-byte
    /// equivalent to repeated scalar printing. Same single-threaded contract as `feed(_ bytes:)`.
    func feedScalarwise(_ bytes: [UInt8]) {
        #if DEBUG
        assert(!isFeeding, "VTParser.feed is not reentrant or thread-safe — serialize feeds on one queue")
        isFeeding = true
        defer { isFeeding = false }
        #endif
        for b in bytes { feed(b) }
    }

    // MARK: - Core dispatch

    /// Walk `buf`, batching contiguous printable-ASCII (`0x20...0x7E`) runs while sitting in the
    /// ground state with no partial UTF-8 sequence into a single `parserPrintRun`. Every other
    /// byte — controls, ESC/CSI/OSC/DCS/APC, UTF-8 lead/continuation, high bytes — goes through the
    /// unchanged per-byte `feed`, so the run path only ever short-circuits the common ASCII case.
    private func feedBuffer(_ buf: UnsafeBufferPointer<UInt8>) {
        let n = buf.count
        var i = 0
        while i < n {
            if state == .ground, utf8Remaining == 0, buf[i] >= 0x20, buf[i] < 0x7F {
                let j = printableASCIIRunEnd(buf, from: i + 1, end: n)
                handler.parserPrintRun(UnsafeBufferPointer(rebasing: buf[i ..< j]))
                i = j
            } else if Self.bulkCodepointRunEnabled, state == .ground, utf8Remaining == 0, buf[i] >= 0x80 {
                // A printable run that begins with a UTF-8 lead byte. Bulk-decode it (incl. any
                // trailing ASCII) into `codepointScratch` and emit in one call, amortizing the
                // per-byte dispatch + decode. `decodePrintableRun` stops at the first control/ESC/DEL
                // or any UTF-8 anomaly (invalid/short/overlong/surrogate/out-of-range) — anything it
                // can't cleanly decode is left to the proven per-byte `feed`, which owns the U+FFFD
                // replacement + cross-chunk carry semantics.
                let j = decodePrintableRun(buf, from: i, end: n)
                if j > i {
                    codepointScratch.withUnsafeBufferPointer { handler.parserPrintCodepointRun($0) }
                    i = j
                } else {
                    feed(buf[i])
                    i += 1
                }
            } else {
                feed(buf[i])
                i += 1
            }
        }
    }

    /// Index of the first byte at or after `start` (bounded by `end`) that is **not** printable
    /// ASCII (`0x20...0x7E`) — i.e. the end of a printable-ASCII run. Byte-for-byte equivalent to
    /// the scalar scan `while j < end, buf[j] >= 0x20, buf[j] < 0x7F { j += 1 }`, but vectorized:
    /// a byte stops the run iff `(b &- 0x20) >= 0x5F` unsigned (which is exactly `b < 0x20 ||
    /// b >= 0x7F` — DEL `0x7F` and every high/control byte stop, `0x20...0x7E` continue). Full
    /// 16-wide `SIMD16<UInt8>` chunks are tested at once (`any` to skip clean chunks, first set
    /// lane for the boundary); the trailing `< 16` bytes use the scalar predicate. The 16-wide
    /// loads are gated by `j + 16 <= end`, so it never reads past the buffer.
    @inline(__always)
    private func printableASCIIRunEnd(_ buf: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        guard let base = buf.baseAddress else { return start }
        var j = start
        let bias = SIMD16<UInt8>(repeating: 0x20)
        let threshold = SIMD16<UInt8>(repeating: 0x5F)
        while j + 16 <= end {
            let v = UnsafeRawPointer(base + j).loadUnaligned(as: SIMD16<UInt8>.self)
            let stop = (v &- bias) .>= threshold
            if any(stop) {
                for lane in 0 ..< 16 where stop[lane] { return j + lane }
            }
            j += 16
        }
        while j < end, buf[j] >= 0x20, buf[j] < 0x7F { j += 1 }
        return j
    }

    /// Decode a printable run (ASCII + well-formed UTF-8) starting at `start` (bounded by `end`)
    /// into `codepointScratch`, returning the index one past the last consumed byte. Stops —
    /// keeping whatever was decoded so far — at the first C0/DEL byte (end of run) OR at any UTF-8
    /// anomaly: an invalid lead byte, a continuation byte that isn't `0x80...0xBF`, a sequence
    /// truncated by `end` (a chunk boundary mid-sequence), an overlong encoding, a surrogate, or a
    /// scalar above `0x10FFFF`. On an anomaly it leaves the offending byte unconsumed so the caller
    /// hands it to the per-byte `feed`, which owns the exact U+FFFD-replacement, reprocess-fresh, and
    /// cross-`feed`-call carry-over semantics — so the bulk path only ever handles clean text and
    /// stays byte-identical to the scalar path. Returns `start` (empty scratch) when the first byte
    /// is itself such an anomaly. ESC never reaches here (the caller's ASCII branch handles printable
    /// ASCII and this branch only starts on a `>= 0x80` lead; ESC `0x1B < 0x20` ends the run).
    private func decodePrintableRun(_ buf: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        codepointScratch.removeAll(keepingCapacity: true)
        var p = start
        loop: while p < end {
            let b = buf[p]
            if b >= 0x20, b < 0x7F {            // printable ASCII
                codepointScratch.append(UInt32(b))
                p += 1
                continue
            }
            if b < 0x80 { break }               // C0 control (< 0x20) or DEL (0x7F) — end of run
            // UTF-8 lead byte: classify length, then validate the whole sequence before emitting.
            let length: Int
            let minValue: UInt32
            var value: UInt32
            if b & 0xE0 == 0xC0 { length = 2; value = UInt32(b & 0x1F); minValue = 0x80 }
            else if b & 0xF0 == 0xE0 { length = 3; value = UInt32(b & 0x0F); minValue = 0x800 }
            else if b & 0xF8 == 0xF0 { length = 4; value = UInt32(b & 0x07); minValue = 0x10000 }
            else { break }                      // invalid lead (stray continuation, 0xF8+) — anomaly
            guard p + length <= end else { break }   // truncated by the buffer end — anomaly (carry)
            var k = 1
            while k < length {
                let c = buf[p + k]
                if c & 0xC0 != 0x80 { break loop }   // invalid continuation — anomaly
                value = (value << 6) | UInt32(c & 0x3F)
                k += 1
            }
            // Reject overlong, surrogates, and out-of-range here; the scalar path emits U+FFFD for
            // these, so leave them to it rather than reproduce the replacement inline.
            if value < minValue || (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF { break }
            codepointScratch.append(value)
            p += length
        }
        return p
    }

    private func feed(_ byte: UInt8) {
        // VT500 "anywhere" rule (Williams state machine, events 18/1A): CAN and SUB
        // abort any in-progress sequence and return to ground. Without this, an
        // unterminated OSC/DCS/APC string state would keep consuming output until
        // the next ESC or BEL arrives.
        if byte == 0x18 || byte == 0x1A, state != .ground {
            oscBuffer.removeAll(keepingCapacity: true)
            stringBuffer.removeAll(keepingCapacity: true)
            sawESCInString = false
            clearCSI()
            state = .ground
            handler.parserExecute(byte)
            return
        }
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
        case .stringCapture: stringCapture(byte)
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
            handler.parserExecute(byte)
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
            handler.parserPrint(0xFFFD)
        } else {
            handler.parserPrint(value)
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
        case 0x50: // DCS 'P' — capture (Sixel)
            stringKind = .dcs; stringBuffer.removeAll(keepingCapacity: true); state = .stringCapture
        case 0x5F: // APC '_' — capture (Kitty graphics)
            stringKind = .apc; stringBuffer.removeAll(keepingCapacity: true); state = .stringCapture
        case 0x58, 0x5E: // SOS 'X', PM '^' — no payload of interest, discard
            state = .stringConsume
        case 0x20 ... 0x2F: // intermediate
            appendIntermediate(byte)
            state = .escapeIntermediate
        case 0x30 ... 0x7E: // final
            handler.parserESC(final: byte, intermediates: intermediates)
            state = .ground
        default:
            // C0 control inside ESC: execute and stay.
            if byte < 0x20 { handler.parserExecute(byte) } else { state = .ground }
        }
    }

    private func escapeIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x30 ... 0x7E:
            handler.parserESC(final: byte, intermediates: intermediates)
            state = .ground
        default:
            if byte < 0x20 { handler.parserExecute(byte) } else { state = .ground }
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
            if byte < 0x20 { handler.parserExecute(byte) } else { state = .csiIgnore }
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
            if byte < 0x20 { handler.parserExecute(byte) } else { state = .csiIgnore }
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
            if byte < 0x20 { handler.parserExecute(byte) } else { state = .csiIgnore }
        }
    }

    private func csiIgnore(_ byte: UInt8) {
        // Stay until a final byte ends the (malformed) sequence.
        if (0x40 ... 0x7E).contains(byte) {
            state = .ground
            clearCSI()
        } else if byte < 0x20 {
            handler.parserExecute(byte)
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        finalizeCurrentGroup()
        if !csiOverflow {
            // Borrow the reused buffers for the call only — `CSIParams` must not escape, so the
            // whole dispatch (incl. screen mutation) runs inside the buffer-pointer scope.
            paramValues.withUnsafeBufferPointer { vbuf in
                groupStarts.withUnsafeBufferPointer { gbuf in
                    handler.parserCSI(
                        final: final,
                        params: CSIParams(values: vbuf, starts: gbuf),
                        intermediates: intermediates,
                        isPrivate: csiPrivate,
                        privateMarker: csiPrivateMarker
                    )
                }
            }
        }
        state = .ground
        clearCSI()
    }

    private func pushDigit(_ byte: UInt8) {
        let digit = Int(byte - 0x30)
        let value = (currentNumber ?? 0) * 10 + digit
        // Clamp rather than poison: xterm caps an over-large param at 65535 and still
        // dispatches the sequence. Further digits keep it pinned (accumulation stays
        // bounded, DoS guard preserved); handler-side grid clamps do the rest.
        currentNumber = min(value, 65_535)
    }

    /// Append a value to the flattened store, dropping (and flagging overflow) past the cap.
    private func appendValue(_ value: Int) {
        if paramValues.count >= maxParamValues { csiOverflow = true; return }
        paramValues.append(value)
    }

    /// End the current sub-parameter (`:`), staying within the same parameter group.
    private func pushSubparamSeparator() {
        appendValue(currentNumber ?? 0)
        currentNumber = nil
    }

    /// End the current parameter (`;`): close the current group's last sub-parameter and open a new
    /// group at the current end of the flattened store.
    private func pushParamSeparator() {
        appendValue(currentNumber ?? 0)
        currentNumber = nil
        if groupStarts.count >= maxParams { csiOverflow = true; return }
        groupStarts.append(paramValues.count)
    }

    /// Flush the in-progress number into the final group at dispatch time so a trailing parameter is
    /// always emitted (e.g. `CSI m` → one group `[0]`, matching the prior flat `[0]`).
    private func finalizeCurrentGroup() {
        appendValue(currentNumber ?? 0)
        currentNumber = nil
    }

    private func clearCSI() {
        paramValues.removeAll(keepingCapacity: true)
        groupStarts.removeAll(keepingCapacity: true)
        groupStarts.append(0) // group 0 always begins at the start of the (empty) value store
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
                handler.parserOSC(oscBuffer)
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
            handler.parserOSC(oscBuffer)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
        case 0x1B:
            sawESCInString = true
        default:
            if oscBuffer.count < oscCap { oscBuffer.append(byte) }
        }
    }

    /// OSC byte budget: the larger image cap once the buffer is recognizably `1337;…` (iTerm2
    /// inline image), otherwise the tight default that bounds OSC-52 clipboard floods.
    private var oscCap: Int {
        if oscBuffer.count >= 5,
           oscBuffer[0] == 0x31, oscBuffer[1] == 0x33, oscBuffer[2] == 0x33, oscBuffer[3] == 0x37,
           oscBuffer[4] == 0x3B { // "1337;"
            return maxOSCImageBytes
        }
        return maxOSCBytes
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

    /// Capture a DCS/APC payload until its String Terminator (`ESC \`) or BEL, then dispatch it
    /// (Sixel via `parserDCS`, Kitty graphics via `parserAPC`). Bounded by `maxImageStringBytes`.
    private func stringCapture(_ byte: UInt8) {
        if sawESCInString {
            sawESCInString = false
            if byte == 0x5C { dispatchCapturedString(); state = .ground; return }
            // A lone ESC aborts the string and reprocesses from ground.
            stringBuffer.removeAll(keepingCapacity: true)
            state = .ground
            feedFromGround(byte)
            return
        }
        switch byte {
        case 0x07: // BEL terminates
            dispatchCapturedString(); state = .ground
        case 0x1B:
            sawESCInString = true
        default:
            if stringBuffer.count < maxImageStringBytes { stringBuffer.append(byte) }
        }
    }

    private func dispatchCapturedString() {
        switch stringKind {
        case .dcs: handler.parserDCS(stringBuffer)
        case .apc: handler.parserAPC(stringBuffer)
        }
        stringBuffer.removeAll(keepingCapacity: true)
    }

    /// Reprocess a byte as if freshly arriving in the ground state. Used when a string
    /// state aborts on an unexpected ESC sequence.
    private func feedFromGround(_ byte: UInt8) {
        state = .ground
        feed(byte)
    }
}
