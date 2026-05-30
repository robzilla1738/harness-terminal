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
    /// Program-requested cursor shape/blink (DECSCUSR); `.default`/nil honor the user setting.
    var cursorShape: TerminalCursorShape = .default
    var cursorBlinking: Bool? = nil
    var autowrap = true

    /// Inclusive scroll region (DECSTBM). Defaults to the whole screen.
    private var scrollTop = 0
    private var scrollBottom: Int

    /// Current graphic rendition applied to newly printed cells.
    private var pen = Pen()
    /// Active OSC 8 hyperlink id (0 = none) stamped onto printed cells. Deliberately *not* part
    /// of `Pen` — OSC 8 links must survive an SGR reset; only OSC 8 (or RIS) changes this.
    private var currentHyperlink: UInt32 = 0

    /// Lines that have scrolled off the top of the screen, oldest first. Only the primary
    /// screen records history (the alternate screen is for full-screen TUIs). Each entry is
    /// one row of cells captured at its width when evicted; the reader pads/truncates.
    /// One scrolled-off line plus whether it ended by a soft autowrap (so reflow can re-join
    /// it with its continuation) rather than a hard line break.
    private struct HistoryLine { var cells: [TerminalGridCell]; var wrapped: Bool }
    private var history: [HistoryLine] = []
    /// Per-row soft-wrap flag, parallel to the `rows` viewport rows: true when that row
    /// continues onto the next (set on autowrap in `wrapLine`), so reflow knows which physical
    /// rows form one logical line. Kept in sync with every row move (scroll/insert/delete/erase).
    private var rowWrapped: [Bool]
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
        self.rowWrapped = Array(repeating: false, count: r)
    }

    // MARK: - Snapshot

    /// An immutable copy of the current screen for `readGrid()` / rendering.
    func snapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cells: cells,
            cursor: TerminalCursor(row: cursorRow, col: cursorCol, visible: cursorVisible, shape: cursorShape, blinking: cursorBlinking)
        )
    }

    /// DECSCUSR `CSI Ps SP q`: 0/1 blink block, 2 steady block, 3 blink underline, 4 steady
    /// underline, 5 blink bar, 6 steady bar. Out-of-range resets to the user default.
    func setCursorStyle(_ ps: Int) {
        switch ps {
        case 0, 1: cursorShape = .block; cursorBlinking = true
        case 2: cursorShape = .block; cursorBlinking = false
        case 3: cursorShape = .underline; cursorBlinking = true
        case 4: cursorShape = .underline; cursorBlinking = false
        case 5: cursorShape = .bar; cursorBlinking = true
        case 6: cursorShape = .bar; cursorBlinking = false
        default: cursorShape = .default; cursorBlinking = nil
        }
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
                let line = history[idx].cells
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

    // MARK: - Random-access line read (copy-mode / scrollback navigation)

    /// Total addressable lines in scrollback-view space: retained history + the live
    /// viewport rows. Copy-mode addresses cells in this `[history ++ viewport]` virtual
    /// sequence, exactly as `snapshot(scrollbackOffset:)` windows it.
    var bufferLineCount: Int { history.count + rows }

    /// One virtual line (0 = oldest retained history line; the last `rows` indices are the
    /// live viewport rows), padded/truncated to the current width. O(cols), so copy-mode
    /// search and motion can scan scrollback without rebuilding a whole snapshot per line.
    func bufferLine(_ index: Int) -> [TerminalGridCell] {
        guard index >= 0, index < bufferLineCount else {
            return Array(repeating: .blank, count: cols)
        }
        if index < history.count {
            let line = history[index].cells
            if line.count == cols { return line }
            var out = Array(repeating: TerminalGridCell.blank, count: cols)
            for c in 0 ..< min(cols, line.count) { out[c] = line[c] }
            return out
        }
        let row = index - history.count
        return Array(cells[row * cols ..< (row + 1) * cols])
    }

    // MARK: - Capture (capture-pane)

    /// The full buffer (`history ++ viewport`) as plain-text lines — the actual on-screen
    /// content, exactly like tmux's grid capture (so cursor moves, overwrites and clears are
    /// reflected faithfully, unlike a raw byte-stream strip). A wide glyph's `spacerTail`
    /// column is skipped; codepoint 0 reads as a space. When `joinWrapped` (tmux `-J`),
    /// physical rows that ended in a soft autowrap are concatenated with their continuation
    /// into one logical line; otherwise every physical row is one line.
    func captureLines(joinWrapped: Bool) -> [String] {
        var phys: [(cells: [TerminalGridCell], wrapped: Bool)] = []
        phys.reserveCapacity(history.count + rows)
        for h in history { phys.append((h.cells, h.wrapped)) }
        for r in 0 ..< rows {
            phys.append((Array(cells[r * cols ..< (r + 1) * cols]), rowWrapped[r]))
        }

        func text(_ cells: [TerminalGridCell], trimTrailing: Bool) -> String {
            var end = cells.count
            if trimTrailing { while end > 0, isBlank(cells[end - 1]) { end -= 1 } }
            var s = String()
            s.reserveCapacity(end)
            for i in 0 ..< end {
                let cell = cells[i]
                if cell.width == .spacerTail { continue } // wide head already emitted
                s.unicodeScalars.append(cell.codepoint == 0 ? " " : (Unicode.Scalar(cell.codepoint) ?? " "))
            }
            return s
        }

        guard joinWrapped else { return phys.map { text($0.cells, trimTrailing: true) } }

        // A soft-wrapped row continues onto the next; don't trim its trailing cells (they're
        // part of the logical line). Only trim where the logical line actually ends.
        var out: [String] = []
        var current = ""
        var building = false
        for row in phys {
            current += text(row.cells, trimTrailing: !row.wrapped)
            building = true
            if !row.wrapped {
                out.append(current)
                current = ""
                building = false
            }
        }
        if building { out.append(current) }
        return out
    }

    // MARK: - Resize

    /// Resize to a new geometry. The primary screen *reflows*: physical rows are re-joined
    /// into logical lines (following soft-wrap flags), re-wrapped to the new width, and the
    /// cursor is mapped to its new position. The alternate screen just clamps (full-screen
    /// TUIs redraw on SIGWINCH, so reflowing them would corrupt their layout).
    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        guard nc != cols || nr != rows else { return }

        if recordsHistory {
            reflow(toCols: nc, rows: nr)
        } else {
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
            rowWrapped = Array(repeating: false, count: nr)
            cursorRow = min(cursorRow, nr - 1)
            cursorCol = min(cursorCol, nc - 1)
        }
        scrollTop = 0
        scrollBottom = nr - 1
        pendingWrap = false
    }

    /// True when a cell is the default blank (no glyph, default bg, no attributes) — used to
    /// trim trailing padding so reflow doesn't manufacture spurious blank rows.
    private func isBlank(_ cell: TerminalGridCell) -> Bool { cell == .blank }

    /// Reflow the primary screen to `nc × nr`: rebuild logical lines from history + viewport
    /// (joining rows whose predecessor soft-wrapped), trim each line's trailing blanks, re-wrap
    /// to `nc` (keeping wide chars whole), then split the result into scrollback + viewport with
    /// the cursor mapped to its new physical position.
    private func reflow(toCols nc: Int, rows nr: Int) {
        // 1) Gather source rows (history ++ viewport) with their wrap flags, and the absolute
        //    index of the cursor's row in that sequence.
        var srcRows: [(cells: [TerminalGridCell], wrapped: Bool)] = []
        srcRows.reserveCapacity(history.count + rows)
        for h in history { srcRows.append((h.cells, h.wrapped)) }
        for r in 0 ..< rows {
            srcRows.append((Array(cells[r * cols ..< (r + 1) * cols]), rowWrapped[r]))
        }
        let cursorAbsRow = history.count + min(cursorRow, rows - 1)

        // 2) Build logical lines by joining a row onto the previous when it soft-wrapped.
        //    Record the cursor's (logical line index, column within that line).
        var logicals: [[TerminalGridCell]] = []
        var current: [TerminalGridCell] = []
        var building = false
        var prevWrapped = false
        var cursorLogical = 0
        var cursorLogicalCol = 0
        for (i, row) in srcRows.enumerated() {
            if building, !prevWrapped {
                // The previous logical line ended with a hard break — finalize it.
                logicals.append(current)
                current = []
            }
            building = true
            if i == cursorAbsRow {
                cursorLogical = logicals.count
                cursorLogicalCol = current.count + min(cursorCol, cols - 1)
            }
            current.append(contentsOf: row.cells)
            prevWrapped = row.wrapped
        }
        if building { logicals.append(current) }

        // 3) Trim each logical line's trailing blank cells (but never below the cursor column on
        //    the cursor's own line, so the cursor keeps its place). Empty lines are preserved.
        for i in logicals.indices {
            var end = logicals[i].count
            let floorCol = (i == cursorLogical) ? min(cursorLogicalCol, logicals[i].count) : 0
            while end > floorCol, isBlank(logicals[i][end - 1]) { end -= 1 }
            logicals[i] = Array(logicals[i].prefix(end))
        }
        cursorLogicalCol = min(cursorLogicalCol, logicals.indices.contains(cursorLogical) ? logicals[cursorLogical].count : 0)

        // 4) Re-wrap each logical line into rows of width `nc` (wide chars never split). Each
        //    logical line yields at least one row (preserving blank lines). Map the cursor.
        var out: [[TerminalGridCell]] = []
        var outWrapped: [Bool] = []
        var cursorOutRow = 0
        var cursorOutCol = 0
        let blank = TerminalGridCell.blank
        for (li, line) in logicals.enumerated() {
            var rowBuf = Array(repeating: blank, count: nc)
            var col = 0
            func flush(soft: Bool) {
                out.append(rowBuf)
                outWrapped.append(soft)
                rowBuf = Array(repeating: blank, count: nc)
                col = 0
            }
            var k = 0
            while k < line.count {
                let cell = line[k]
                if cell.width == .spacerTail { k += 1; continue } // emitted with its wide head
                let wcols = (cell.width == .wide) ? 2 : 1
                if col + wcols > nc { flush(soft: true) }
                if li == cursorLogical, k == cursorLogicalCol {
                    cursorOutRow = out.count
                    cursorOutCol = col
                }
                rowBuf[col] = cell
                if cell.width == .wide, col + 1 < nc {
                    rowBuf[col + 1] = TerminalGridCell(width: .spacerTail)
                }
                col += wcols
                k += 1
            }
            // Cursor at end-of-line (past the last cell).
            if li == cursorLogical, cursorLogicalCol >= line.count {
                cursorOutRow = out.count
                cursorOutCol = min(col, nc - 1)
            }
            flush(soft: false) // hard end of this logical line
        }

        // 5) Drop trailing blank rows that sit *below* the cursor (a terminal doesn't keep empty
        //    space under the cursor as scrollback), then split into scrollback + viewport.
        var total = out.count
        while total - 1 > cursorOutRow, isRowBlank(out[total - 1]) { total -= 1 }
        out = Array(out.prefix(total))
        outWrapped = Array(outWrapped.prefix(total))

        let viewportTop = max(0, total - nr)
        // Scrollback = rows above the viewport.
        var newHistory: [HistoryLine] = []
        if viewportTop > 0 {
            for i in 0 ..< viewportTop { newHistory.append(HistoryLine(cells: out[i], wrapped: outWrapped[i])) }
            if newHistory.count > maxHistoryLines { newHistory.removeFirst(newHistory.count - maxHistoryLines) }
        }
        // Viewport = the next `nr` rows, blank-padded at the bottom if content is shorter.
        var newCells = [TerminalGridCell]()
        newCells.reserveCapacity(nc * nr)
        var newWrapped = [Bool](repeating: false, count: nr)
        for r in 0 ..< nr {
            let srcIdx = viewportTop + r
            if srcIdx < total {
                newCells.append(contentsOf: out[srcIdx])
                newWrapped[r] = outWrapped[srcIdx]
            } else {
                newCells.append(contentsOf: Array(repeating: blank, count: nc))
            }
        }

        history = newHistory
        cells = newCells
        rowWrapped = newWrapped
        cols = nc
        rows = nr
        cursorRow = clamp(cursorOutRow - viewportTop, 0, nr - 1)
        cursorCol = clamp(cursorOutCol, 0, nc - 1)
    }

    /// Whether an output row (a `[TerminalGridCell]`) is entirely default-blank.
    private func isRowBlank(_ row: [TerminalGridCell]) -> Bool {
        for cell in row where !isBlank(cell) { return false }
        return true
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
            width: width,
            hyperlinkID: currentHyperlink
        )
    }

    /// Set the active OSC 8 hyperlink id stamped onto subsequently-printed cells (0 = none).
    func setHyperlink(_ id: UInt32) { currentHyperlink = id }

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
        // The row we're leaving continues onto the next (a soft wrap) — record it so resize
        // reflow re-joins the logical line. `lineFeed` may scroll; `scrollUp` carries the flag.
        if cursorRow >= 0, cursorRow < rowWrapped.count { rowWrapped[cursorRow] = true }
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
            // A line leaving the very top of the screen (not a sub-region) is scrollback —
            // carry its soft-wrap flag so reflow can re-join it with its continuation.
            if recordsHistory, scrollTop == 0 {
                history.append(HistoryLine(cells: Array(cells[0 ..< cols]), wrapped: rowWrapped[scrollTop]))
                if history.count > maxHistoryLines {
                    history.removeFirst(history.count - maxHistoryLines)
                }
            }
            // Drop the top region line; shift the rest up; blank the bottom line.
            for r in scrollTop ..< scrollBottom {
                for c in 0 ..< cols {
                    cells[r * cols + c] = cells[(r + 1) * cols + c]
                }
                rowWrapped[r] = rowWrapped[r + 1]
            }
            for c in 0 ..< cols {
                cells[scrollBottom * cols + c] = blank
            }
            rowWrapped[scrollBottom] = false
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
                rowWrapped[r] = rowWrapped[r - 1]
                r -= 1
            }
            for c in 0 ..< cols {
                cells[scrollTop * cols + c] = blank
            }
            rowWrapped[scrollTop] = false
        }
    }

    // MARK: - Erase / edit

    /// A cleared cell carrying the current background (terminals erase with the active
    /// background color but no glyph/foreground attributes).
    private func erasedCell() -> TerminalGridCell {
        TerminalGridCell(background: pen.background)
    }

    /// ED — erase in display. mode 0: cursor→end, 1: start→cursor, 2/3: all. Cleared full rows
    /// no longer continue a wrapped line, so their soft-wrap flags reset.
    func eraseInDisplay(mode: Int) {
        let blank = erasedCell()
        switch mode {
        case 1:
            for r in 0 ..< cursorRow {
                for c in 0 ..< cols { cells[r * cols + c] = blank }
                rowWrapped[r] = false
            }
            for c in 0 ... cursorCol where c < cols { cells[cursorRow * cols + c] = blank }
        case 2, 3:
            for i in 0 ..< cells.count { cells[i] = blank }
            for r in 0 ..< rows { rowWrapped[r] = false }
        default: // 0
            for c in cursorCol ..< cols { cells[cursorRow * cols + c] = blank }
            rowWrapped[cursorRow] = false
            for r in (cursorRow + 1) ..< rows {
                for c in 0 ..< cols { cells[r * cols + c] = blank }
                rowWrapped[r] = false
            }
        }
        pendingWrap = false
    }

    /// EL — erase in line. mode 0: cursor→end, 1: start→cursor, 2: whole line. Erasing to the
    /// end of the line (0 or 2) clears its soft-wrap continuation.
    func eraseInLine(mode: Int) {
        let blank = erasedCell()
        switch mode {
        case 1:
            for c in 0 ... cursorCol where c < cols { cells[cursorRow * cols + c] = blank }
        case 2:
            for c in 0 ..< cols { cells[cursorRow * cols + c] = blank }
            rowWrapped[cursorRow] = false
        default:
            for c in cursorCol ..< cols { cells[cursorRow * cols + c] = blank }
            rowWrapped[cursorRow] = false
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
            rowWrapped[r] = rowWrapped[r - count]
            r -= 1
        }
        for r in cursorRow ..< (cursorRow + count) {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
            rowWrapped[r] = false
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
            rowWrapped[r] = rowWrapped[r + count]
            r += 1
        }
        while r <= scrollBottom {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
            rowWrapped[r] = false
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
        currentHyperlink = 0
        cursorShape = .default
        cursorBlinking = nil
        history.removeAll()
        cells = Array(repeating: .blank, count: cols * rows)
        rowWrapped = Array(repeating: false, count: rows)
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
