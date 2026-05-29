import Foundation

/// A headless, renderer-free terminal: feed bytes, read a styled grid snapshot. This
/// is the native replacement for the Ghostty fork's `GridTerminal` and powers the
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
}
