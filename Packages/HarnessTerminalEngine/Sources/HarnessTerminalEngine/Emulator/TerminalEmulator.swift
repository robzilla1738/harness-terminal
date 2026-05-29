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
    /// Bytes the terminal must write back to the PTY (DSR cursor report, DA, etc.).
    public var onResponse: ((Data) -> Void)?

    public init(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        primary = TerminalScreen(cols: c, rows: r)
        alternate = TerminalScreen(cols: c, rows: r)
        current = primary
        parser = VTParser(handler: self)
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

    // MARK: - VTParserHandler

    func parserPrint(_ scalar: UInt32) {
        current.print(scalar)
    }

    func parserExecute(_ control: UInt8) {
        switch control {
        case 0x07: onBell?()                 // BEL
        case 0x08: current.backspace()       // BS
        case 0x09: current.tab()             // HT
        case 0x0A, 0x0B, 0x0C: current.lineFeed() // LF, VT, FF
        case 0x0D: current.carriageReturn()  // CR
        default: break
        }
    }

    func parserESC(final: UInt8, intermediates: [UInt8]) {
        // Charset designation (ESC ( B etc.) and other intermediate sequences are
        // accepted but not acted on in Phase 1.
        guard intermediates.isEmpty else { return }
        switch final {
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

    func parserCSI(final: UInt8, params: [Int], intermediates: [UInt8], isPrivate: Bool) {
        if isPrivate {
            handlePrivateMode(final: final, params: params)
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
        case 0x48, 0x66: // CUP / HVP
            current.moveCursor(row: arg(params, 0, 1) - 1, col: arg(params, 1, 1) - 1)
        case 0x4A: current.eraseInDisplay(mode: argRaw(params, 0, 0)) // ED
        case 0x4B: current.eraseInLine(mode: argRaw(params, 0, 0))    // EL
        case 0x4C: current.insertLines(arg(params, 0, 1))   // IL
        case 0x4D: current.deleteLines(arg(params, 0, 1))   // DL
        case 0x40: current.insertCharacters(arg(params, 0, 1)) // ICH
        case 0x50: current.deleteCharacters(arg(params, 0, 1)) // DCH
        case 0x58: current.eraseCharacters(arg(params, 0, 1))  // ECH
        case 0x53: current.scrollUp(arg(params, 0, 1))   // SU
        case 0x54: current.scrollDown(arg(params, 0, 1)) // SD
        case 0x64: current.moveCursorRow(arg(params, 0, 1) - 1) // VPA
        case 0x6D: current.applySGR(params)              // SGR
        case 0x72: setScrollRegion(params)               // DECSTBM
        case 0x73: current.saveCursor()                  // ANSI save cursor
        case 0x75: current.restoreCursor()               // ANSI restore cursor
        case 0x6E: deviceStatusReport(argRaw(params, 0, 0)) // DSR
        case 0x63: deviceAttributes()                    // DA
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
        default: break                                     // 8 (links), 52 (clipboard) — Phase 6+
        }
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
        let bottom = (argRaw(params, 1, 0) == 0) ? rows - 1 : params[1] - 1
        current.setScrollRegion(top: top, bottom: bottom)
    }

    private func handlePrivateMode(final: UInt8, params: [Int]) {
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
            case 1: modes.cursorKeysApplication = set      // DECCKM
            case 47, 1047: switchAlternate(set, clearOnEnter: true, saveCursor: false)
            case 1049: switchAlternate(set, clearOnEnter: true, saveCursor: true)
            default: break
            }
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

    public init() {}

    /// Any mouse-tracking mode is active.
    public var mouseTrackingEnabled: Bool { mouseClick || mouseDrag || mouseAny }
}
