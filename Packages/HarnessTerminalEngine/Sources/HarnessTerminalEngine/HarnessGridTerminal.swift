import Foundation

/// A headless, renderer-free terminal: feed bytes, read a styled grid snapshot. This
/// is Harness's native grid terminal and powers the
/// `harness attach` compositor. It deliberately mirrors that type's shape
/// (`init?`, `feed`, `resize`, `readGrid() -> TerminalGridSnapshot?`) so the cutover at
/// call sites is a type-name swap.
///
/// Unlike the live renderer there is no Metal/AppKit here — it's pure Swift and safe to
/// create, drive, resize, and destroy off the main thread (one instance per pane).
public final class HarnessGridTerminal {
    private let emulator: TerminalEmulator

    public init?(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return nil }
        emulator = TerminalEmulator(cols: cols, rows: rows)
    }

    /// Clipboard text set by the program via OSC 52 (base64-decoded). Used by the
    /// GUI surface and the attach-window compositor to set the client clipboard.
    public var onSetClipboard: ((String) -> Void)? {
        get { emulator.onSetClipboard }
        set { emulator.onSetClipboard = newValue }
    }

    /// Bytes the emulator wants written back to the PTY (DA/DSR/DECRQM replies, …). Left
    /// unwired by the compositor today (a second attached client would double-reply); the GUI
    /// surface owns the authoritative response path.
    public var onResponse: ((Data) -> Void)? {
        get { emulator.onResponse }
        set { emulator.onResponse = newValue }
    }

    public func feed(_ data: Data) { emulator.feed(data) }
    public func feed(_ text: String) { emulator.feed(text) }
    public func feed(_ bytes: [UInt8]) { emulator.feed(bytes) }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        emulator.resize(cols: cols, rows: rows)
    }

    public func readGrid() -> TerminalGridSnapshot? {
        emulator.readGrid()
    }

    /// Dirty viewport rows since the last call (resets the accumulator). See
    /// `TerminalEmulator.consumeDamage()`.
    public func consumeDamage() -> TerminalDamage {
        emulator.consumeDamage()
    }

    /// Read the viewport scrolled `offset` lines up into scrollback (0 = live bottom).
    /// Powers the compositor's copy-mode overlay (it renders history the same way the GUI
    /// surface does).
    public func readGrid(scrollbackOffset offset: Int) -> TerminalGridSnapshot? {
        emulator.readGrid(scrollbackOffset: offset)
    }

    /// Grid geometry + scrollback metrics (for copy-mode navigation and mouse demux).
    public var columns: Int { emulator.cols }
    public var rowCount: Int { emulator.rows }
    public var historyCount: Int { emulator.historyCount }

    /// Total lines addressable by copy-mode (history + viewport) and a single virtual line.
    public var bufferLineCount: Int { emulator.bufferLineCount }
    public func bufferLine(_ index: Int) -> [TerminalGridCell] { emulator.bufferLine(index) }

    /// OSC 133 shell-prompt rows (copy-mode view space), oldest first.
    public var promptRows: [Int] { emulator.promptRows }
    /// The OSC 133 semantic mark on a copy-mode-space line, or nil.
    public func mark(atBufferLine index: Int) -> SemanticMark? { emulator.mark(atBufferLine: index) }

    /// Scrollback retention cap (lines). Raised by the daemon's `capture-pane` so a long
    /// history reconstructs fully.
    public var maxScrollbackLines: Int {
        get { emulator.maxScrollbackLines }
        set { emulator.maxScrollbackLines = newValue }
    }

    /// The full buffer as plain-text lines for `capture-pane`; `joinWrapped` (tmux `-J`)
    /// joins soft-wrapped physical rows into their logical line.
    public func captureLines(joinWrapped: Bool) -> [String] { emulator.captureLines(joinWrapped: joinWrapped) }

    /// Resolve a cell's OSC 8 `hyperlinkID` to its URL (nil for 0 / unknown).
    public func hyperlinkURL(id: UInt32) -> String? { emulator.hyperlinkURL(id: id) }

    /// The pane's active terminal modes (mouse tracking, bracketed paste, …) — read by the
    /// compositor to encode forwarded mouse events correctly.
    public var modes: TerminalModes { emulator.modes }
}
