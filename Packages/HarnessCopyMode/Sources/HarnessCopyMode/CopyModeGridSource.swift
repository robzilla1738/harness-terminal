import HarnessTerminalEngine

/// A read-only view of a terminal's scrollback + viewport that copy-mode navigates over.
/// Both the GUI emulator (`TerminalEmulator`) and the headless compositor terminal
/// (`HarnessGridTerminal`) conform — retroactively, in this module — so one reducer drives
/// copy mode in every surface (GUI overlay and the ssh compositor) instead of two.
///
/// Coordinates are in **virtual line space**: the sequence `[scrollback history ++ live
/// viewport]`, index 0 = oldest retained line. This is exactly the space
/// `TerminalScreen.snapshot(scrollbackOffset:)` windows, so a virtual line maps cleanly to
/// a render offset (see `CopyModeState.scrollbackOffset`).
public protocol CopyModeGridSource {
    /// Total addressable lines: retained scrollback history + the live viewport rows.
    var totalLines: Int { get }
    /// Visible viewport height in rows (for page motions and keeping the cursor on-screen).
    var viewportRows: Int { get }
    /// Grid width in columns.
    var columns: Int { get }
    /// One virtual line (0 = oldest), already padded/truncated to `columns`.
    func line(_ index: Int) -> [TerminalGridCell]
    /// OSC 133 shell-prompt rows in virtual line space, oldest first (empty without shell
    /// integration) — drives the copy-mode previous/next-prompt motions.
    var promptRows: [Int] { get }
}

extension CopyModeGridSource {
    /// Default: no shell-integration marks. The engine conformances override this.
    public var promptRows: [Int] { [] }
}

/// One virtual line decomposed for column ↔ character mapping: the visible characters plus,
/// per character, the grid column where it starts and how many columns it spans. Wide (CJK)
/// glyphs report width 2 and their trailing spacer cell is dropped; blank cells become
/// spaces so selection and search treat trailing padding uniformly. Built once per line scan.
struct CopyModeLine {
    let chars: [Character]
    /// Grid column where the k-th character begins.
    let columnOf: [Int]
    /// Column span (1 or 2) of the k-th character.
    let widthOf: [Int]
    /// The line's full grid width in columns.
    let totalColumns: Int

    var text: String { String(chars) }

    /// Index of the first character at or after grid `column` (== `chars.count` if none).
    func charIndex(atOrAfter column: Int) -> Int {
        for (i, start) in columnOf.enumerated() where start >= column { return i }
        return chars.count
    }

    /// Index of the last character at or before grid `column` (== `chars.count` if past end).
    func charIndex(atOrBefore column: Int) -> Int {
        var result = chars.count
        for (i, start) in columnOf.enumerated() {
            if start <= column { result = i } else { break }
        }
        return result
    }

    /// The characters whose start column falls in `[from, to)`, as a string.
    func substring(fromColumn from: Int, toColumn to: Int) -> String {
        var out = ""
        for (i, start) in columnOf.enumerated() where start >= from && start < to {
            out.append(chars[i])
        }
        return out
    }

    /// Grid column of the last non-blank character, or 0 when the line is empty.
    var lastContentColumn: Int {
        for i in stride(from: chars.count - 1, through: 0, by: -1) where chars[i] != " " {
            return columnOf[i]
        }
        return 0
    }
}

extension CopyModeGridSource {
    /// Grid columns `[start, end]` of the whitespace-delimited word at `column` on virtual `line`,
    /// using the same separator rule as copy-mode word motion (space / tab). When `column` lands on
    /// whitespace or past the content, returns just that column. Shared so mouse double-click word
    /// selection matches copy mode exactly.
    public func wordColumnRange(line: Int, column: Int) -> ClosedRange<Int> {
        func isSeparator(_ c: Character) -> Bool { c == " " || c == "\t" }
        let rl = renderedLine(line)
        let idx = rl.charIndex(atOrBefore: column)
        guard idx < rl.chars.count else { return column ... column }
        let charStart = rl.columnOf[idx]
        let charEnd = charStart + rl.widthOf[idx] - 1
        guard column >= charStart, column <= charEnd, !isSeparator(rl.chars[idx]) else {
            return column ... column
        }
        var lo = idx, hi = idx
        while lo > 0, !isSeparator(rl.chars[lo - 1]) { lo -= 1 }
        while hi + 1 < rl.chars.count, !isSeparator(rl.chars[hi + 1]) { hi += 1 }
        return rl.columnOf[lo] ... (rl.columnOf[hi] + rl.widthOf[hi] - 1)
    }

    /// Decompose a virtual line for column/character mapping (handles wide chars + blanks).
    func renderedLine(_ index: Int) -> CopyModeLine {
        let cells = line(index)
        var chars: [Character] = []
        var columnOf: [Int] = []
        var widthOf: [Int] = []
        chars.reserveCapacity(cells.count)
        var c = 0
        while c < cells.count {
            let cell = cells[c]
            if cell.width == .spacerTail { c += 1; continue }
            // One Character per cell = base scalar + any combining marks (a Thai cluster is a single
            // grapheme), so column/character mapping stays 1:1. `cluster.first` takes that single
            // grapheme; the engine guarantees one (combining marks fold into the base, non-extending
            // format scalars are dropped), but `.first` guards defensively so a stray multi-grapheme
            // cell can never trap `Character(_:)`. Blank cells render as a space.
            chars.append(cell.cluster.first ?? " ")
            columnOf.append(c)
            widthOf.append(cell.width == .wide ? 2 : 1)
            c += 1
        }
        return CopyModeLine(chars: chars, columnOf: columnOf, widthOf: widthOf, totalColumns: cells.count)
    }
}
