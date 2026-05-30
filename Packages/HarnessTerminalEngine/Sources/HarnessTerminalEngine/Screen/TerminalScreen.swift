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
    /// Column tab stops (HTS/TBC). Length tracks `cols`; default is every 8th column. A `true`
    /// at index `c` means a tab stop sits at column `c`.
    private var tabStops: [Bool] = []

    // MARK: - Inline images
    /// One placed image. `absRow` is the row in the virtual `[history ++ viewport]` sequence
    /// (the same coordinate space as `bufferLine` and prompt marks), so an image rides scrollback
    /// and reflow with the line it sits on instead of being dropped. Pixels live in `imageStore`
    /// keyed by id.
    private struct ImagePlacement { var id: Int; var absRow: Int; var col: Int; var cols: Int; var rows: Int; var z: Int }
    private var placements: [ImagePlacement] = []
    private var imageStore: [Int: DecodedImage] = [:]
    private var nextImageID = 1
    private var imageByteTotal = 0
    /// Pixel size of one cell, set by the host renderer; used to size an image's cell footprint
    /// and advance the cursor below it. A deterministic headless default keeps engine tests stable.
    var cellPixelWidth = 8
    var cellPixelHeight = 16

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
    private struct HistoryLine { var cells: [TerminalGridCell]; var wrapped: Bool; var mark: SemanticMark? = nil }
    private var history: [HistoryLine] = []
    /// Per-row soft-wrap flag, parallel to the `rows` viewport rows: true when that row
    /// continues onto the next (set on autowrap in `wrapLine`), so reflow knows which physical
    /// rows form one logical line. Kept in sync with every row move (scroll/insert/delete/erase).
    private var rowWrapped: [Bool]
    /// Per-row OSC 133 semantic mark, parallel to `rowWrapped` (and carried into `HistoryLine`
    /// when a row scrolls off): non-nil marks a shell prompt line. Kept in lockstep with
    /// `rowWrapped` at every row move so prompt positions never drift.
    private var rowMarks: [SemanticMark?]
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
        self.rowMarks = Array(repeating: nil, count: r)
        self.tabStops = Self.defaultTabStops(c)
    }

    /// Default tab stops: every 8th column (the classic 8-column tab).
    private static func defaultTabStops(_ cols: Int) -> [Bool] {
        (0 ..< max(1, cols)).map { $0 % 8 == 0 }
    }

    // MARK: - Snapshot

    /// An immutable copy of the current screen for `readGrid()` / rendering.
    func snapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cells: cells,
            cursor: TerminalCursor(row: cursorRow, col: cursorCol, visible: cursorVisible, shape: cursorShape, blinking: cursorBlinking),
            images: imageSnapshots(topIndex: history.count),
            marks: markSnapshot(topIndex: history.count)
        )
    }

    /// Semantic marks for the `rows`-tall window whose top sits at `topIndex` in the virtual
    /// `[history ++ viewport]` sequence (`history.count` for the live view, less for a
    /// scrollback view), keyed by the row's position within the window.
    private func markSnapshot(topIndex: Int) -> [Int: SemanticMark] {
        var out: [Int: SemanticMark] = [:]
        for i in 0 ..< rows {
            let idx = topIndex + i
            let mark: SemanticMark?
            if idx < history.count {
                mark = idx >= 0 ? history[idx].mark : nil
            } else {
                let vr = idx - history.count
                mark = (vr >= 0 && vr < rowMarks.count) ? rowMarks[vr] : nil
            }
            if let mark { out[i] = mark }
        }
        return out
    }

    /// Placements mapped into the `rows`-tall window whose top sits at `topIndex` in the virtual
    /// `[history ++ viewport]` sequence (`history.count` for the live view, less for a scrollback
    /// view); only those still overlapping the window are emitted.
    private func imageSnapshots(topIndex: Int) -> [ImagePlacementSnapshot] {
        placements.compactMap { p in
            let row = p.absRow - topIndex
            guard row + p.rows > 0, row < rows else { return nil }
            return ImagePlacementSnapshot(id: p.id, row: row, col: p.col, cols: p.cols, rows: p.rows, z: p.z)
        }
    }

    /// Decoded pixels for a placed image (queried by the renderer on the main thread).
    func image(for id: Int) -> DecodedImage? { imageStore[id] }

    /// Place a decoded image at the cursor. `cols`/`rows`, when > 0, override the computed cell
    /// footprint (Kitty `c`/`r`, iTerm2 width/height). Advances the cursor below the image.
    func placeImage(_ image: DecodedImage, cols: Int = 0, rows: Int = 0, z: Int = 0) {
        let fCols = cols > 0 ? cols : max(1, Int((Double(image.pixelWidth) / Double(max(1, cellPixelWidth))).rounded(.up)))
        let fRows = rows > 0 ? rows : max(1, Int((Double(image.pixelHeight) / Double(max(1, cellPixelHeight))).rounded(.up)))
        let id = nextImageID; nextImageID += 1
        imageStore[id] = image
        imageByteTotal += image.byteCount
        placements.append(ImagePlacement(id: id, absRow: history.count + cursorRow, col: cursorCol, cols: fCols, rows: fRows, z: z))
        evictImagesIfNeeded()
        // Move the cursor below the image so following output doesn't overlap it (the placement
        // rides along if these line feeds scroll the screen).
        for _ in 0 ..< fRows { lineFeed() }
    }

    /// Enforce the per-screen image byte budget by dropping the oldest placements (LRU by age).
    private func evictImagesIfNeeded() {
        while imageByteTotal > ImageLimits.maxBytesPerScreen, !placements.isEmpty {
            let oldest = placements.removeFirst()
            if let bytes = imageStore.removeValue(forKey: oldest.id)?.byteCount { imageByteTotal -= bytes }
        }
    }

    /// Shift placements when content moves without history growing (a scroll *region* scroll, or
    /// the alternate screen) — their absolute anchors track the moved rows. Drop any pushed fully
    /// out of the viewport (region/alt scrolls don't accrue scrollback). A full-screen scroll that
    /// grows history needs no shift: the anchor is invariant because `history.count` grew to match.
    private func shiftPlacements(by delta: Int) {
        guard !placements.isEmpty else { return }
        for i in placements.indices { placements[i].absRow += delta }
        placements.removeAll { p in
            let row = p.absRow - history.count
            if row + p.rows <= 0 || row >= rows {
                if let bytes = imageStore.removeValue(forKey: p.id)?.byteCount { imageByteTotal -= bytes }
                return true
            }
            return false
        }
    }

    /// Trim `n` oldest history lines and keep image anchors consistent: every absolute row shifts
    /// down by `n`, and placements that fall entirely above the retained buffer are evicted (their
    /// pixels with them). The single funnel for dropping scrollback so images evict alongside it.
    private func dropHistoryHead(_ n: Int) {
        guard n > 0 else { return }
        history.removeFirst(min(n, history.count))
        guard !placements.isEmpty else { return }
        for i in placements.indices { placements[i].absRow -= n }
        placements.removeAll { p in
            if p.absRow + p.rows <= 0 {
                if let bytes = imageStore.removeValue(forKey: p.id)?.byteCount { imageByteTotal -= bytes }
                return true
            }
            return false
        }
    }

    private func clearImages() {
        placements.removeAll()
        imageStore.removeAll()
        imageByteTotal = 0
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
            cursor: TerminalCursor(row: cursorRow, col: cursorCol, visible: false),
            // Images are anchored in `[history ++ viewport]` space; this window starts at topIndex.
            images: imageSnapshots(topIndex: topIndex),
            marks: markSnapshot(topIndex: topIndex)
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

    // MARK: - Semantic prompts (OSC 133 shell integration)

    /// OSC 133;A — mark the cursor's row as a shell prompt line (exit unknown until 133;D).
    func markPromptStart() {
        guard cursorRow >= 0, cursorRow < rowMarks.count else { return }
        rowMarks[cursorRow] = SemanticMark(exit: rowMarks[cursorRow]?.exit)
    }

    /// OSC 133;D[;exit] — record the finished command's exit status onto the most recent prompt
    /// line at or above the cursor. Scans backward (viewport, then history) and stops at the
    /// first prompt mark — the active command's prompt — so the exit lands where the gutter
    /// indicator is drawn. A no-op when no prompt has been marked.
    func markCommandFinished(exit: Int?) {
        // Viewport rows above (and including) the cursor, newest first.
        var r = min(cursorRow, rowMarks.count - 1)
        while r >= 0 {
            if rowMarks[r] != nil { rowMarks[r]?.exit = exit; return }
            r -= 1
        }
        var h = history.count - 1
        while h >= 0 {
            if history[h].mark != nil { history[h].mark?.exit = exit; return }
            h -= 1
        }
    }

    /// Absolute indices (in `[history ++ viewport]` space, matching `bufferLine`/copy-mode) of
    /// every shell-prompt row, oldest first — drives jump-to-previous/next-prompt navigation.
    func promptRows() -> [Int] {
        var rowsOut: [Int] = []
        for (i, h) in history.enumerated() where h.mark != nil { rowsOut.append(i) }
        for (i, m) in rowMarks.enumerated() where m != nil { rowsOut.append(history.count + i) }
        return rowsOut
    }

    /// The semantic mark on a virtual line (`[history ++ viewport]` index), or nil.
    func mark(atBufferLine index: Int) -> SemanticMark? {
        guard index >= 0, index < bufferLineCount else { return nil }
        if index < history.count { return history[index].mark }
        let row = index - history.count
        return (row >= 0 && row < rowMarks.count) ? rowMarks[row] : nil
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
            // The primary screen reflows; image anchors are re-mapped onto their logical line so
            // they survive the geometry change (see `reflow`).
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
            rowMarks = Array(repeating: nil, count: nr)
            cursorRow = min(cursorRow, nr - 1)
            cursorCol = min(cursorCol, nc - 1)
            // The alternate screen has no logical-line model to reflow against (full-screen TUIs
            // redraw on SIGWINCH), so its images can't be repositioned — drop them.
            clearImages()
        }
        scrollTop = 0
        scrollBottom = nr - 1
        pendingWrap = false
        ensureTabStopsSized()   // tab stops are column-absolute; keep the array sized to `cols`
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
        // Prompt marks parallel to `srcRows`, so reflow re-anchors them onto the logical line
        // they tag (carried to that line's first physical row below).
        var srcMarks: [SemanticMark?] = []
        srcMarks.reserveCapacity(history.count + rows)
        for h in history { srcMarks.append(h.mark) }
        for r in 0 ..< rows { srcMarks.append(rowMarks[r]) }
        let cursorAbsRow = history.count + min(cursorRow, rows - 1)

        // 2) Build logical lines by joining a row onto the previous when it soft-wrapped.
        //    Record the cursor's (logical line index, column within that line).
        var logicals: [[TerminalGridCell]] = []
        var logicalMarks: [SemanticMark?] = []
        // Source-row index → the logical line it joins into, so an image anchored on that source
        // row can be re-anchored to the logical line's first re-wrapped row below.
        var logicalOf = [Int](repeating: 0, count: srcRows.count)
        var current: [TerminalGridCell] = []
        var currentMark: SemanticMark? = nil
        var building = false
        var prevWrapped = false
        var cursorLogical = 0
        var cursorLogicalCol = 0
        for (i, row) in srcRows.enumerated() {
            if building, !prevWrapped {
                // The previous logical line ended with a hard break — finalize it.
                logicals.append(current)
                logicalMarks.append(currentMark)
                current = []
                currentMark = nil
            }
            // A logical line's mark is the mark of its first physical row.
            if current.isEmpty { currentMark = srcMarks[i] }
            logicalOf[i] = logicals.count   // the index this logical line will occupy
            building = true
            if i == cursorAbsRow {
                cursorLogical = logicals.count
                cursorLogicalCol = current.count + min(cursorCol, cols - 1)
            }
            current.append(contentsOf: row.cells)
            prevWrapped = row.wrapped
        }
        if building { logicals.append(current); logicalMarks.append(currentMark) }

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
        var outMarks: [SemanticMark?] = []
        // Logical line index → index of its first re-wrapped output row (for image re-anchoring).
        var logicalFirstOutRow = [Int](repeating: 0, count: logicals.count)
        var cursorOutRow = 0
        var cursorOutCol = 0
        let blank = TerminalGridCell.blank
        for (li, line) in logicals.enumerated() {
            logicalFirstOutRow[li] = out.count
            var rowBuf = Array(repeating: blank, count: nc)
            var col = 0
            var firstRowOfLogical = true
            func flush(soft: Bool) {
                out.append(rowBuf)
                outWrapped.append(soft)
                // The logical line's mark lands on its first re-wrapped row only.
                outMarks.append(firstRowOfLogical ? logicalMarks[li] : nil)
                firstRowOfLogical = false
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
        outMarks = Array(outMarks.prefix(total))

        let viewportTop = max(0, total - nr)
        // Scrollback = rows above the viewport.
        var newHistory: [HistoryLine] = []
        if viewportTop > 0 {
            for i in 0 ..< viewportTop { newHistory.append(HistoryLine(cells: out[i], wrapped: outWrapped[i], mark: outMarks[i])) }
            if newHistory.count > maxHistoryLines { newHistory.removeFirst(newHistory.count - maxHistoryLines) }
        }
        // Viewport = the next `nr` rows, blank-padded at the bottom if content is shorter.
        var newCells = [TerminalGridCell]()
        newCells.reserveCapacity(nc * nr)
        var newWrapped = [Bool](repeating: false, count: nr)
        var newMarks = [SemanticMark?](repeating: nil, count: nr)
        for r in 0 ..< nr {
            let srcIdx = viewportTop + r
            if srcIdx < total {
                newCells.append(contentsOf: out[srcIdx])
                newWrapped[r] = outWrapped[srcIdx]
                newMarks[r] = outMarks[srcIdx]
            } else {
                newCells.append(contentsOf: Array(repeating: blank, count: nc))
            }
        }

        history = newHistory
        cells = newCells
        rowWrapped = newWrapped
        rowMarks = newMarks
        cols = nc
        rows = nr
        cursorRow = clamp(cursorOutRow - viewportTop, 0, nr - 1)
        cursorCol = clamp(cursorOutCol, 0, nc - 1)

        // Re-anchor inline images: each placement was anchored to a source-row index; map that
        // row → its logical line → that line's first re-wrapped output row, then into the final
        // [history ++ viewport] index (history may have been trimmed off the front). Placements
        // whose row fell out of the buffer (or off the retained scrollback) are evicted with
        // their pixels. Columns are re-clamped; the cell footprint is preserved.
        if !placements.isEmpty {
            let trimmedFront = viewportTop - history.count   // rows dropped by the maxHistory cap
            for i in placements.indices {
                let src = placements[i].absRow
                guard src >= 0, src < logicalOf.count else { placements[i].absRow = -1; continue }
                let outRow = logicalFirstOutRow[logicalOf[src]]
                placements[i].absRow = (outRow < total) ? outRow - trimmedFront : -1
                placements[i].col = min(placements[i].col, nc - 1)
            }
            placements.removeAll { p in
                if p.absRow < 0 {
                    if let bytes = imageStore.removeValue(forKey: p.id)?.byteCount { imageByteTotal -= bytes }
                    return true
                }
                return false
            }
        }
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
        advanceToNextTabStop()
    }

    /// True if column `c` is a tab stop (falls back to the every-8 default beyond the array).
    private func tabStopAt(_ c: Int) -> Bool {
        c < tabStops.count ? tabStops[c] : (c % 8 == 0)
    }

    private func advanceToNextTabStop() {
        guard cursorCol < cols - 1 else { return }
        var c = cursorCol + 1
        while c < cols - 1, !tabStopAt(c) { c += 1 }
        cursorCol = c
    }

    /// HTS — set a tab stop at the cursor column.
    func setTabStop() {
        ensureTabStopsSized()
        guard cursorCol < tabStops.count else { return }
        tabStops[cursorCol] = true
    }

    /// TBC `CSI g` — clear the tab stop at the cursor column.
    func clearTabStop() {
        ensureTabStopsSized()
        guard cursorCol < tabStops.count else { return }
        tabStops[cursorCol] = false
    }

    /// TBC `CSI 3 g` — clear every tab stop.
    func clearAllTabStops() {
        tabStops = Array(repeating: false, count: cols)
    }

    /// CHT — advance the cursor over `n` tab stops.
    func cursorForwardTabs(_ n: Int) {
        pendingWrap = false
        for _ in 0 ..< max(1, n) { advanceToNextTabStop() }
    }

    /// CBT — move the cursor back over `n` tab stops.
    func cursorBackwardTabs(_ n: Int) {
        pendingWrap = false
        for _ in 0 ..< max(1, n) {
            guard cursorCol > 0 else { return }
            var c = cursorCol - 1
            while c > 0, !tabStopAt(c) { c -= 1 }
            cursorCol = c
        }
    }

    /// Keep `tabStops` the same length as `cols`, preserving existing stops and default-filling
    /// any newly-exposed columns (tab stops are column-absolute, so they survive a resize).
    private func ensureTabStopsSized() {
        guard tabStops.count != cols else { return }
        if tabStops.count < cols {
            for c in tabStops.count ..< cols { tabStops.append(c % 8 == 0) }
        } else {
            tabStops.removeLast(tabStops.count - cols)
        }
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
        // A full-screen scroll (top of the screen, history on) accrues scrollback: image anchors
        // are invariant because `history.count` grows in step, so they ride into scrollback rather
        // than being dropped. A region/alternate scroll moves content without history, so anchors
        // shift (handled after the loop).
        let growsHistory = recordsHistory && scrollTop == 0
        for _ in 0 ..< count {
            // A line leaving the very top of the screen (not a sub-region) is scrollback —
            // carry its soft-wrap flag so reflow can re-join it with its continuation.
            if growsHistory {
                history.append(HistoryLine(cells: Array(cells[0 ..< cols]), wrapped: rowWrapped[scrollTop], mark: rowMarks[scrollTop]))
                // `removeFirst` is O(history.count) — doing it every scrolled line makes a
                // terminal at full scrollback pay O(maxHistoryLines) per output line (the
                // steady-state hot path for any long-running shell). Amortize it: let the
                // buffer overshoot by a bounded slack, then trim back to the cap in one batch,
                // so the O(n) shift fires once per `slack` lines (≈O(1) amortized). Readers
                // clamp to `history.count`, so the transient margin just exposes a little extra
                // scrollback — never less than configured. Slack is 0 when scrollback is off.
                let slack = min(1024, maxHistoryLines / 4)
                if history.count > maxHistoryLines + slack {
                    dropHistoryHead(history.count - maxHistoryLines)
                }
            }
            // Drop the top region line; shift the rest up; blank the bottom line.
            for r in scrollTop ..< scrollBottom {
                for c in 0 ..< cols {
                    cells[r * cols + c] = cells[(r + 1) * cols + c]
                }
                rowWrapped[r] = rowWrapped[r + 1]
                rowMarks[r] = rowMarks[r + 1]
            }
            for c in 0 ..< cols {
                cells[scrollBottom * cols + c] = blank
            }
            rowWrapped[scrollBottom] = false
            rowMarks[scrollBottom] = nil
        }
        // Only region/alternate scrolls move anchors; a history-growing scroll leaves them
        // invariant (the image scrolls into scrollback instead of being dropped).
        if !growsHistory { shiftPlacements(by: -count) }
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
                rowMarks[r] = rowMarks[r - 1]
                r -= 1
            }
            for c in 0 ..< cols {
                cells[scrollTop * cols + c] = blank
            }
            rowWrapped[scrollTop] = false
            rowMarks[scrollTop] = nil
        }
        shiftPlacements(by: count)
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
                rowMarks[r] = nil   // fully-cleared row is no longer a prompt
            }
            for c in 0 ... cursorCol where c < cols { cells[cursorRow * cols + c] = blank }
        case 2, 3:
            for i in 0 ..< cells.count { cells[i] = blank }
            for r in 0 ..< rows { rowWrapped[r] = false; rowMarks[r] = nil }
            clearImages()   // ED 2/3 clears the screen (and scrollback for 3) → drop images
            if mode == 3 { history.removeAll() }
        default: // 0
            for c in cursorCol ..< cols { cells[cursorRow * cols + c] = blank }
            rowWrapped[cursorRow] = false
            for r in (cursorRow + 1) ..< rows {
                for c in 0 ..< cols { cells[r * cols + c] = blank }
                rowWrapped[r] = false
                rowMarks[r] = nil   // fully-cleared row is no longer a prompt
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
            rowMarks[cursorRow] = nil   // whole line cleared → no longer a prompt
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
            rowMarks[r] = rowMarks[r - count]
            r -= 1
        }
        for r in cursorRow ..< (cursorRow + count) {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
            rowWrapped[r] = false
            rowMarks[r] = nil
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
            rowMarks[r] = rowMarks[r + count]
            r += 1
        }
        while r <= scrollBottom {
            for c in 0 ..< cols { cells[r * cols + c] = blank }
            rowWrapped[r] = false
            rowMarks[r] = nil
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
        rowMarks = Array(repeating: nil, count: rows)
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        cursorVisible = true
        autowrap = true
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(cols)
        clearImages()
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
