import Foundation

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
    /// Clipboard text set by a program via OSC 52 (already base64-decoded). The
    /// consumer gates this on the `set-clipboard` option before writing the system
    /// pasteboard; the engine only decodes.
    public var onSetClipboard: ((String) -> Void)?
    /// Bytes the terminal must write back to the PTY (DSR cursor report, DA, etc.).
    public var onResponse: ((Data) -> Void)?
    /// Resolves the terminal's current colors so the engine can answer OSC 10/11/12/4 *queries*
    /// (e.g. a TUI reading the background to pick a light/dark theme). The host supplies it from
    /// the resolved theme; nil roles get no reply.
    public var colorProvider: ((TerminalColorRole) -> (r: UInt8, g: UInt8, b: UInt8)?)?
    /// Desktop notification requested by a program (OSC 9 = `(nil, body)`; OSC 777 =
    /// `(title, body)`). The host routes it to the system notification path.
    public var onNotification: ((_ title: String?, _ body: String) -> Void)?
    /// Mouse pointer shape requested via OSC 22 (e.g. `text`, `pointer`, `default`); nil clears.
    public var onPointerShapeChange: ((String?) -> Void)?
    /// Last OSC-22 pointer shape (nil = terminal default). Surfaced for hosts that prefer polling.
    public private(set) var pointerShape: String?

    /// Active character set per designation slot (`ESC ( …` / `ESC ) …`). DEC special graphics
    /// turns letters into line-drawing glyphs; ASCII is the default. `glUsesG1` is toggled by
    /// SO (invoke G1) / SI (invoke G0).
    private enum Charset { case ascii, decSpecialGraphics }
    private var g0: Charset = .ascii
    private var g1: Charset = .ascii
    private var glUsesG1 = false

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

    /// Cap on retained primary-screen scrollback.
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

    public func resize(cols: Int, rows: Int) {
        primary.resize(cols: cols, rows: rows)
        alternate.resize(cols: cols, rows: rows)
    }

    public func readGrid() -> TerminalGridSnapshot {
        current.snapshot()
    }

    /// Total lines addressable by copy-mode / scrollback navigation on the current screen
    /// (retained history + the live viewport rows). 0 history on the alternate screen.
    public var bufferLineCount: Int { current.bufferLineCount }

    /// One line in copy-mode view space (`[history ++ viewport]`, 0 = oldest), padded to
    /// the current width. O(cols) random access — for copy-mode motion/search.
    public func bufferLine(_ index: Int) -> [TerminalGridCell] { current.bufferLine(index) }

    /// The full buffer as plain-text lines for `capture-pane`. `joinWrapped` (tmux `-J`)
    /// joins soft-wrapped physical rows into their logical line.
    public func captureLines(joinWrapped: Bool) -> [String] { current.captureLines(joinWrapped: joinWrapped) }

    // MARK: - VTParserHandler

    func parserPrint(_ scalar: UInt32) {
        // Translate through the DEC special-graphics table when that charset is invoked into GL,
        // so `lqqk`-style line drawing renders via the existing procedural box-drawing path.
        let active = glUsesG1 ? g1 : g0
        current.print(active == .decSpecialGraphics ? DECSpecialGraphics.map(scalar) : scalar)
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

    func parserCSI(final: UInt8, params: [[Int]], intermediates: [UInt8], isPrivate: Bool, privateMarker: UInt8?) {
        // Most control functions use one value per parameter; flatten by taking each
        // group's first sub-parameter. SGR is the exception — it needs the full groups
        // (for `4:3` underline styles and colon-form colors).
        let flat = params.map { $0.first ?? 0 }
        if isPrivate {
            handlePrivateMode(final: final, intermediates: intermediates, params: flat, marker: privateMarker)
            return
        }
        // DECSCUSR — `CSI Ps SP q` (intermediate space) sets the cursor shape/blink.
        if intermediates == [0x20], final == 0x71 {
            current.setCursorStyle(argRaw(flat, 0, 0))
            return
        }
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x41: current.moveCursorRelative(dRow: -arg(flat, 0, 1), dCol: 0) // CUU
        case 0x42: current.moveCursorRelative(dRow: arg(flat, 0, 1), dCol: 0)  // CUD
        case 0x43: current.moveCursorRelative(dRow: 0, dCol: arg(flat, 0, 1))  // CUF
        case 0x44: current.moveCursorRelative(dRow: 0, dCol: -arg(flat, 0, 1)) // CUB
        case 0x45: cursorNextLine(arg(flat, 0, 1))   // CNL
        case 0x46: cursorPrevLine(arg(flat, 0, 1))   // CPL
        case 0x47: current.moveCursorCol(arg(flat, 0, 1) - 1) // CHA
        case 0x48, 0x66: // CUP / HVP
            current.moveCursor(row: arg(flat, 0, 1) - 1, col: arg(flat, 1, 1) - 1)
        case 0x4A: current.eraseInDisplay(mode: argRaw(flat, 0, 0)) // ED
        case 0x4B: current.eraseInLine(mode: argRaw(flat, 0, 0))    // EL
        case 0x4C: current.insertLines(arg(flat, 0, 1))   // IL
        case 0x4D: current.deleteLines(arg(flat, 0, 1))   // DL
        case 0x40: current.insertCharacters(arg(flat, 0, 1)) // ICH
        case 0x50: current.deleteCharacters(arg(flat, 0, 1)) // DCH
        case 0x58: current.eraseCharacters(arg(flat, 0, 1))  // ECH
        case 0x53: current.scrollUp(arg(flat, 0, 1))   // SU
        case 0x54: current.scrollDown(arg(flat, 0, 1)) // SD
        case 0x64: current.moveCursorRow(arg(flat, 0, 1) - 1) // VPA
        case 0x6D: current.applySGR(groups: params)    // SGR
        case 0x72: setScrollRegion(flat)               // DECSTBM
        case 0x73: current.saveCursor()                // ANSI save cursor
        case 0x75: current.restoreCursor()             // ANSI restore cursor
        case 0x6E: deviceStatusReport(argRaw(flat, 0, 0)) // DSR
        case 0x63: deviceAttributes()                  // DA
        case 0x67: // TBC — `CSI g` clear tab at cursor; `CSI 3 g` clear all
            argRaw(flat, 0, 0) == 3 ? current.clearAllTabStops() : current.clearTabStop()
        case 0x49: current.cursorForwardTabs(arg(flat, 0, 1))  // CHT — forward N tab stops
        case 0x5A: current.cursorBackwardTabs(arg(flat, 0, 1)) // CBT — back N tab stops
        default: break
        }
    }

    func parserOSC(_ data: [UInt8]) {
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        guard let semi = text.firstIndex(of: ";") else { return }
        let code = String(text[text.startIndex ..< semi])
        let payload = String(text[text.index(after: semi)...])
        switch code {
        case "0", "2": onTitleChange?(payload)            // icon+title / title
        case "7": handleWorkingDirectoryOSC(payload)       // cwd as file:// URL
        case "8": handleHyperlinkOSC(payload)              // OSC 8 hyperlinks
        case "10": handleColorQuery(code: "10", role: .foreground, payload: payload)
        case "11": handleColorQuery(code: "11", role: .background, payload: payload)
        case "12": handleColorQuery(code: "12", role: .cursor, payload: payload)
        case "4": handlePaletteColorQuery(payload)         // OSC 4 ; index ; ?
        case "52": handleClipboardOSC(payload)             // clipboard set (OSC 52)
        case "9": onNotification?(nil, payload)            // OSC 9 ; <body> — desktop notification
        case "777": handleNotify777(payload)               // OSC 777 ; notify ; <title> ; <body>
        case "22": setPointerShape(payload)                // OSC 22 ; <shape> — mouse cursor shape
        default: break
        }
    }

    /// OSC 777 `notify;<title>;<body>` (urxvt/Ghostty). Other 777 sub-commands are ignored.
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

    /// Parameter at `index`, treating absent/zero as `defaultValue` (for 1-based counts).
    private func arg(_ params: [Int], _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        let v = params[index]
        return v == 0 ? defaultValue : v
    }

    /// Parameter at `index` with a literal default (for modes where 0 is meaningful).
    private func argRaw(_ params: [Int], _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        return params[index]
    }

    private func cursorNextLine(_ n: Int) {
        for _ in 0 ..< n { current.lineFeed() }
        current.carriageReturn()
    }

    private func cursorPrevLine(_ n: Int) {
        for _ in 0 ..< n { current.reverseLineFeed() }
        current.carriageReturn()
    }

    private func setScrollRegion(_ params: [Int]) {
        let top = arg(params, 0, 1) - 1
        // Use the bounds-safe accessor for both branches (no direct `params[1]` indexing).
        let rawBottom = argRaw(params, 1, 0)
        let bottom = rawBottom == 0 ? rows - 1 : rawBottom - 1
        current.setScrollRegion(top: top, bottom: bottom)
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
        // DECRQM: `CSI ? Ps $ p` — report a private mode's current state.
        if final == 0x70, intermediates == [0x24] { // '$' then 'p'
            for p in params { reportPrivateMode(p) }
            return
        }
        let set = (final == 0x68) // 'h' set, 'l' reset
        guard final == 0x68 || final == 0x6C else { return }
        for p in params {
            switch p {
            case 7: current.autowrap = set                 // DECAWM autowrap
            case 25: current.cursorVisible = set           // DECTCEM cursor visibility
            case 1000: modes.mouseClick = set              // X10/normal mouse
            case 1002: modes.mouseDrag = set               // button-event tracking
            case 1003: modes.mouseAny = set                // any-event tracking
            case 1006: modes.mouseSGR = set                // SGR extended coordinates
            case 1004: modes.focusReporting = set          // focus in/out reporting
            case 2004: modes.bracketedPaste = set          // bracketed paste
            case 2026: modes.synchronizedOutput = set      // synchronized output (no tearing)
            case 1: modes.cursorKeysApplication = set      // DECCKM
            case 47, 1047: switchAlternate(set, clearOnEnter: true, saveCursor: false)
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
        case 7: state = current.autowrap ? 1 : 2
        case 25: state = current.cursorVisible ? 1 : 2
        case 1000: state = modes.mouseClick ? 1 : 2
        case 1002: state = modes.mouseDrag ? 1 : 2
        case 1003: state = modes.mouseAny ? 1 : 2
        case 1006: state = modes.mouseSGR ? 1 : 2
        case 1004: state = modes.focusReporting ? 1 : 2
        case 2004: state = modes.bracketedPaste ? 1 : 2
        case 2026: state = modes.synchronizedOutput ? 1 : 2
        case 1: state = modes.cursorKeysApplication ? 1 : 2
        default: state = 0 // not recognized
        }
        respond("\u{1b}[?\(p);\(state)$y")
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
        // Identify as a VT100 with Advanced Video Option (a safe, widely-accepted reply).
        respond("\u{1b}[?1;2c")
    }

    private func respond(_ s: String) {
        onResponse?(Data(s.utf8))
    }

    private func handleWorkingDirectoryOSC(_ payload: String) {
        // OSC 7 value is a file URL: file://host/path
        if let url = URL(string: payload), url.isFileURL {
            onWorkingDirectoryChange?(url.path)
        } else if payload.hasPrefix("file://") {
            // Fallback: strip scheme + authority manually.
            let withoutScheme = String(payload.dropFirst("file://".count))
            if let slash = withoutScheme.firstIndex(of: "/") {
                onWorkingDirectoryChange?(String(withoutScheme[slash...]))
            }
        }
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
        pointerShape = nil
        hyperlinks.removeAll()
        hyperlinkKeys.removeAll()
        nextHyperlinkID = 1
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
    public var mouseClick = false
    public var mouseDrag = false
    public var mouseAny = false
    public var mouseSGR = false
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
