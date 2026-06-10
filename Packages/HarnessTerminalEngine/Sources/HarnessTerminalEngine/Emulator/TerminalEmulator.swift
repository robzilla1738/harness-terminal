import Foundation
import Dispatch // DispatchTime: a monotonic clock for command-duration timing (explicit for Linux)

/// A headless terminal emulator: feed it PTY output bytes, query the screen via
/// `readGrid()`. It owns the parser, the primary + alternate screens, terminal modes,
/// and emits host-facing events (title, working directory, bell) and PTY responses
/// (DSR/DA) through closures.
///
/// This is the engine's public driver. The live Metal renderer and the headless
/// `harness attach` compositor both build on it; `HarnessGridTerminal` in
/// HarnessTerminalKit is a thin wrapper that adapts it to the existing call sites.
///
/// PTY spawning, scrollback storage, and process lifecycle are NOT here — they are
/// daemon-owned. The emulator only consumes bytes and renders the viewport.
///
/// **Threading contract:** this type is not thread-safe. `feed`, the screen it mutates, and the
/// `onResponse`/`onBell`/… callbacks must all be driven from a single serialized context — the
/// GUI confines each surface's emulator to one serial queue (`SurfaceEmulatorState` in
/// HarnessTerminalKit). The underlying `VTParser` hands borrowed buffer views to the handler that
/// are only valid within the synchronous `feed` call, so concurrent or reentrant feeds would be a
/// use-after-free; `VTParser` carries a debug-only tripwire that traps on violations.
public final class TerminalEmulator: VTParserHandler {
    private var parser: VTParser!
    private let primary: TerminalScreen
    private let alternate: TerminalScreen
    private var current: TerminalScreen
    private var onAlternateScreen = false

    /// Terminal modes that the host queries to encode input correctly (Phase 6).
    public private(set) var modes = TerminalModes()

    public var cols: Int { current.cols }
    public var rows: Int { current.rows }

    // MARK: Host callbacks

    /// Window/tab title (OSC 0 / OSC 2).
    public var onTitleChange: ((String) -> Void)?
    /// Reported working directory (OSC 7).
    public var onWorkingDirectoryChange: ((String) -> Void)?
    /// Terminal bell (BEL / `\a`).
    public var onBell: (() -> Void)?
    /// A shell command finished (OSC 133 `D`), with how long it ran (since the `C`/`B` mark) and
    /// its exit code. Drives the "long command finished in an unfocused window" notification.
    public var onCommandFinished: ((_ duration: TimeInterval, _ exitCode: Int?) -> Void)?
    /// Clipboard text set by a program via OSC 52 (already base64-decoded). The
    /// consumer gates this on the `set-clipboard` option before writing the system
    /// pasteboard; the engine only decodes.
    public var onSetClipboard: ((String) -> Void)?
    /// Bytes the terminal must write back to the PTY (DSR cursor report, DA, etc.).
    public var onResponse: ((Data) -> Void)?

    // MARK: Terminal identity (XTVERSION / secondary DA)
    //
    // Capability-detecting tools probe for the terminal's identity. The host sets these from the
    // `terminal-identity` option (HarnessCore `TerminalIdentity`) — the engine is dependency-free,
    // so it carries plain values rather than reaching for the version constant. Mutated only on
    // the emulator's serial queue (host calls go through `emulatorState.sync`).

    /// Name reported in the XTVERSION reply (`DCS > | <name> <version> ST`).
    public var terminalName: String = "Harness"
    /// Version text reported in the XTVERSION reply.
    public var terminalVersion: String = ""
    /// Numeric firmware field of the secondary-DA reply (`CSI > 1 ; n ; 0 c`).
    public var secondaryDAVersion: Int = 0
    /// Title as last set by OSC 0/2 (the value XTWINOPS 22/23 push and pop).
    public private(set) var currentTitle = ""
    /// XTWINOPS title stack (`CSI 22 t` push / `CSI 23 t` pop). Depth-capped like xterm's;
    /// pushes beyond the cap are dropped (a runaway program can't grow it without bound).
    private var titleStack: [String] = []
    private static let titleStackLimit = 10
    /// DECSET 1048 state for DECRPM: xterm tracks save/restore-cursor as a mode bit (set on
    /// `h`, cleared on `l`) even though the observable effect is the save/restore action.
    private var mode1048Saved = false
    /// Resolves the terminal's current colors so the engine can answer OSC 10/11/12/4 *queries*
    /// (e.g. a TUI reading the background to pick a light/dark theme). The host supplies it from
    /// the resolved theme; nil roles get no reply.
    public var colorProvider: ((TerminalColorRole) -> (r: UInt8, g: UInt8, b: UInt8)?)?
    /// Desktop notification requested by a program (OSC 9 = `(nil, body)`; OSC 777 =
    /// `(title, body)`). The host routes it to the system notification path.
    public var onNotification: ((_ title: String?, _ body: String) -> Void)?
    /// ConEmu progress report (OSC 9;4) — `ESC ] 9 ; 4 ; <state> ; <value> ST`. Emitted by
    /// Claude Code 2.0+, amp, zig build, systemd, … while they work. Like Ghostty, any
    /// `9;4;…` payload is always a progress report, never a notification (the accepted
    /// iTerm2 OSC 9 collision). The host drives its working indicator from this.
    public var onProgress: ((TerminalProgressReport) -> Void)?
    /// Mouse pointer shape requested via OSC 22 (e.g. `text`, `pointer`, `default`); nil clears.
    public var onPointerShapeChange: ((String?) -> Void)?
    /// iTerm2 `OSC 1337 ; SetUserVar=name=<base64>` landed (already decoded + validated).
    /// The host surfaces these to format strings as pane-scoped `@name` user options.
    public var onUserVariableChange: ((_ name: String, _ value: String) -> Void)?
    /// RIS dropped every user variable — hosts that mirrored them (pane-scoped `@` options)
    /// must clear their copies too, or `#{@name}` keeps serving pre-reset values. Fired only
    /// when there was something to clear.
    public var onUserVariablesCleared: (() -> Void)?
    /// User variables set via OSC 1337 `SetUserVar=` (count- and size-capped; RIS clears).
    public private(set) var userVariables: [String: String] = [:]
    private static let maxUserVariables = 64
    /// Last OSC-22 pointer shape (nil = terminal default). Surfaced for hosts that prefer polling.
    public private(set) var pointerShape: String?
    /// When the current command started running (OSC 133 `C`/`B`), for command-duration timing.
    /// A MONOTONIC timestamp, not wall-clock `Date`: command duration is an elapsed interval, and a
    /// wall-clock step (NTP/DST/manual change) between C and D would make it negative (suppressing a
    /// long-command notification) or inflated (firing a spurious one).
    private var commandStartedAt: DispatchTime?

    /// Active character set per designation slot (`ESC ( …` / `ESC ) …`). DEC special graphics
    /// turns letters into line-drawing glyphs; ASCII is the default. `glUsesG1` is toggled by
    /// SO (invoke G1) / SI (invoke G0).
    private enum Charset { case ascii, decSpecialGraphics }
    private var g0: Charset = .ascii
    private var g1: Charset = .ascii
    private var glUsesG1 = false

    /// In-flight Kitty graphics chunk reassembly, keyed by image id. The first chunk carries the
    /// control keys (format/dims); later chunks append payload until `m=0`.
    private var kittyPending: [Int: (command: KittyGraphicsCommand, payload: [UInt8])] = [:]
    private let maxKittyPendingBytes = 32 << 20
    /// The per-image byte cap bounds one in-flight transfer, but image ids are free integers —
    /// a hostile stream can open many distinct ids that each send `m=1` and never finish. Cap the
    /// count of concurrently-reassembling images so the dictionary can't grow without bound.
    private let maxKittyPendingImages = 64
    /// Transmitted-but-not-yet-placed images, keyed by Kitty image id (`i=`). Populated by `a=t`
    /// (and `a=T`), consumed by `a=p` (place-many) — the transmit-once/place-many model image
    /// plugins use. Bounded by count + total bytes; oldest evicted on overflow.
    private var kittyTransmitted: [(id: Int, image: DecodedImage)] = []
    private let maxKittyTransmittedImages = 64
    private var kittyTransmittedBytes = 0

    public init(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        primary = TerminalScreen(cols: c, rows: r, recordsHistory: true)
        alternate = TerminalScreen(cols: c, rows: r)
        current = primary
        parser = VTParser(handler: self)
    }

    /// Scrollback lines available on the current screen (0 on the alternate screen).
    public var historyCount: Int { current.historyCount }

    /// Whether the alternate screen is active (full-screen TUIs like less/vim). The surface
    /// view uses this to synthesize arrow keys for the scroll wheel — the alternate screen
    /// has no scrollback to scroll.
    public var isAlternateScreenActive: Bool { onAlternateScreen }

    /// Cap on retained primary-screen scrollback. `0` means **unlimited** (history is never
    /// trimmed); any positive value caps the ring. Negative inputs clamp to `0` (unlimited).
    public var maxScrollbackLines: Int {
        get { primary.maxHistoryLines }
        set { primary.maxHistoryLines = max(0, newValue) }
    }

    /// Read the viewport scrolled `offset` lines up into scrollback (0 = live bottom).
    public func readGrid(scrollbackOffset offset: Int) -> TerminalGridSnapshot {
        current.snapshot(scrollbackOffset: offset)
    }

    // MARK: - Input

    public func feed(_ data: Data) { parser.feed(data) }
    public func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    public func feed(_ text: String) { parser.feed(Array(text.utf8)) }

    /// Reference seam: feed bytes one at a time through the per-byte scalar path, bypassing the
    /// printable-ASCII run fast path that `feed` uses. Public so the (non-`@testable`) benchmark
    /// target can A/B the run path against the scalar baseline; equivalence tests use it too. Not
    /// part of the normal input API — production code should always use `feed`.
    public func feedScalarwise(_ bytes: [UInt8]) { parser.feedScalarwise(bytes) }

    public func resize(cols: Int, rows: Int) {
        primary.resize(cols: cols, rows: rows)
        alternate.resize(cols: cols, rows: rows)
    }

    /// Test-only seam: resize routing the primary screen through the general reflow path even when
    /// the width is unchanged, so `ReflowFastPathTests` can A/B the width-unchanged fast path
    /// against the authoritative reflow. Not used in production (`resize` picks the fast path).
    func resizeForcingFullReflow(cols: Int, rows: Int) {
        primary.resize(cols: cols, rows: rows, forceFullReflow: true)
        alternate.resize(cols: cols, rows: rows, forceFullReflow: true)
    }

    /// Cheap, non-mutating preview of the primary-screen viewport after a hypothetical reflow to
    /// `cols × rows` — for live re-wrap during a resize drag while the authoritative history-wide
    /// reflow and PTY `SIGWINCH` are deferred to drag-end. O(visible content), not O(history).
    /// Byte-identical to `resize(...)`'s resulting viewport (proven by `ReflowPreviewTests`).
    /// Returns nil on the alternate screen (full-screen TUIs redraw on `SIGWINCH`; no live reflow).
    public func previewViewportReflow(cols: Int, rows: Int) -> TerminalGridSnapshot? {
        guard !onAlternateScreen else { return nil }
        let preview = primary.previewViewportReflow(toCols: cols, rows: rows)
        return TerminalGridSnapshot(
            cols: max(1, cols), rows: max(1, rows), cells: preview.cells,
            // Honor DECTCEM — a program that hid its cursor must not see it flash
            // back during the drag preview.
            cursor: TerminalCursor(row: preview.cursorRow, col: preview.cursorCol, visible: primary.cursorVisible)
        )
    }

    public func readGrid() -> TerminalGridSnapshot {
        current.snapshot()
    }

    /// Which viewport rows of the current screen changed since the last call, so a renderer can
    /// rebuild only those rows. Resets the accumulator: each change is reported exactly once.
    /// Reports `full` for screen-wide changes (clear/resize/reset/alternate-screen switch) and
    /// `cursorOnly` when the only change was the cursor moving. Always reflects the *live*
    /// viewport; callers showing scrollback should rebuild fully instead.
    public func consumeDamage() -> TerminalDamage {
        current.consumeDamage()
    }

    /// Total lines addressable by copy-mode / scrollback navigation on the current screen
    /// (retained history + the live viewport rows). 0 history on the alternate screen.
    public var bufferLineCount: Int { current.bufferLineCount }

    /// One line in copy-mode view space (`[history ++ viewport]`, 0 = oldest), padded to
    /// the current width. O(cols) random access — for copy-mode motion/search.
    public func bufferLine(_ index: Int) -> [TerminalGridCell] { current.bufferLine(index) }

    /// OSC 133 shell-prompt rows in copy-mode view space (`[history ++ viewport]`), oldest
    /// first — drives jump-to-previous/next-prompt. Empty without shell integration.
    public var promptRows: [Int] { current.promptRows() }

    /// The OSC 133 semantic mark on a copy-mode-space line, or nil.
    public func mark(atBufferLine index: Int) -> SemanticMark? { current.mark(atBufferLine: index) }

    /// The full buffer as plain-text lines for `capture-pane`. `joinWrapped` (tmux `-J`)
    /// joins soft-wrapped physical rows into their logical line.
    public func captureLines(joinWrapped: Bool) -> [String] { current.captureLines(joinWrapped: joinWrapped) }

    /// Virtual-line span `[first, last]` of the logical (soft-wrapped) line containing virtual
    /// `line` (space: `[history ++ viewport]`, 0 = oldest). Drives triple-click logical-line
    /// selection — a hard-ended line returns just itself.
    public func logicalLineRowSpan(virtualLine line: Int) -> ClosedRange<Int> {
        current.logicalLineSpan(containing: line)
    }

    // MARK: - VTParserHandler

    func parserPrint(_ scalar: UInt32) {
        // Translate through the DEC special-graphics table when that charset is invoked into GL,
        // so `lqqk`-style line drawing renders via the existing procedural box-drawing path.
        let active = glUsesG1 ? g1 : g0
        current.print(active == .decSpecialGraphics ? DECSpecialGraphics.map(scalar) : scalar)
    }

    /// Run-batched printable-ASCII path: route a contiguous ASCII run to the screen's batched
    /// `printASCIIRun` (build the cell template once, fill a row in a tight loop). Only valid when
    /// the active charset is ASCII — under DEC special graphics each byte needs the per-codepoint
    /// translation `parserPrint` does, so we fall back to scalar replay there. Byte-for-byte
    /// equivalent to repeated `parserPrint`, which is what `AsciiFastPathTests` proves.
    func parserPrintRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        let active = glUsesG1 ? g1 : g0
        if active == .decSpecialGraphics {
            for b in bytes { current.print(DECSpecialGraphics.map(UInt32(b))) }
        } else {
            current.printASCIIRun(bytes)
        }
    }

    /// Run-batched printable codepoint path (ASCII + decoded UTF-8): route the run to the screen's
    /// batched `printCodepointRun` (template once, width per scalar, row marked once). Under DEC
    /// special graphics each scalar needs the per-codepoint translation `parserPrint` applies, so
    /// fall back to scalar replay there — byte-for-byte equivalent to repeated `parserPrint`, which
    /// `CodepointRunFastPathTests` proves.
    func parserPrintCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        let active = glUsesG1 ? g1 : g0
        if active == .decSpecialGraphics {
            for cp in codepoints { current.print(DECSpecialGraphics.map(cp)) }
        } else {
            current.printCodepointRun(codepoints)
        }
    }

    func parserExecute(_ control: UInt8) {
        switch control {
        case 0x07: onBell?()                 // BEL
        case 0x08: current.backspace()       // BS
        case 0x09: current.tab()             // HT
        case 0x0A, 0x0B, 0x0C: current.lineFeed() // LF, VT, FF
        case 0x0D: current.carriageReturn()  // CR
        case 0x0E: glUsesG1 = true           // SO / LS1 — invoke G1 into GL
        case 0x0F: glUsesG1 = false          // SI / LS0 — invoke G0 into GL
        default: break
        }
    }

    func parserESC(final: UInt8, intermediates: [UInt8]) {
        // Charset designation: `ESC ( <f>` designates G0, `ESC ) <f>` designates G1. `f` = `0`
        // selects DEC special graphics (line drawing); anything else (incl. `B`) is ASCII.
        if intermediates == [0x28] || intermediates == [0x29] {
            let charset: Charset = (final == 0x30) ? .decSpecialGraphics : .ascii
            if intermediates == [0x28] { g0 = charset } else { g1 = charset }
            return
        }
        // DECALN — `ESC # 8` (intermediate '#'): screen alignment test, fill the screen with 'E'.
        if intermediates == [0x23], final == 0x38 {
            current.screenAlignmentTest()
            return
        }
        // Other intermediate sequences are accepted but not acted on.
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x48: current.setTabStop()      // HTS — set a tab stop at the cursor column
        case 0x44: current.lineFeed()        // IND — Index
        case 0x45: current.carriageReturn(); current.lineFeed() // NEL
        case 0x4D: current.reverseLineFeed() // RI — Reverse Index
        case 0x37: current.saveCursor()      // DECSC
        case 0x38: current.restoreCursor()   // DECRC
        case 0x63: fullReset()               // RIS
        case 0x3D: modes.keypadApplication = true   // DECKPAM
        case 0x3E: modes.keypadApplication = false  // DECKPNM
        default: break
        }
    }

    func parserCSI(final: UInt8, params: CSIParams, intermediates: [UInt8], isPrivate: Bool, privateMarker: UInt8?) {
        // Most control functions use one value per parameter (the first sub-parameter of each
        // group); the `arg`/`argRaw` helpers read those directly off the borrowed view. SGR is the
        // exception — it needs the full groups (for `4:3` underline styles and colon-form colors).
        if isPrivate {
            // Private modes (DECSET/DECRST, Kitty keyboard, XTMODKEYS) are rare and off the
            // throughput hot path; materialize a small flat array just for them so the existing
            // private-mode handlers stay unchanged.
            var flat = [Int]()
            flat.reserveCapacity(params.count)
            for g in 0 ..< params.count { flat.append(params.first(g)) }
            handlePrivateMode(final: final, intermediates: intermediates, params: flat, marker: privateMarker)
            return
        }
        // DECSCUSR — `CSI Ps SP q` (intermediate space) sets the cursor shape/blink.
        if intermediates == [0x20], final == 0x71 {
            current.setCursorStyle(argRaw(params, 0, 0))
            return
        }
        // DECSTR — `CSI ! p` (intermediate '!'): soft terminal reset.
        if intermediates == [0x21], final == 0x70 {
            softReset()
            return
        }
        // DECRQM, ANSI form — `CSI Ps $ p` (no private marker): report a non-private mode's
        // state. The private form (`CSI ? Ps $ p`) routes through `handlePrivateMode`.
        if intermediates == [0x24], final == 0x70 {
            for g in 0 ..< params.count { reportANSIMode(params.first(g)) }
            return
        }
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x41: current.moveCursorRelative(dRow: -arg(params, 0, 1), dCol: 0) // CUU
        case 0x42: current.moveCursorRelative(dRow: arg(params, 0, 1), dCol: 0)  // CUD
        case 0x43: current.moveCursorRelative(dRow: 0, dCol: arg(params, 0, 1))  // CUF
        case 0x44: current.moveCursorRelative(dRow: 0, dCol: -arg(params, 0, 1)) // CUB
        case 0x45: cursorNextLine(arg(params, 0, 1))   // CNL
        case 0x46: cursorPrevLine(arg(params, 0, 1))   // CPL
        case 0x47: current.moveCursorCol(arg(params, 0, 1) - 1) // CHA
        case 0x48, 0x66: // CUP / HVP (origin-mode aware)
            current.cursorPosition(row: arg(params, 0, 1) - 1, col: arg(params, 1, 1) - 1)
        case 0x4A: current.eraseInDisplay(mode: argRaw(params, 0, 0)) // ED
        case 0x4B: current.eraseInLine(mode: argRaw(params, 0, 0))    // EL
        case 0x4C: current.insertLines(arg(params, 0, 1))   // IL
        case 0x4D: current.deleteLines(arg(params, 0, 1))   // DL
        case 0x40: current.insertCharacters(arg(params, 0, 1)) // ICH
        case 0x50: current.deleteCharacters(arg(params, 0, 1)) // DCH
        case 0x58: current.eraseCharacters(arg(params, 0, 1))  // ECH
        case 0x53: current.scrollUp(arg(params, 0, 1))   // SU
        case 0x54: current.scrollDown(arg(params, 0, 1)) // SD
        case 0x64: current.cursorToRow(arg(params, 0, 1) - 1) // VPA (origin-mode aware)
        case 0x62: current.repeatLastGraphicChar(arg(params, 0, 1)) // REP — repeat last graphic char
        case 0x68: setANSIMode(params, true)  // SM — set mode (IRM…)
        case 0x6C: setANSIMode(params, false) // RM — reset mode
        case 0x6D: current.applySGR(params)            // SGR
        case 0x72: setScrollRegion(params)             // DECSTBM
        case 0x73: current.saveCursor()                // ANSI save cursor
        case 0x75: current.restoreCursor()             // ANSI restore cursor
        case 0x6E: deviceStatusReport(argRaw(params, 0, 0)) // DSR
        case 0x63: deviceAttributes()                  // DA
        case 0x67: // TBC — `CSI g` clear tab at cursor; `CSI 3 g` clear all
            argRaw(params, 0, 0) == 3 ? current.clearAllTabStops() : current.clearTabStop()
        case 0x49: current.cursorForwardTabs(arg(params, 0, 1))  // CHT — forward N tab stops
        case 0x5A: current.cursorBackwardTabs(arg(params, 0, 1)) // CBT — back N tab stops
        case 0x74: handleWindowOps(params)             // XTWINOPS (title stack + size reports)
        default: break
        }
    }

    func parserDCS(_ data: [UInt8]) {
        // tmux control-mode passthrough (`DCS tmux; … ST`). Recognized so it is never misread as
        // Sixel; driving the wrapped sequences is out of scope here (tracked separately).
        if data.starts(with: Self.tmuxPassthroughPrefix) { return }
        // Demux the DCS by its header — params (0x30–0x3F), then intermediates (0x20–0x2F), then a
        // final byte (0x40–0x7E), with the device-control data after the final, mirroring CSI. The
        // old `data.contains("q")` test sent every DCS that happened to contain a 'q' (DECRQSS `$q`,
        // XTGETTCAP `+q`, tmux passthrough) into the Sixel decoder, where it decoded as nothing.
        var i = 0
        let n = data.count
        while i < n, (0x30 ... 0x3F).contains(data[i]) { i += 1 } // parameter bytes
        var intermediate: UInt8?
        while i < n, (0x20 ... 0x2F).contains(data[i]) { intermediate = data[i]; i += 1 } // intermediates
        guard i < n else { return } // header with no final byte — malformed, ignore
        let final = data[i]
        let payload = Array(data[(i + 1)...])
        switch (intermediate, final) {
        case (nil, 0x71): // 'q' — Sixel image (no intermediate)
            if let image = SixelDecoder.decode(data) { placeImage(image, z: 0) }
        case (0x24, 0x71): // '$' 'q' — DECRQSS: request the value of a setting
            handleDECRQSS(payload)
        case (0x2B, 0x71): // '+' 'q' — XTGETTCAP: terminfo capability query
            handleXTGETTCAP(payload)
        default:
            break // unrecognized device-control string — ignore rather than misroute
        }
    }

    /// `DCS tmux;` — the tmux control-mode passthrough introducer.
    private static let tmuxPassthroughPrefix = Array("tmux;".utf8)

    /// DECRQSS (`DCS $ q Pt ST`) — report the current value of the setting named by `Pt` (the
    /// intermediate+final of the CSI that sets it). Reply `DCS 1 $ r <value> Pt ST` when we can
    /// answer, or the "invalid request" form `DCS 0 $ r Pt ST` otherwise. We answer for the
    /// settings the engine actually tracks: DECSCUSR (`SP q`) and DECSTBM (`r`).
    private func handleDECRQSS(_ request: [UInt8]) {
        let pt = String(decoding: request, as: UTF8.self)
        switch pt {
        case " q": // DECSCUSR — cursor style
            respond("\u{1b}P1$r\(current.cursorStylePs) q\u{1b}\\")
        case "r": // DECSTBM — scroll region (top;bottom, 1-based)
            let region = current.scrollRegionOneBased
            respond("\u{1b}P1$r\(region.top);\(region.bottom)r\u{1b}\\")
        default:
            respond("\u{1b}P0$r\(pt)\u{1b}\\") // request not recognized
        }
    }

    /// XTGETTCAP (`DCS + q Pt ST`) — answer terminfo/termcap capability queries for the handful of
    /// stable, statically-known capabilities (`TN` terminal name, `Co`/`colors` palette size, `RGB`
    /// truecolor). Names and values are hex-encoded per the protocol; unknown names get the negative
    /// `DCS 0 + r <name> ST` reply so a querier doesn't wait.
    private func handleXTGETTCAP(_ request: [UInt8]) {
        // The request is one or more `;`-separated hex-encoded capability names.
        for nameHex in request.split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let name = Self.decodeHex(Array(nameHex)) else { continue }
            let value: String?
            switch name {
            case "TN": value = terminalName            // terminal name
            case "Co", "colors": value = "256"          // palette size
            case "RGB": value = "8/8/8"                 // 24-bit truecolor (bits per channel)
            default: value = nil
            }
            if let value {
                respond("\u{1b}P1+r\(Self.encodeHex(name))=\(Self.encodeHex(value))\u{1b}\\")
            } else {
                respond("\u{1b}P0+r\(Self.encodeHex(name))\u{1b}\\")
            }
        }
    }

    /// Decode an ASCII hex string (`"5452"` → `"TN"`); nil on odd length or a non-hex digit.
    private static func decodeHex(_ bytes: [UInt8]) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 2)
        var idx = bytes.startIndex
        while idx < bytes.count {
            guard let hi = hexValue(bytes[idx]), let lo = hexValue(bytes[idx + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo))
            idx += 2
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30 ... 0x39: return Int(b - 0x30)
        case 0x41 ... 0x46: return Int(b - 0x41 + 10)
        case 0x61 ... 0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// Hex-encode a string for an XTGETTCAP reply (`"TN"` → `"544e"`).
    private static func encodeHex(_ s: String) -> String {
        s.utf8.map { String(format: "%02x", $0) }.joined()
    }

    func parserAPC(_ data: [UInt8]) {
        // Kitty graphics protocol (`G …`). Reassemble chunks, then decode + place.
        guard let command = KittyGraphicsCommand.parse(data) else { return }
        handleKittyGraphics(command)
    }

    // MARK: - Inline images

    /// Decoded pixels for a placed image (queried by the renderer on the main thread).
    public func image(for id: Int) -> DecodedImage? { current.image(for: id) }

    /// Set by the host so an image's cell footprint + cursor advance match the real cell size.
    public func setCellPixelSize(width: Int, height: Int) {
        for screen in [primary, alternate] {
            screen.cellPixelWidth = max(1, width)
            screen.cellPixelHeight = max(1, height)
        }
    }

    private func placeImage(_ image: DecodedImage, cols: Int = 0, rows: Int = 0, z: Int = 0, kittyID: Int? = nil) {
        current.placeImage(image, cols: cols, rows: rows, z: z, kittyID: kittyID)
    }

    /// Store a transmitted image for later `a=p` placement, bounded by count + total bytes.
    private func storeKittyTransmitted(id: Int, image: DecodedImage) {
        kittyTransmitted.removeAll { existing in
            if existing.id == id { kittyTransmittedBytes -= existing.image.byteCount; return true }
            return false
        }
        kittyTransmitted.append((id, image))
        kittyTransmittedBytes += image.byteCount
        while (kittyTransmitted.count > maxKittyTransmittedImages
               || kittyTransmittedBytes > ImageLimits.maxBytesPerScreen),
              !kittyTransmitted.isEmpty {
            kittyTransmittedBytes -= kittyTransmitted.removeFirst().image.byteCount
        }
    }

    private func kittyTransmitted(id: Int) -> DecodedImage? {
        kittyTransmitted.first { $0.id == id }?.image
    }

    /// Emit the Kitty graphics ack `APC G <i|I>=<id> ; <message> ST`. Per spec it's sent only when
    /// the client gave an addressable id (`i=`) or number (`I=`), and is suppressed by quietness:
    /// `q=1` silences the OK reply, `q=2` silences errors too.
    private func kittyAck(idKey: String, id: Int, ok: Bool, message: String, quietness: Int) {
        guard id != 0 else { return }
        if ok, quietness >= 1 { return }
        if !ok, quietness >= 2 { return }
        respond("\u{1b}_G\(idKey)=\(id);\(message)\u{1b}\\")
    }

    private func handleKittyGraphics(_ cmd: KittyGraphicsCommand) {
        let key = cmd.imageID
        if cmd.moreChunks {
            if var pending = kittyPending[key] {
                // Bound total reassembly memory, but KEEP the entry (with its first chunk's control
                // keys) so the final chunk still resolves the original dims/format. Append only up
                // to the cap and drop the overflow — nilling the entry here would make a later final
                // chunk decode as a fresh, dimensionless image and silently fail to place.
                let remaining = maxKittyPendingBytes - pending.payload.count
                if remaining > 0 {
                    pending.payload.append(contentsOf: cmd.payload.prefix(remaining))
                    kittyPending[key] = pending
                }
            } else {
                // New in-flight image: drop all pending reassembly if we're at the id cap, so a
                // flood of never-finished `m=1` chunks under distinct ids can't grow the map.
                if kittyPending.count >= maxKittyPendingImages { kittyPending.removeAll() }
                kittyPending[key] = (cmd, cmd.payload) // first chunk holds the control keys
            }
            return
        }
        // Final chunk: combine with any accumulated chunks (whose first command holds the control).
        let base: KittyGraphicsCommand
        var payload: [UInt8]
        if let pending = kittyPending.removeValue(forKey: key) {
            base = pending.command
            payload = pending.payload
            payload.append(contentsOf: cmd.payload)
        } else {
            base = cmd
            payload = cmd.payload
        }
        // Echo whichever handle the client used (`i=` preferred, else `I=`) back in the ack.
        let echoKey = base.imageID != 0 ? "i" : "I"
        let echoID = base.imageID != 0 ? base.imageID : base.imageNumber

        switch base.action {
        case "q":
            // Query (capability/decodability probe): validate without placing or storing. Answering
            // this is what gates detection in `icat`/`timg`/`chafa`, so it must reply.
            let ok = base.decode(base64Payload: payload) != nil
            kittyAck(idKey: echoKey, id: echoID, ok: ok,
                     message: ok ? "OK" : "EBADF:could not decode image", quietness: base.quietness)

        case "t", "T":
            // Transmit (`t`) stores for later place-many; transmit+display (`T`) also places now.
            guard let image = base.decode(base64Payload: payload) else {
                kittyAck(idKey: echoKey, id: echoID, ok: false,
                         message: "EBADF:could not decode image", quietness: base.quietness)
                return
            }
            if base.imageID != 0 { storeKittyTransmitted(id: base.imageID, image: image) }
            if base.action == "T" {
                placeImage(image, cols: base.cols, rows: base.rows, z: base.z,
                           kittyID: base.imageID != 0 ? base.imageID : nil)
            }
            kittyAck(idKey: echoKey, id: echoID, ok: true, message: "OK", quietness: base.quietness)

        case "p":
            // Put/place a previously-transmitted image by id (transmit-once / place-many).
            guard base.imageID != 0, let image = kittyTransmitted(id: base.imageID) else {
                kittyAck(idKey: echoKey, id: echoID, ok: false,
                         message: "ENOENT:image not found", quietness: base.quietness)
                return
            }
            placeImage(image, cols: base.cols, rows: base.rows, z: base.z, kittyID: base.imageID)
            kittyAck(idKey: echoKey, id: echoID, ok: true, message: "OK", quietness: base.quietness)

        case "d":
            // Delete placements: `d=i`/`d=I` by image id, otherwise (`d=a`/`d=A`/default) all.
            switch base.deleteTarget {
            case "i", "I":
                if base.imageID != 0 {
                    current.deleteImages(kittyID: base.imageID)
                    kittyTransmitted.removeAll { e in
                        e.id == base.imageID ? { kittyTransmittedBytes -= e.image.byteCount; return true }() : false
                    }
                }
            default:
                current.deleteImages(kittyID: nil)
                kittyTransmitted.removeAll(); kittyTransmittedBytes = 0
            }
            kittyAck(idKey: echoKey, id: echoID, ok: true, message: "OK", quietness: base.quietness)

        default:
            break // `a=a` (animation) and any unknown action are deliberately ignored (deferred).
        }
    }

    /// iTerm2 inline image (`OSC 1337 ; File=…:<base64>`). width/height args may be cells (`N`),
    /// pixels (`Npx`), or percent (`N%`); only plain cell counts are honored here — pixel/percent
    /// fall back to the footprint computed from the image's pixels.
    /// The OSC 1337 family beyond inline images (F20): `CurrentDir=` reports the cwd with
    /// the same trust policy as OSC 7 (absolute paths only — hostile output must not steer
    /// the inherited cwd), and `SetUserVar=name=<base64>` stores a per-surface user variable
    /// (surfaced to format strings by the host as a pane-scoped `@name` option). Anything
    /// else falls through to the image handler, which ignores what it can't parse.
    private func handleITerm2OSC(_ payload: String) {
        if payload.hasPrefix("CurrentDir=") {
            let path = String(payload.dropFirst("CurrentDir=".count))
            guard path.hasPrefix("/") else { return }
            onWorkingDirectoryChange?(path)
            return
        }
        if payload.hasPrefix("SetUserVar=") {
            let body = String(payload.dropFirst("SetUserVar=".count))
            guard let eq = body.firstIndex(of: "=") else { return }
            let name = String(body[..<eq])
            let encoded = String(body[body.index(after: eq)...])
            // Bound everything a hostile stream controls: name shape + length (ASCII only —
            // Unicode `isLetter`/`isNumber` would admit lookalikes like `½`), the base64 TEXT
            // before decoding (4096 bytes ≈ 5464 base64 chars with padding, so a multi-MiB
            // payload is never decoded), decoded value size + content (no C0/DEL/C1 — values
            // are later format-expanded into status lines and other clients' TTYs, where a
            // control byte is escape injection), and the variable-table population (new names
            // rejected past the cap; existing names stay updatable).
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  encoded.utf8.count <= 5464,
                  let data = Data(base64Encoded: encoded), data.count <= 4096,
                  let value = String(data: data, encoding: .utf8),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0x80 ... 0x9F).contains($0.value) })
            else { return }
            if userVariables[name] == value { return } // same-value rewrite: no host round trip
            if userVariables[name] == nil, userVariables.count >= Self.maxUserVariables { return }
            userVariables[name] = value
            onUserVariableChange?(name, value)
            return
        }
        handleITerm2Image(payload)
    }

    private func handleITerm2Image(_ payload: String) {
        guard let parsed = ITerm2InlineImage.parse(Array(payload.utf8)) else { return }
        func cells(_ s: String?) -> Int {
            guard let s, !s.hasSuffix("px"), !s.hasSuffix("%"), let n = Int(s) else { return 0 }
            return n
        }
        placeImage(parsed.image, cols: cells(parsed.widthArg), rows: cells(parsed.heightArg), z: 0)
    }

    func parserOSC(_ data: [UInt8]) {
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        guard let semi = text.firstIndex(of: ";") else { return }
        let code = String(text[text.startIndex ..< semi])
        let payload = String(text[text.index(after: semi)...])
        switch code {
        case "0", "2": // icon+title / title (tracked so XTWINOPS 22/23 can push/pop it)
            currentTitle = payload
            onTitleChange?(payload)
        case "7": handleWorkingDirectoryOSC(payload)       // cwd as file:// URL
        case "8": handleHyperlinkOSC(payload)              // OSC 8 hyperlinks
        case "10": handleColorQuery(code: "10", role: .foreground, payload: payload)
        case "11": handleColorQuery(code: "11", role: .background, payload: payload)
        case "12": handleColorQuery(code: "12", role: .cursor, payload: payload)
        case "4": handlePaletteColorQuery(payload)         // OSC 4 ; index ; ?
        case "52": handleClipboardOSC(payload)             // clipboard set (OSC 52)
        case "9": handleOSC9(payload)                      // notification, or ConEmu progress (9;4)
        case "777": handleNotify777(payload)               // OSC 777 ; notify ; <title> ; <body>
        case "22": setPointerShape(payload)                // OSC 22 ; <shape> — mouse cursor shape
        case "133": handleSemanticPrompt(payload)          // OSC 133 ; A/B/C/D — shell integration
        case "1337": handleITerm2OSC(payload)              // iTerm2 family (File=/CurrentDir=/SetUserVar=)
        default: break
        }
    }

    /// OSC 9 carries two protocols: `9;4;<state>[;<value>]` is a ConEmu progress report;
    /// anything else is an iTerm2-style desktop notification with the payload as body.
    /// Ghostty parity: `9;4` always wins the collision (a notification can't start with "4;").
    private func handleOSC9(_ payload: String) {
        guard payload == "4" || payload.hasPrefix("4;") else {
            onNotification?(nil, payload)
            return
        }
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        // parts[0] == "4"; parts[1] = state; parts[2] = optional 0–100 value.
        guard parts.count >= 2, let raw = Int(parts[1]),
              let state = TerminalProgressReport.State(rawValue: raw)
        else { return } // unknown state: ignore (don't fall back to a notification)
        let value = parts.count >= 3 ? Int(parts[2]).map { max(0, min(100, $0)) } : nil
        onProgress?(TerminalProgressReport(state: state, value: value))
    }

    /// OSC 133 shell integration. `A` marks a prompt line, `D[;exit]`
    /// reports the finished command's status; `B` (command start) and `C` (output start) are the
    /// input/output delimiters — parsed but not stamped, since the prompt mark + exit status are
    /// what drive jump-to-prompt and the success/failure gutter. Purely informational: nothing is
    /// written back to the PTY, and a program that doesn't emit 133 is unaffected.
    private func handleSemanticPrompt(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first?.first else { return }
        switch kind {
        case "A":
            current.markPromptStart()
            commandStartedAt = nil // new prompt: no command running yet
        case "B", "C":
            // Command execution begins. C (output/exec start) deliberately overwrites B
            // (prompt-end/input start): duration must measure execution (C→D), not the time
            // the user spent typing at the prompt. B alone still covers integrations that
            // never emit C.
            commandStartedAt = .now()
        case "D":
            let exitCode = parts.count >= 2 ? Int(parts[1]) : nil
            current.markCommandFinished(exit: exitCode)
            if let started = commandStartedAt {
                // Monotonic elapsed seconds — never negative or clock-skewed.
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
                onCommandFinished?(Double(elapsedNanos) / 1_000_000_000, exitCode)
                commandStartedAt = nil
            }
        default: break
        }
    }

    /// OSC 777 `notify;<title>;<body>`. Other 777 sub-commands are ignored.
    private func handleNotify777(_ payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "notify", parts.count >= 2 else { return }
        let title = parts.count >= 3 ? parts[1] : nil
        let body = parts.count >= 3 ? parts[2] : parts[1]
        onNotification?(title, body)
    }

    private func setPointerShape(_ shape: String) {
        let value = shape.isEmpty ? nil : shape
        guard value != pointerShape else { return }
        pointerShape = value
        onPointerShapeChange?(value)
    }

    /// OSC 10/11/12 `?`: report the current fg/bg/cursor color (8→16-bit, `rgb:RRRR/GGGG/BBBB`).
    /// A non-`?` payload is a *set*, which Harness ignores — the theme owns the canvas colors.
    private func handleColorQuery(code: String, role: TerminalColorRole, payload: String) {
        guard payload.hasPrefix("?"), let rgb = colorProvider?(role) else { return }
        respond("\u{1b}]\(code);\(Self.xtermColor(rgb))\u{1b}\\")
    }

    /// OSC 4 `index ; ?`: report a palette color. A spec instead of `?` is a set (ignored).
    private func handlePaletteColorQuery(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let index = Int(parts[0]), parts[1].hasPrefix("?"),
              let rgb = colorProvider?(.palette(index)) else { return }
        respond("\u{1b}]4;\(index);\(Self.xtermColor(rgb))\u{1b}\\")
    }

    /// xterm color reply form: each 8-bit channel widened to 16-bit (`v * 0x101`).
    private static func xtermColor(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> String {
        func h(_ v: UInt8) -> String { String(format: "%04x", UInt16(v) &* 0x101) }
        return "rgb:\(h(c.r))/\(h(c.g))/\(h(c.b))"
    }

    // OSC 8 hyperlink registry: cell `hyperlinkID` → URL. Global across both screens.
    private var hyperlinks: [UInt32: String] = [:]
    private var hyperlinkKeys: [String: UInt32] = [:]
    private var nextHyperlinkID: UInt32 = 1

    /// Resolve a cell's `hyperlinkID` to its URL (nil for 0 / unknown).
    public func hyperlinkURL(id: UInt32) -> String? { id == 0 ? nil : hyperlinks[id] }

    /// OSC 8: `params ; URI` — open a hyperlink over subsequently-printed cells; an empty URI
    /// (`OSC 8 ; ; ST`) ends it. An `id=<name>` param lets split runs of the same link share an
    /// id (so a wrapped URL highlights as one).
    private func handleHyperlinkOSC(_ payload: String) {
        guard let semi = payload.firstIndex(of: ";") else { return }
        let params = payload[payload.startIndex ..< semi]
        let uri = String(payload[payload.index(after: semi)...])
        guard !uri.isEmpty else { current.setHyperlink(0); return }
        let explicitID = params.split(separator: ":").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }
        let key = explicitID.map { "id=\($0)\u{1}\(uri)" } ?? "uri=\(uri)"
        let id: UInt32
        if let existing = hyperlinkKeys[key] {
            id = existing
        } else {
            // Bound the registry against hostile floods of unique links.
            if hyperlinks.count >= 16_384 { hyperlinks.removeAll(); hyperlinkKeys.removeAll(); nextHyperlinkID = 1 }
            id = nextHyperlinkID
            nextHyperlinkID &+= 1
            hyperlinks[id] = uri
            hyperlinkKeys[key] = id
        }
        current.setHyperlink(id)
    }

    /// OSC 52: `Pc ; Pd` where `Pd` is base64 text to copy (or `?` to query). We
    /// support *setting* the clipboard; a query is ignored (the engine never blocks
    /// on a pasteboard read). The consumer honors the `set-clipboard` option.
    private func handleClipboardOSC(_ payload: String) {
        guard let semi = payload.firstIndex(of: ";") else { return }
        let encoded = String(payload[payload.index(after: semi)...])
        guard encoded != "?", !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8)
        else { return }
        onSetClipboard?(text)
    }

    // MARK: - Helpers

    /// Parameter at `index` (first sub-parameter of group `index`), treating absent/zero as
    /// `defaultValue` (for 1-based counts).
    private func arg(_ params: CSIParams, _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        let v = params.first(index)
        return v == 0 ? defaultValue : v
    }

    /// Parameter at `index` with a literal default (for modes where 0 is meaningful).
    private func argRaw(_ params: CSIParams, _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        return params.first(index)
    }

    // CNL/CPL are cursor moves, not scrolls: ECMA-48 / xterm clamp them to the page exactly
    // like CUD/CUU (which `moveCursorRelative` already does), so they never scroll the region.
    // The old loop-of-lineFeed form both diverged from that and let `\e[65535E` spin 65k scrolls.
    private func cursorNextLine(_ n: Int) {
        current.moveCursorRelative(dRow: max(1, n), dCol: 0)
        current.carriageReturn()
    }

    private func cursorPrevLine(_ n: Int) {
        current.moveCursorRelative(dRow: -max(1, n), dCol: 0)
        current.carriageReturn()
    }

    private func setScrollRegion(_ params: CSIParams) {
        let top = arg(params, 0, 1) - 1
        // Use the bounds-safe accessor for both branches (no direct indexing).
        let rawBottom = argRaw(params, 1, 0)
        let bottom = rawBottom == 0 ? rows - 1 : rawBottom - 1
        current.setScrollRegion(top: top, bottom: bottom)
    }

    /// ANSI SM/RM (`CSI Ps h` / `CSI Ps l`, no private marker). Only IRM (mode 4) is meaningful;
    /// other ANSI modes (e.g. LNM 20) are not implemented and are ignored.
    private func setANSIMode(_ params: CSIParams, _ set: Bool) {
        for g in 0 ..< params.count where params.first(g) == 4 {
            current.insertMode = set // IRM — insert/replace mode
        }
    }

    /// DECSTR (`CSI ! p`) soft terminal reset: return the active screen's state (cursor visibility,
    /// insert/replace, origin, scroll region, saved cursor, SGR) plus the host-facing keyboard modes
    /// and charset designations to defaults, without clearing the screen or moving the cursor.
    private func softReset() {
        current.softReset()
        modes.cursorKeysApplication = false
        modes.keypadApplication = false
        // The screen's softReset() discards savedCursor — DECRQM ?1048 must not keep
        // reporting "set" for a save that no longer exists.
        mode1048Saved = false
        g0 = .ascii
        g1 = .ascii
        glUsesG1 = false
    }

    private func handlePrivateMode(final: UInt8, intermediates: [UInt8], params: [Int], marker: UInt8?) {
        // Kitty keyboard protocol — `CSI u` with a private introducer (push/pop/set/query).
        if final == 0x75, intermediates.isEmpty {
            handleKittyKeyboard(marker: marker, params: params)
            return
        }
        // modifyOtherKeys (XTMODKEYS) — `CSI > 4 ; n m`.
        if final == 0x6D, marker == 0x3E, params.first == 4 {
            modes.modifyOtherKeys = params.count > 1 ? params[1] : 0
            return
        }
        // XTVERSION — `CSI > q`: reply `DCS > | <name> <version> ST`. Capability-detecting tools
        // (Claude Code) read this to confirm which terminal they're in. Must live here: the
        // private `>` marker means a `q`/`c` final never reaches the main `switch final` (the
        // `isPrivate` early-return in `parserCSI` routes it straight to us).
        if final == 0x71, marker == 0x3E, intermediates.isEmpty {
            // No trailing space when the version is empty — strict DCS parsers choke on it.
            let versionPart = terminalVersion.isEmpty ? "" : " \(terminalVersion)"
            respond("\u{1b}P>|\(terminalName)\(versionPart)\u{1b}\\")
            return
        }
        // Secondary DA — `CSI > c`: reply `CSI > 1 ; <version> ; 0 c` (VT220-class, firmware n).
        if final == 0x63, marker == 0x3E, intermediates.isEmpty {
            respond("\u{1b}[>1;\(secondaryDAVersion);0c")
            return
        }
        // Tertiary DA — `CSI = c`: reply DECRPTUI (`DCS ! | <8-hex-digit unit id> ST`). The
        // all-zero site/serial is what xterm reports; tools only check that a reply arrives.
        if final == 0x63, marker == 0x3D, intermediates.isEmpty {
            respond("\u{1b}P!|00000000\u{1b}\\")
            return
        }
        // DECRQM: `CSI ? Ps $ p` — report a private mode's current state.
        if final == 0x70, intermediates == [0x24] { // '$' then 'p'
            for p in params { reportPrivateMode(p) }
            return
        }
        let set = (final == 0x68) // 'h' set, 'l' reset
        guard final == 0x68 || final == 0x6C else { return }
        for p in params {
            switch p {
            case 5: // DECSCNM reverse video — whole-screen fg/bg swap (resolved at render)
                if modes.reverseVideo != set {
                    modes.reverseVideo = set
                    current.markFullyDirty()
                }
            case 6: current.setOriginMode(set)             // DECOM origin mode
            case 7: current.autowrap = set                 // DECAWM autowrap
            case 12: current.setCursorBlink(set)           // att610 cursor blink
            case 25: current.cursorVisible = set           // DECTCEM cursor visibility
            case 1000: modes.mouseClick = set              // X10/normal mouse
            case 1002: modes.mouseDrag = set               // button-event tracking
            case 1003: modes.mouseAny = set                // any-event tracking
            case 1006: modes.mouseSGR = set                // SGR extended coordinates
            case 1016: modes.mouseSGRPixel = set           // SGR-pixel extended coordinates
            case 1004: modes.focusReporting = set          // focus in/out reporting
            case 1007: modes.alternateScroll = set         // wheel → arrows on alt screen
            case 2004: modes.bracketedPaste = set          // bracketed paste
            case 2026: modes.synchronizedOutput = set      // synchronized output (no tearing)
            case 1: modes.cursorKeysApplication = set      // DECCKM
            case 47, 1047: switchAlternate(set, clearOnEnter: true, saveCursor: false)
            case 1048: // save (h) / restore (l) cursor without the screen switch
                mode1048Saved = set
                set ? current.saveCursor() : current.restoreCursor()
            case 1049: switchAlternate(set, clearOnEnter: true, saveCursor: true)
            default: break
            }
        }
    }

    /// DECRPM reply `CSI ? Ps ; Pm $ y` — Pm: 0 not recognized, 1 set, 2 reset. Lets a program
    /// detect support (e.g. `?2026$p` for synchronized output) before using it.
    private func reportPrivateMode(_ p: Int) {
        let state: Int
        switch p {
        case 5: state = modes.reverseVideo ? 1 : 2
        case 6: state = current.originMode ? 1 : 2
        case 7: state = current.autowrap ? 1 : 2
        case 12: state = current.cursorBlinking == true ? 1 : 2 // nil = user default → "reset"
        case 25: state = current.cursorVisible ? 1 : 2
        case 1000: state = modes.mouseClick ? 1 : 2
        case 1002: state = modes.mouseDrag ? 1 : 2
        case 1003: state = modes.mouseAny ? 1 : 2
        case 1006: state = modes.mouseSGR ? 1 : 2
        case 1016: state = modes.mouseSGRPixel ? 1 : 2
        case 1004: state = modes.focusReporting ? 1 : 2
        case 1007: state = modes.alternateScroll ? 1 : 2
        case 2004: state = modes.bracketedPaste ? 1 : 2
        case 2026: state = modes.synchronizedOutput ? 1 : 2
        case 1: state = modes.cursorKeysApplication ? 1 : 2
        case 47, 1047, 1049: state = onAlternateScreen ? 1 : 2
        case 1048: state = mode1048Saved ? 1 : 2 // xterm tracks save/restore as a mode bit
        default: state = 0 // not recognized
        }
        respond("\u{1b}[?\(p);\(state)$y")
    }

    /// DECRPM reply for the ANSI (non-private) DECRQM form: `CSI Ps ; Pm $ y`. Only IRM
    /// (mode 4) is implemented; every other ANSI mode reports 0 (not recognized) — the
    /// conformance-correct answer, letting programs feature-detect instead of assuming.
    private func reportANSIMode(_ p: Int) {
        let state: Int
        switch p {
        case 4: state = current.insertMode ? 1 : 2
        default: state = 0 // not recognized
        }
        respond("\u{1b}[\(p);\(state)$y")
    }

    /// XTWINOPS (`CSI Ps ; … t`). Implemented: the title stack (22 push / 23 pop) and the
    /// size *reports* (18 chars / 14 pixels). Resize/move/iconify remain deliberate
    /// non-goals — the window belongs to the user — and unknown Ps are ignored.
    private func handleWindowOps(_ params: CSIParams) {
        switch argRaw(params, 0, 0) {
        case 14: // text area size in pixels → CSI 4 ; height ; width t
            // Derived from the cell pixel size the host already supplies for inline images
            // (`setCellPixelSize`, kept current on every font/scale change) — one source of
            // truth, and the same space SGR-pixel (1016) mouse coordinates use. A headless
            // consumer reports the screen's synthetic 8×16 default rather than silence, so
            // a querying program never hangs.
            respond("\u{1b}[4;\(rows * current.cellPixelHeight);\(cols * current.cellPixelWidth)t")
        case 18: // text area size in characters → CSI 8 ; rows ; cols t
            respond("\u{1b}[8;\(rows);\(cols)t")
        case 22: // push title (Ps2 0/1/2 — icon and window title are one value here)
            if titleStack.count < Self.titleStackLimit { titleStack.append(currentTitle) }
        case 23: // pop title — restores (and re-announces) the saved title
            if let restored = titleStack.popLast() {
                currentTitle = restored
                onTitleChange?(restored)
            }
        default: break
        }
    }

    /// Kitty keyboard protocol control, dispatched by the private introducer:
    /// `>` push flags, `<` pop N levels, `=` set flags with a mode, `?` query current flags.
    private func handleKittyKeyboard(marker: UInt8?, params: [Int]) {
        switch marker {
        case 0x3E: // '>' — push flags
            let flags = UInt8(truncatingIfNeeded: params.first ?? 0)
            if modes.kittyKeyboardStack.count < 32 { modes.kittyKeyboardStack.append(flags) }
        case 0x3C: // '<' — pop N levels (default 1)
            let n = max(1, params.first ?? 1)
            modes.kittyKeyboardStack.removeLast(min(n, modes.kittyKeyboardStack.count))
        case 0x3D: // '=' — set flags on the active level; mode 1 replace, 2 set bits, 3 clear bits
            let flags = UInt8(truncatingIfNeeded: params.first ?? 0)
            let mode = params.count > 1 ? params[1] : 1
            let current = modes.kittyKeyboardStack.last ?? 0
            let next: UInt8
            switch mode {
            case 2: next = current | flags
            case 3: next = current & ~flags
            default: next = flags
            }
            if modes.kittyKeyboardStack.isEmpty { modes.kittyKeyboardStack.append(next) }
            else { modes.kittyKeyboardStack[modes.kittyKeyboardStack.count - 1] = next }
        case 0x3F: // '?' — query: reply with the current flags
            respond("\u{1b}[?\(modes.kittyKeyboardFlags)u")
        default:
            break
        }
    }

    private func switchAlternate(_ enable: Bool, clearOnEnter: Bool, saveCursor: Bool) {
        if enable {
            guard !onAlternateScreen else { return }
            if saveCursor { primary.saveCursor() }
            onAlternateScreen = true
            current = alternate
            if clearOnEnter { alternate.clearAll() }
        } else {
            guard onAlternateScreen else { return }
            onAlternateScreen = false
            current = primary
            if saveCursor { primary.restoreCursor() }
        }
        // The visible buffer changed wholesale — the next consumer must repaint everything.
        current.markFullyDirty()
    }

    private func deviceStatusReport(_ code: Int) {
        switch code {
        case 5: respond("\u{1b}[0n")                       // "terminal OK"
        case 6: // cursor position report (1-based)
            let snap = current.snapshot()
            respond("\u{1b}[\(snap.cursor.row + 1);\(snap.cursor.col + 1)R")
        default: break
        }
    }

    private func deviceAttributes() {
        // Identify as a VT220-class terminal (62) with Sixel graphics (4) and ANSI color (22) —
        // the same class Ghostty/xterm report. `parserDCS` decodes Sixel, so tools that gate on
        // the DA1 feature list (img2sixel, chafa, timg) will actually emit it; the 62 class is
        // what makes capability-probing TUIs try VT220-level sequences we do implement (DECRQM,
        // DA3, the title stack) instead of degrading to VT100.
        respond("\u{1b}[?62;4;22c")
    }

    private func respond(_ s: String) {
        onResponse?(Data(s.utf8))
    }

    private func handleWorkingDirectoryOSC(_ payload: String) {
        // OSC 7 reports the shell's cwd as a file URL: `file://<host>/<absolute-path>`. Accept only
        // a `file://` URL that resolves to an absolute path; ignore a relative path, a non-`file`
        // scheme, or junk, so hostile output can't steer the cwd inherited by new tabs to an
        // attacker-chosen value. No existence check — the path may live on a remote host (cwd
        // reported over ssh), and the engine is filesystem-agnostic by design.
        let path: String
        if let url = URL(string: payload), url.isFileURL {
            path = url.path
        } else if payload.hasPrefix("file://") {
            // Fallback: strip scheme + authority manually (URL() rejects some unencoded paths).
            let withoutScheme = String(payload.dropFirst("file://".count))
            guard let slash = withoutScheme.firstIndex(of: "/") else { return }
            path = String(withoutScheme[slash...])
        } else {
            return
        }
        guard path.hasPrefix("/") else { return }
        onWorkingDirectoryChange?(path)
    }

    private func fullReset() {
        primary.fullReset()
        alternate.fullReset()
        if onAlternateScreen {
            onAlternateScreen = false
            current = primary
        }
        modes = TerminalModes()
        g0 = .ascii
        g1 = .ascii
        glUsesG1 = false
        // RIS empties the XTWINOPS title stack (xterm behavior); the title itself persists.
        titleStack.removeAll()
        mode1048Saved = false
        kittyPending.removeAll()
        // RIS returns the terminal to its initial state, so the transmitted-image cache
        // (transmit-once / place-many storage) must reset too — same cleanup as `d=a`
        // delete-all — otherwise images survive a full reset and keep occupying the
        // per-screen byte budget.
        kittyTransmitted.removeAll()
        kittyTransmittedBytes = 0
        pointerShape = nil
        if !userVariables.isEmpty {
            userVariables.removeAll()
            onUserVariablesCleared?()
        }
        hyperlinks.removeAll()
        hyperlinkKeys.removeAll()
        nextHyperlinkID = 1
        // A full reset abandons any in-flight command timing — otherwise a 133;D after
        // ESC c reports a spurious command-finished with a pre-reset start time.
        commandStartedAt = nil
        parser.reset()
    }
}

/// Terminal mode flags that govern how the host encodes keyboard/mouse input. Read by
/// the NSView host's input encoder (Phase 6); set here by DECSET/DECRST.
public struct TerminalModes: Sendable, Equatable {
    public var cursorKeysApplication = false
    public var keypadApplication = false
    public var bracketedPaste = false
    public var focusReporting = false
    /// DECSET 1007 "alternate scroll": wheel events on the alternate screen become arrow
    /// keys. On by default (the iTerm2/Ghostty convention) so less/man/vim scroll out of
    /// the box; programs can opt out with `CSI ? 1007 l`.
    public var alternateScroll = true
    public var mouseClick = false
    public var mouseDrag = false
    public var mouseAny = false
    public var mouseSGR = false
    /// DECSET 1016: SGR-pixel mouse reporting — same `CSI < … M/m` framing as 1006 but with
    /// pixel coordinates. Takes precedence over 1006 when both are set (xterm semantics).
    public var mouseSGRPixel = false
    /// DECSET 5 (DECSCNM): whole-screen reverse video. Resolved at render time (the renderer
    /// swaps default fg/bg), so the engine only tracks the flag and dirties the screen.
    public var reverseVideo = false
    /// DEC private mode 2026 (synchronized output): while set, the program is mid-frame and the
    /// renderer should hold the last presented frame rather than paint partial updates — no
    /// tearing in TUIs (vim, fzf, btop, …). Cleared by the program (or a renderer-side timeout).
    public var synchronizedOutput = false
    /// Kitty keyboard progressive-enhancement flag stack (`CSI > flags u` push / `CSI < u` pop).
    /// Top of stack = active flags; empty = disabled (flags 0). Bits: 1 disambiguate-escape-codes,
    /// 2 report-event-types, 4 report-alternate-keys, 8 report-all-keys-as-escape-codes,
    /// 16 report-associated-text. The input encoder uses CSI-u encoding only when non-zero, so
    /// legacy output is byte-identical until a program opts in.
    public var kittyKeyboardStack: [UInt8] = []
    /// Active Kitty keyboard flags (top of stack, or 0 when none pushed).
    public var kittyKeyboardFlags: UInt8 { kittyKeyboardStack.last ?? 0 }
    /// xterm modifyOtherKeys level (`CSI > 4 ; n m`): 0 off, 1, or 2. Independent of Kitty.
    public var modifyOtherKeys: Int = 0

    public init() {}

    /// Any mouse-tracking mode is active.
    public var mouseTrackingEnabled: Bool { mouseClick || mouseDrag || mouseAny }
}
