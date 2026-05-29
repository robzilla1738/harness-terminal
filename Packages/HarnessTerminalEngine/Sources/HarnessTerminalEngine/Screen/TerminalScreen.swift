import Foundation

/// The mutable terminal screen: a `cols × rows` cell buffer plus cursor, the current
/// SGR "pen", a scroll region, and autowrap state. It implements the *effects* of
/// control functions (print, cursor moves, erase, scroll, SGR) — the parser decodes
/// bytes and calls these methods; it knows nothing about escape syntax.
///
/// One `TerminalScreen` represents the active buffer. Alternate-screen support swaps
/// the underlying storage in `TerminalEmulator` and keeps two of these. Scrollback is
/// daemon-owned and intentionally not stored here — the engine renders the viewport.
final class TerminalScreen {
    private(set) var cols: Int
    private(set) var rows: Int

    /// Row-major cell storage, `cols * rows` long.
    private var cells: [TerminalGridCell]

    /// 0-based cursor position. `pendingWrap` defers the autowrap that should happen
    /// *after* a glyph is written in the last column, matching xterm semantics (the
    /// cursor visually stays on the last column until the next printable arrives).
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private var pendingWrap = false

    var cursorVisible = true
    var autowrap = true

    /// Inclusive scroll region (DECSTBM). Defaults to the whole screen.
    private var scrollTop = 0
    private var scrollBottom: Int

    /// Current graphic rendition applied to newly printed cells.
    private var pen = Pen()

    /// Lines that have scrolled off the top of the screen, oldest first. Only the primary
    /// screen records history (the alternate screen is for full-screen TUIs). Each entry is
    /// one row of cells captured at its width when evicted; the reader pads/truncates.
    private var history: [[TerminalGridCell]] = []
    /// Whether this screen accumulates scrollback (primary = true, alternate = false).
    let recordsHistory: Bool
    /// Cap on retained scrollback lines.
    var maxHistoryLines = 10_000

    /// Number of scrolled-off lines currently retained.
    var historyCount: Int { history.count }

    init(cols: Int, rows: Int, recordsHistory: Bool = false) {
        let c = max(1, cols)
        let r = max(1, rows)
        self.cols = c
        self.rows = r
        self.scrollBottom = r - 1
        self.recordsHistory = recordsHistory
        self.cells = Array(repeating: .blank, count: c * r)
    }

    // MARK: - Snapshot

    /// An immutable copy of the current screen for `readGrid()` / rendering.
    func snapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cells: cells,
            cursor: TerminalCursor(row: cursorRow, col: cursorCol, visible: cursorVisible)
        )
    }

    /// A snapshot scrolled `offset` lines up into history (0 = the live viewport). The
    /// window spans `rows` lines over the virtual sequence [history ++ viewport]; history
    /// lines are padded/truncated to the current width. The cursor is hidden when scrolled
    /// off the live view.
    func snapshot(scrollbackOffset offset: Int) -> TerminalGridSnapshot {
        let clamped = max(0, min(offset, history.count))
        guard clamped > 0 else { return snapshot() }
        var out = [TerminalGridCell]()
        out.reserveCapacity(cols * rows)
        let topIndex = history.count - clamped // index into [history ++ viewport]
        for i in 0 ..< rows {
            let idx = topIndex + i
            if idx < history.count {
                let line = history[idx]
                for c in 0 ..< cols { out.append(c < line.count ? line[c] : .blank) }
            } else {
                let viewportRow = idx - history.count
                if viewportRow >= 0, viewportRow < rows {
                    for c in 0 ..< cols { out.append(cells[viewportRow * cols + c]) }
                } else {
                    for _ in 0 ..< cols { out.append(.blank) }
                }
            }
        }
        return TerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cells: out,
            cursor: TerminalCursor(row: cursorRow, col: cursorCol, visible: false)
        )
    }

    // MARK: - Resize

    /// Resize to a new geometry. Content is preserved top-left; the cursor is clamped.
    /// (Reflow/rewrap is a later refinement — daemon owns history, so a hard reflow
    /// here is acceptable for Phase 1 and matches many terminals' simple resize.)
    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        guard nc != cols || nr != rows else { return }
        var next = Array(repeating: TerminalGridCell.blank, count: nc * nr)
        let copyRows = min(rows, nr)
        let copyCols = min(cols, nc)
        for r in 0 ..< copyRows {
            for c in 0 ..< copyCols {
                next[r * nc + c] = cells[r * cols + c]
            }
        }
        cells = next
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = nr - 1
        cursorRow = min(cursorRow, nr - 1)
        cursorCol = min(cursorCol, nc - 1)
        pendingWrap = false
    }

    // MARK: - Printing

    /// Write one printable scalar at the cursor, honoring width and autowrap.
    func print(_ scalar: UInt32) {
        let w = CharacterWidth.width(of: scalar)

        // Zero-width (combining marks etc.): attach to the previous cell's glyph when
        // possible. Phase 1 keeps the primary scalar and drops the combining mark from
        // the grid model (renderer-side grapheme composition lands with the Metal
        // renderer); it must never advance the cursor.
        if w == 0 { return }

        // A glyph that cannot fit in the remaining columns wraps first.
        if pendingWrap {
            wrapLine()
        } else if w == 2, cursorCol >= cols - 1 {
            wrapLine()
        }

        if w == 2 {
            writeCell(makeCell(scalar, width: .wide), at: cursorCol)
            if cursorCol + 1 < cols {
                writeCell(makeCell(0, width: .spacerTail), at: cursorCol + 1)
            }
            advance(by: 2)
        } else {
            writeCell(makeCell(scalar, width: .normal), at: cursorCol)
            advance(by: 1)
        }
    }

    private func makeCell(_ scalar: UInt32, width: TerminalCellWidth) -> TerminalGridCell {
        TerminalGridCell(
            codepoint: scalar,
            foreground: pen.foreground,
            background: pen.background,
            underlineColor: pen.underlineColor,
            bold: pen.bold,
            faint: pen.faint,
            italic: pen.italic,
            underline: pen.underline,
            blink: pen.blink,
            inverse: pen.inverse,
            invisible: pen.invisible,
            strikethrough: pen.strikethrough,
            overline: pen.overline,
            width: width
        )
    }

    private func writeCell(_ cell: TerminalGridCell, at col: Int) {
        guard col >= 0, col < cols, cursorRow >= 0, cursorRow < rows else { return }
        cells[cursorRow * cols + col] = cell
    }

    /// Advance the cursor after writing a glyph, arming a deferred wrap when it reaches
    /// past the last column instead of wrapping immediately.
    private func advance(by n: Int) {
        let next = cursorCol + n
        if next >= cols {
            cursorCol = cols - 1
            pendingWrap = autowrap
        } else {
            cursorCol = next
            pendingWrap = false
        }
    }

    /// Move to column 0 of the next line, scrolling within the region if at the bottom.
    private func wrapLine() {
        pendingWrap = false
        cursorCol = 0
        lineFeed()
    }

    // MARK: - Cursor & line control

    func carriageReturn() {
        cursorCol = 0
        pendingWrap = false
    }

    func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    func reverseLineFeed() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    func backspace() {
        if pendingWrap {
            pendingWrap = false
        } else if cursorCol > 0 {
            cursorCol -= 1
        }
    }

    func tab() {
        pendingWrap = false
        guard cursorCol < cols - 1 else { return }
        // Next multiple of 8, capped at the last column.
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = min(next, cols - 1)
    }

    func moveCursor(row: Int, col: Int) {
        cursorRow = clamp(row, 0, rows - 1)
        cursorCol = clamp(col, 0, cols - 1)
        pendingWrap = false
    }

    func moveCursorRow(_ row: Int) { moveCursor(row: row, col: cursorCol) }
    func moveCursorCol(_ col: Int) { moveCursor(row: cursorRow, col: col) }

    func moveCursorRelative(dRow: Int, dCol: Int) {
        moveCursor(row: cursorRow + dRow, col: cursorCol + dCol)
    }

    // MARK: - Scroll region

    /// Set the inclusive scroll region (DECSTBM). 0-based, clamped; resets cursor to home.
    func setScrollRegion(top: Int, bottom: Int) {
        let t = clamp(top, 0, rows - 1)
        let b = clamp(bottom, 0, rows - 1)
        guard t < b else {
            scrollTop = 0
            scrollBottom = rows - 1
            moveCursor(row: 0, col: 0)
            return
        }
        scrollTop = t
        scrollBottom = b
        moveCursor(row: 0, col: 0)
    }

    func scrollUp(_ n: Int) {
        let count = max(1, n)
        let blank = erasedCell()
        for _ in 0 ..< count {
            // A line leaving the very top of the screen (not a sub-region) is scrollback.
            if recordsHistory, scrollTop == 0 {
                history.append(Array(cells[0 ..< cols]))
                if history.count > maxHistoryLines {
                    history.removeFirst(history.count - maxHistoryLines)
                }
            }
            // Drop the top region line; shift the rest up; blank the bottom line.
            for r in scrollTop ..< scrollBottom {
                for c in 0 ..< cols {
                    cells[r * cols + c] = cells[(r + 1) * cols + c]
                }
            }
            for c in 0 ..< cols {
                cells[scrollBottom * cols + c] = blank
            }
        }
    }

    func scrollDown(_ n: Int) {
        let count = max(1, n)
        let blank = erasedCell()
        for _ in 0 ..< count {
            var r = scrollBottom
            while r > scrollTop {
                for c in 0 ..< cols {
                    cells[r * cols + c] = cells[(r - 1) * cols + c]
                }
                r -= 1
            }
            for c in 0 ..< cols {
                cells[scrollTop * cols + c] = blank
            }
        }
    }

    // MARK: - Erase / edit

    /// A cleared cell carrying the current background (terminals erase with the active
    /// background color but no glyph/foreground attributes).
    private func erasedCell() -> TerminalGridCell {
        TerminalGridCell(background: pen.background)
    }

    /// ED — erase in display. mode 0: cursor→end, 1: start→cursor, 2/3: all.
    func eraseInDisplay(mode: Int) {
        let blank = erasedCell()
        switch mode {
        case 1:
            for r in 0 ..< cursorRow {
                for c in 0 ..< cols { cells[r * cols + c] = blank }
            }
            for c in 0 ... cursorCol where c < cols { cells[cursorRow * cols + c] = blank }
        case 2, 3:
            for i in 0 ..< cells.count { cells[i] = blank }
        default: // 0
            for c in cursorCol ..< cols { cells[cursorRow * cols + c] = blank }
            for r in (cursorRow + 1) ..< rows {
                for c in 0 ..< cols { cells[r * cols + c] = blank }
            }
        }
        pendingWrap = false
    }

    /// EL — erase in line. mode 0: cursor→end, 1: start→cursor, 2: whole line.
    func eraseInLine(mode: Int) {
        let blank = erasedCell()
        switch mode {
        case 1:
            for c in 0 ... cursorCol where c < cols { cells[cursorRow * cols + c] = blank }
        case 2:
            for c in 0 ..< cols { cells[cursorRow * cols + c] = blank }
        default:
            for c in cursorCol ..< cols { cells[cursorRow * cols + c] = blank }
        }
        pendingWrap = false
    }

    /// ICH — insert `n` blank cells at the cursor, shifting the rest of the line right.
    func insertCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        let blank = erasedCell()
        let rowStart = cursorRow * cols
        var c = cols - 1
        while c >= cursorCol + count {
            cells[rowStart + c] = cells[rowStart + c - count]
            c -= 1
        }
        for c in cursorCol ..< (cursorCol + count) { cells[rowStart + c] = blank }
        pendingWrap = false
    }

    /// DCH — delete `n` cells at the cursor, shifting the rest of the line left.
    func deleteCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        let blank = erasedCell()
        let rowStart = cursorRow * cols
        var c = cursorCol
        while c + count < cols {
            cells[rowStart + c] = cells[rowStart + c + count]
            c += 1
        }
        while c < cols { cells[rowStart + c] = blank; c += 1 }
        pendingWrap = false
    }

    /// ECH — erase `n` cells at the cursor in place (no shifting).
    func eraseCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        let blank = erasedCell()
        let rowStart = cursorRow * cols
        for c in cursorCol ..< (cursorCol + count) { cells[rowStart + c] = blank }
    }

    /// IL — insert `n` blank lines at the cursor row, within the scroll region.
    func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = clamp(n, 1, scrollBottom - cursorRow + 1)
        let blank = erasedCell()
        var r = scrollBottom
        while r >= cursorRow + count {
            for c in 0 ..< cols { cells[r * cols + c] = cells[(r - count) * cols + c] }
            r -= 1
        }
        for r in cursorRow ..< (cursorRow + count) {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
        }
        pendingWrap = false
    }

    /// DL — delete `n` lines at the cursor row, within the scroll region.
    func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = clamp(n, 1, scrollBottom - cursorRow + 1)
        let blank = erasedCell()
        var r = cursorRow
        while r + count <= scrollBottom {
            for c in 0 ..< cols { cells[r * cols + c] = cells[(r + count) * cols + c] }
            r += 1
        }
        while r <= scrollBottom {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
            r += 1
        }
        pendingWrap = false
    }

    // MARK: - SGR (graphic rendition)

    func resetPen() { pen = Pen() }

    /// Apply decoded SGR parameter groups to the pen. Each group is one semicolon-separated
    /// parameter with its colon sub-parameters. Handles all standard attribute toggles,
    /// 16/256/truecolor for fg (38), bg (48), and underline color (58) in BOTH the
    /// semicolon form (`38;5;n`, `38;2;r;g;b`) and the colon form (`38:5:n`, `38:2::r:g:b`),
    /// and `4:N` underline styles (curly/dotted/dashed).
    func applySGR(groups: [[Int]]) {
        guard !groups.isEmpty else { resetPen(); return }
        var i = 0
        while i < groups.count {
            let group = groups[i]
            let code = group.first ?? 0
            if group.count > 1 {
                // Colon sub-parameter form: the whole spec lives in this one group.
                switch code {
                case 4: pen.underline = Self.underlineStyle(group[1])
                case 38: if let c = Self.colonColor(group) { pen.foreground = c }
                case 48: if let c = Self.colonColor(group) { pen.background = c }
                case 58: if let c = Self.colonColor(group) { pen.underlineColor = c }
                default: applySingleCode(code)
                }
                i += 1
            } else {
                switch code {
                case 38:
                    if let (c, used) = Self.semicolonColor(groups, from: i) { pen.foreground = c; i += used } else { i += 1 }
                case 48:
                    if let (c, used) = Self.semicolonColor(groups, from: i) { pen.background = c; i += used } else { i += 1 }
                case 58:
                    if let (c, used) = Self.semicolonColor(groups, from: i) { pen.underlineColor = c; i += used } else { i += 1 }
                default:
                    applySingleCode(code); i += 1
                }
            }
        }
    }

    /// Apply a single (non-color, non-grouped) SGR code to the pen.
    private func applySingleCode(_ code: Int) {
        switch code {
        case 0: resetPen()
        case 1: pen.bold = true
        case 2: pen.faint = true
        case 3: pen.italic = true
        case 4: pen.underline = .single
        case 5, 6: pen.blink = true
        case 7: pen.inverse = true
        case 8: pen.invisible = true
        case 9: pen.strikethrough = true
        case 21: pen.underline = .double
        case 22: pen.bold = false; pen.faint = false
        case 23: pen.italic = false
        case 24: pen.underline = .none
        case 25: pen.blink = false
        case 27: pen.inverse = false
        case 28: pen.invisible = false
        case 29: pen.strikethrough = false
        case 30 ... 37: pen.foreground = .palette(code - 30)
        case 39: pen.foreground = .none
        case 40 ... 47: pen.background = .palette(code - 40)
        case 49: pen.background = .none
        case 53: pen.overline = true
        case 55: pen.overline = false
        case 59: pen.underlineColor = .none
        case 90 ... 97: pen.foreground = .palette(code - 90 + 8)
        case 100 ... 107: pen.background = .palette(code - 100 + 8)
        default: break // unknown / unsupported SGR codes are ignored
        }
    }

    private static func underlineStyle(_ n: Int) -> TerminalGridUnderline {
        switch n {
        case 0: return .none
        case 1: return .single
        case 2: return .double
        case 3: return .curly
        case 4: return .dotted
        case 5: return .dashed
        default: return .single
        }
    }

    private static func clampByte(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }

    /// Colon form within one group: `[38, 5, n]` palette, `[38, 2, r, g, b]` or
    /// `[38, 2, colorspace, r, g, b]` truecolor.
    private static func colonColor(_ group: [Int]) -> TerminalGridColor? {
        guard group.count >= 2 else { return nil }
        switch group[1] {
        case 5:
            guard group.count >= 3 else { return nil }
            return .palette(min(max(group[2], 0), 255))
        case 2:
            if group.count >= 6 {
                return .rgb(r: clampByte(group[3]), g: clampByte(group[4]), b: clampByte(group[5]))
            } else if group.count >= 5 {
                return .rgb(r: clampByte(group[2]), g: clampByte(group[3]), b: clampByte(group[4]))
            }
            return nil
        default:
            return nil
        }
    }

    /// Semicolon form across groups: `38;5;n` or `38;2;r;g;b`. Returns the color and how
    /// many groups it consumed (including the `38`/`48`/`58` lead group).
    private static func semicolonColor(_ groups: [[Int]], from base: Int) -> (TerminalGridColor, Int)? {
        guard base + 1 < groups.count else { return nil }
        switch groups[base + 1].first ?? 0 {
        case 5:
            guard base + 2 < groups.count else { return nil }
            return (.palette(min(max(groups[base + 2].first ?? 0, 0), 255)), 3)
        case 2:
            guard base + 4 < groups.count else { return nil }
            let r = clampByte(groups[base + 2].first ?? 0)
            let g = clampByte(groups[base + 3].first ?? 0)
            let b = clampByte(groups[base + 4].first ?? 0)
            return (.rgb(r: r, g: g, b: b), 5)
        default:
            return nil
        }
    }

    // MARK: - Save / restore cursor (DECSC / DECRC)

    private var savedCursor: SavedCursor?

    func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, col: cursorCol, pen: pen, pendingWrap: pendingWrap)
    }

    func restoreCursor() {
        guard let s = savedCursor else {
            moveCursor(row: 0, col: 0)
            return
        }
        cursorRow = clamp(s.row, 0, rows - 1)
        cursorCol = clamp(s.col, 0, cols - 1)
        pen = s.pen
        pendingWrap = s.pendingWrap
    }

    /// Clear the entire screen and home the cursor (used on alternate-screen entry).
    func clearAll() {
        eraseInDisplay(mode: 2)
        moveCursor(row: 0, col: 0)
    }

    // MARK: - Reset

    /// RIS — full reset: clear, home cursor, default pen and modes, and drop scrollback.
    func fullReset() {
        pen = Pen()
        history.removeAll()
        cells = Array(repeating: .blank, count: cols * rows)
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        cursorVisible = true
        autowrap = true
        scrollTop = 0
        scrollBottom = rows - 1
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        if hi < lo { return lo }
        return min(max(v, lo), hi)
    }
}

/// Saved cursor + rendition for DECSC/DECRC and alternate-screen switching.
private struct SavedCursor {
    var row: Int
    var col: Int
    var pen: Pen
    var pendingWrap: Bool
}

/// Current graphic rendition (SGR) state applied to printed cells.
private struct Pen {
    var foreground: TerminalGridColor = .none
    var background: TerminalGridColor = .none
    var underlineColor: TerminalGridColor = .none
    var bold = false
    var faint = false
    var italic = false
    var underline: TerminalGridUnderline = .none
    var blink = false
    var inverse = false
    var invisible = false
    var strikethrough = false
    var overline = false
}
