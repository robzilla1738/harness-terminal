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

    var cursorVisible = true {
        didSet { if cursorVisible != oldValue { markRowDirty(cursorRow) } }
    }
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
    /// Ring-buffer-backed scrollback (see `HistoryRingBuffer`): appending newest lines and trimming
    /// the oldest to the cap no longer shifts the surviving lines. Logical index 0 is the oldest,
    /// matching the `[HistoryLine]` array this replaced, so every reader below is unchanged.
    private var history = HistoryRingBuffer<HistoryLine>()
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

    // MARK: - Dirty-row damage
    /// Viewport rows whose cell content changed since the last `consumeDamage()`. Cursor
    /// *position* moves are tracked separately (`lastPresentedCursorRow`) so a pure cursor
    /// move doesn't masquerade as content damage. Cleared by `consumeDamage()`.
    private var contentDamage = IndexSet()
    /// The whole screen changed and must be fully rebuilt. Starts true so the first render
    /// paints everything.
    private var fullDamage = true
    /// The cursor row reported dirty at the last `consumeDamage()`. Unioned with the current
    /// `cursorRow` on the next consume so a moved cursor redraws both its old and new rows.
    private var lastPresentedCursorRow = 0

    /// Mark one viewport row's content dirty (out-of-range rows are ignored).
    private func markRowDirty(_ row: Int) {
        guard row >= 0, row < rows else { return }
        contentDamage.insert(row)
    }

    /// Mark a half-open range of viewport rows dirty, clamped to the grid.
    private func markRowsDirty(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound)
        let hi = min(rows, range.upperBound)
        guard lo < hi else { return }
        contentDamage.insert(integersIn: lo ..< hi)
    }

    /// Mark a closed range of viewport rows dirty, clamped to the grid.
    private func markRowsDirty(_ range: ClosedRange<Int>) {
        markRowsDirty(range.lowerBound ..< (range.upperBound + 1))
    }

    /// Flag the whole screen for a full rebuild (clear, resize/reflow, reset, screen switch).
    func markFullyDirty() { fullDamage = true }

    /// Return the rows that changed since the last call and reset the accumulator. A moved
    /// cursor contributes its old and new rows; `cursorOnly` is set when that move is the only
    /// change. `full` requests a whole-screen rebuild.
    func consumeDamage() -> TerminalDamage {
        let cursorMoved = cursorRow != lastPresentedCursorRow
        let contentEmpty = contentDamage.isEmpty
        var dirtyRows = fullDamage ? IndexSet(integersIn: 0 ..< rows) : contentDamage
        if !fullDamage, cursorMoved {
            if lastPresentedCursorRow >= 0, lastPresentedCursorRow < rows {
                dirtyRows.insert(lastPresentedCursorRow)
            }
            dirtyRows.insert(cursorRow)
        }
        let damage = TerminalDamage(
            rows: dirtyRows,
            full: fullDamage,
            cursorOnly: !fullDamage && contentEmpty && cursorMoved
        )
        contentDamage = IndexSet()
        fullDamage = false
        lastPresentedCursorRow = cursorRow
        return damage
    }

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
        // The image overlays the rows it covers from the current cursor row down.
        markRowsDirty(cursorRow ..< (cursorRow + fRows))
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
        markRowDirty(cursorRow)   // cursor shape/blink changed → repaint its row
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
        markRowDirty(cursorRow)   // the prompt gutter stripe appears on this row
    }

    /// OSC 133;D[;exit] — record the finished command's exit status onto the most recent prompt
    /// line at or above the cursor. Scans backward (viewport, then history) and stops at the
    /// first prompt mark — the active command's prompt — so the exit lands where the gutter
    /// indicator is drawn. A no-op when no prompt has been marked.
    func markCommandFinished(exit: Int?) {
        // Viewport rows above (and including) the cursor, newest first.
        var r = min(cursorRow, rowMarks.count - 1)
        while r >= 0 {
            if rowMarks[r] != nil { rowMarks[r]?.exit = exit; markRowDirty(r); return }
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

        // A soft-wrapped row continues onto the next; its cells are logical content and are NOT
        // trailing-trimmed — EXCEPT the single wide-deferral gap (the blank left when a wide glyph
        // was pushed to the next row), which is wrap padding. Dropping only that gap makes a joined
        // wide-char line read seamlessly at any width while preserving ECH/EL-erased trailing blanks
        // (real content). Only the hard-ended row gets the whole-line trailing trim.
        var out: [String] = []
        var current = ""
        var building = false
        for (idx, row) in phys.enumerated() {
            let drop = row.wrapped ? wideDeferralGap(row: row.cells, next: idx + 1 < phys.count ? phys[idx + 1].cells : nil) : 0
            let cells = drop > 0 ? Array(row.cells.dropLast(drop)) : row.cells
            current += text(cells, trimTrailing: !row.wrapped)
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
    func resize(cols newCols: Int, rows newRows: Int, forceFullReflow: Bool = false) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        guard nc != cols || nr != rows else { return }

        if recordsHistory {
            if !forceFullReflow, nc == cols, nr != rows {
                // Width-unchanged fast path: no row's wrap can change, so a full O(history) reflow is
                // pure waste (a vertical window drag, or a sidebar that only changes the row count).
                // Move just the history↔viewport boundary — O(|Δrows| + trailing-blank rows), not
                // O(history). `forceFullReflow` (tests) routes the same change through the general
                // path; `ReflowFastPathTests` proves the two are byte-identical.
                resizeHeightOnly(toRows: nr)
            } else {
                // The primary screen reflows; image anchors are re-mapped onto their logical line so
                // they survive the geometry change (see `reflow`).
                reflow(toCols: nc, rows: nr)
            }
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
        markFullyDirty()        // geometry/reflow rebuilds every row
    }

    /// True when a cell is the default blank (no glyph, default bg, no attributes) — used to
    /// trim trailing padding so reflow doesn't manufacture spurious blank rows.
    private func isBlank(_ cell: TerminalGridCell) -> Bool { cell == .blank }

    /// How many trailing cells of a soft-wrapped row are wrap *padding* (0 or 1), to drop when
    /// re-joining the logical line. The ONLY padding a soft wrap produces is the single gap left
    /// when a wide glyph couldn't fit the right margin and was deferred to the next row (`wrapLine`)
    /// — identified by the next physical row beginning with that deferred `.wide` head. A trailing
    /// blank NOT followed by a wide head is real content (e.g. an ECH/EL erasure, which leaves the
    /// row soft-wrapped) and MUST be preserved, or reflow/capture would shift content left. `next`
    /// is the following physical row (nil if this is the last row).
    private func wideDeferralGap(row: [TerminalGridCell], next: [TerminalGridCell]?) -> Int {
        guard let next, let last = row.last, isBlank(last) else { return 0 }
        for cell in next where cell.width != .spacerTail { return cell.width == .wide ? 1 : 0 }
        return 0
    }

    /// Whether viewport row `r` (in the live `cells` grid) is entirely default-blank.
    private func isViewportRowBlank(_ r: Int) -> Bool {
        let base = r * cols
        for c in 0 ..< cols where !isBlank(cells[base + c]) { return false }
        return true
    }

    /// A copy of viewport row `r`'s cells from the live grid.
    private func viewportRowCells(_ r: Int) -> [TerminalGridCell] {
        Array(cells[r * cols ..< (r + 1) * cols])
    }

    /// Width-unchanged resize (the common vertical drag): re-home the history↔viewport boundary
    /// without re-wrapping. Because the width is unchanged every physical row keeps its exact cells
    /// and wrap flag — only the split between scrollback and the live viewport moves — so this is
    /// byte-identical to `reflow(toCols: cols, rows: nr)` (asserted by `ReflowFastPathTests` across
    /// cursor positions, history depths, content, grow and shrink) but costs O(|Δrows| + trailing
    /// blank rows) instead of O(history). Mirrors reflow step 5's trailing-blank trim, split, cap,
    /// cursor mapping, and image re-anchor for the identity-rewrap case.
    private func resizeHeightOnly(toRows nr: Int) {
        let oldRows = rows
        let historyCount = history.count
        let cursorViewportRow = min(cursorRow, oldRows - 1)
        let cursorAbs = historyCount + cursorViewportRow

        // 1) Drop trailing blank viewport rows *below* the cursor (no empty scrollback under the
        //    cursor). The trim stops at the cursor's row, which is in the viewport, so it never
        //    reaches into history.
        var surviving = oldRows
        while surviving > cursorViewportRow + 1, isViewportRowBlank(surviving - 1) { surviving -= 1 }
        let total = historyCount + surviving

        // 2) New viewport = the bottom `nr` rows of [history ++ surviving viewport]; `boundary` is
        //    the absolute index of its first row, everything above is scrollback.
        let boundary = max(0, total - nr)
        let blank = TerminalGridCell.blank

        // 3) Materialize the new viewport by reading rows [boundary, boundary+nr) from whichever side
        //    of the (old) boundary they live on, padding past `total` with blanks. Reads old state
        //    only; history is re-homed afterward.
        var newCells = [TerminalGridCell](); newCells.reserveCapacity(cols * nr)
        var newWrapped = [Bool](repeating: false, count: nr)
        var newMarks = [SemanticMark?](repeating: nil, count: nr)
        for slot in 0 ..< nr {
            let idx = boundary + slot
            if idx < total {
                if idx < historyCount {
                    let line = history[idx]
                    newCells.append(contentsOf: line.cells)
                    newWrapped[slot] = line.wrapped
                    newMarks[slot] = line.mark
                } else {
                    let r = idx - historyCount
                    newCells.append(contentsOf: viewportRowCells(r))
                    newWrapped[slot] = rowWrapped[r]
                    newMarks[slot] = rowMarks[r]
                }
            } else {
                newCells.append(contentsOf: repeatElement(blank, count: cols))
            }
        }

        // 4) Re-home history to [0 ..< boundary]: shrink pushes top viewport rows up; grow pulls the
        //    recent history tail down (already copied into the viewport above).
        if boundary > historyCount {
            for r in 0 ..< (boundary - historyCount) {
                history.append(HistoryLine(cells: viewportRowCells(r), wrapped: rowWrapped[r], mark: rowMarks[r]))
            }
        } else if boundary < historyCount {
            history.removeLast(historyCount - boundary)
        }
        // Scrollback cap, exactly as reflow applies it (drop oldest overflow).
        let trimmedFront = max(0, boundary - maxHistoryLines)
        if history.count > maxHistoryLines { history.removeFirst(history.count - maxHistoryLines) }

        cells = newCells
        rowWrapped = newWrapped
        rowMarks = newMarks
        rows = nr
        cursorRow = clamp(cursorAbs - boundary, 0, nr - 1)
        cursorCol = min(cursorCol, cols - 1)

        // 5) Re-anchor images by the same boundary shift (width unchanged → columns untouched);
        //    evict any whose row fell below the trimmed tail or off the front of capped scrollback.
        if !placements.isEmpty {
            for i in placements.indices {
                let src = placements[i].absRow
                let mapped = src - trimmedFront
                placements[i].absRow = (src >= 0 && src < total && mapped >= 0) ? mapped : -1
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

    /// Output of `rewrapRows`: the re-wrapped physical rows plus the bookkeeping `reflow` needs to
    /// split scrollback/viewport, re-anchor marks, re-home images, and map the cursor.
    private struct RewrapResult {
        var out: [[TerminalGridCell]]
        var wrapped: [Bool]
        var marks: [SemanticMark?]
        var logicalOf: [Int]            // source-row index → its logical line index
        var logicalFirstOutRow: [Int]   // logical line index → its first output row
        var cursorOutRow: Int
        var cursorOutCol: Int
    }

    /// Steps 2-4 of reflow, factored out so the authoritative `reflow` (whole buffer) and the live
    /// `previewViewportReflow` (visible suffix) wrap *identically*: join `srcRows` into logical lines
    /// (concatenating a row onto the previous when it soft-wrapped, dropping wide-deferral wrap
    /// padding), trim each logical line's trailing blanks (with a cursor floor), then re-wrap to
    /// width `nc` keeping wide glyphs whole and mapping the cursor. Reads only `cols`/`cursorCol`;
    /// mutates no `self` state.
    private func rewrapRows(
        _ srcRows: [(cells: [TerminalGridCell], wrapped: Bool)],
        marks srcMarks: [SemanticMark?],
        cursorAbsRow: Int,
        toCols nc: Int
    ) -> RewrapResult {
        // 2) Build logical lines by joining a row onto the previous when it soft-wrapped.
        var logicals: [[TerminalGridCell]] = []
        var logicalMarks: [SemanticMark?] = []
        var logicalOf = [Int](repeating: 0, count: srcRows.count)
        var current: [TerminalGridCell] = []
        var currentMark: SemanticMark? = nil
        var building = false
        var prevWrapped = false
        var cursorLogical = 0
        var cursorLogicalCol = 0
        for (i, row) in srcRows.enumerated() {
            if building, !prevWrapped {
                logicals.append(current)
                logicalMarks.append(currentMark)
                current = []
                currentMark = nil
            }
            if current.isEmpty { currentMark = srcMarks[i] }
            logicalOf[i] = logicals.count
            building = true
            if i == cursorAbsRow {
                cursorLogical = logicals.count
                cursorLogicalCol = current.count + min(cursorCol, cols - 1)
            }
            // Drop ONLY the genuine wide-deferral gap from a soft-wrapped row (the single blank left
            // when a wide glyph couldn't fit the margin and moved to the next row). Carrying that gap
            // into the logical line re-embeds a fresh gap on every reflow, so wide-char (CJK/emoji)
            // lines used to drift and corrupt across resizes. Crucially we do NOT trim other trailing
            // blanks: an ECH/EL erasure leaves the row soft-wrapped with real (intentional) blank
            // content that must survive. The final (hard-ended) row keeps its cells — step 3 does the
            // whole-logical-line trailing trim.
            if row.wrapped {
                let drop = wideDeferralGap(row: row.cells, next: i + 1 < srcRows.count ? srcRows[i + 1].cells : nil)
                current.append(contentsOf: row.cells[0 ..< (row.cells.count - drop)])
            } else {
                current.append(contentsOf: row.cells)
            }
            prevWrapped = row.wrapped
        }
        if building { logicals.append(current); logicalMarks.append(currentMark) }

        // 3) Trim each logical line's trailing blank cells (but never below the cursor column on the
        //    cursor's own line, so the cursor keeps its place). Empty lines are preserved.
        for i in logicals.indices {
            var end = logicals[i].count
            let floorCol = (i == cursorLogical) ? min(cursorLogicalCol, logicals[i].count) : 0
            while end > floorCol, isBlank(logicals[i][end - 1]) { end -= 1 }
            logicals[i] = Array(logicals[i].prefix(end))
        }
        cursorLogicalCol = min(cursorLogicalCol, logicals.indices.contains(cursorLogical) ? logicals[cursorLogical].count : 0)

        // 4) Re-wrap each logical line into rows of width `nc` (wide chars never split). Each logical
        //    line yields at least one row (preserving blank lines). Map the cursor.
        var out: [[TerminalGridCell]] = []
        var outWrapped: [Bool] = []
        var outMarks: [SemanticMark?] = []
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
                outMarks.append(firstRowOfLogical ? logicalMarks[li] : nil)
                firstRowOfLogical = false
                rowBuf = Array(repeating: blank, count: nc)
                col = 0
            }
            var k = 0
            while k < line.count {
                let cell = line[k]
                if cell.width == .spacerTail { k += 1; continue }
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
            if li == cursorLogical, cursorLogicalCol >= line.count {
                cursorOutRow = out.count
                cursorOutCol = min(col, nc - 1)
            }
            flush(soft: false)
        }

        return RewrapResult(
            out: out, wrapped: outWrapped, marks: outMarks,
            logicalOf: logicalOf, logicalFirstOutRow: logicalFirstOutRow,
            cursorOutRow: cursorOutRow, cursorOutCol: cursorOutCol
        )
    }

    /// Pure (non-mutating) preview of the primary-screen viewport after a hypothetical reflow to
    /// `nc × nr`, computed in O(visible content) by re-wrapping only the logical lines that land in
    /// the bottom `nr` rows. Drives live re-wrap during a resize drag while the authoritative
    /// history-wide reflow + PTY `SIGWINCH` are deferred. Byte-identical to the viewport that
    /// `reflow(toCols: nc, rows: nr)` would produce (proven by `ReflowPreviewTests`); touches no
    /// `self` state, so it is safe to call every drag frame. Primary screen only.
    func previewViewportReflow(toCols ncIn: Int, rows nrIn: Int)
        -> (cells: [TerminalGridCell], cursorRow: Int, cursorCol: Int) {
        let nc = max(1, ncIn)
        let nr = max(1, nrIn)
        let totalSrc = history.count + rows
        let cursorAbsFull = history.count + min(cursorRow, rows - 1)
        let blank = TerminalGridCell.blank

        func sourceRow(_ i: Int) -> (cells: [TerminalGridCell], wrapped: Bool, mark: SemanticMark?) {
            if i < history.count {
                let h = history[i]
                return (h.cells, h.wrapped, h.mark)
            }
            let r = i - history.count
            return (viewportRowCells(r), rowWrapped[r], rowMarks[r])
        }

        // Gather a suffix [start, totalSrc) that begins at a hard-line boundary (so its first logical
        // line is complete) and re-wraps to at least `nr` rows. Extend back by doubling chunks until
        // satisfied or the whole buffer is included. Because output rows below `start` are determined
        // solely by complete logical lines inside the suffix, the last `nr` rows — and the viewport-
        // relative cursor — match the full reflow exactly. Bounded by visible content.
        var start = totalSrc
        var chunk = max(nr, 8)
        while true {
            start = max(0, start - chunk)
            while start > 0, sourceRow(start - 1).wrapped { start -= 1 } // back up to a hard boundary
            var rows2: [(cells: [TerminalGridCell], wrapped: Bool)] = []
            var marks2: [SemanticMark?] = []
            rows2.reserveCapacity(totalSrc - start)
            for i in start ..< totalSrc {
                let s = sourceRow(i)
                rows2.append((s.cells, s.wrapped))
                marks2.append(s.mark)
            }
            let result = rewrapRows(rows2, marks: marks2, cursorAbsRow: cursorAbsFull - start, toCols: nc)
            var total = result.out.count
            while total - 1 > result.cursorOutRow, isRowBlank(result.out[total - 1]) { total -= 1 }
            if total >= nr || start == 0 {
                let viewportTop = max(0, total - nr)
                var cellsOut = [TerminalGridCell]()
                cellsOut.reserveCapacity(nc * nr)
                for r in 0 ..< nr {
                    let idx = viewportTop + r
                    if idx < total { cellsOut.append(contentsOf: result.out[idx]) }
                    else { cellsOut.append(contentsOf: repeatElement(blank, count: nc)) }
                }
                return (cellsOut,
                        clamp(result.cursorOutRow - viewportTop, 0, nr - 1),
                        clamp(result.cursorOutCol, 0, nc - 1))
            }
            chunk *= 2
        }
    }

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

        // 2-4) Join soft-wrapped rows into logical lines, trim, and re-wrap to `nc`. Shared with
        //      `previewViewportReflow` so the live drag preview wraps byte-identically.
        let rw = rewrapRows(srcRows, marks: srcMarks, cursorAbsRow: cursorAbsRow, toCols: nc)
        var out = rw.out
        var outWrapped = rw.wrapped
        var outMarks = rw.marks
        let logicalOf = rw.logicalOf
        let logicalFirstOutRow = rw.logicalFirstOutRow
        let cursorOutRow = rw.cursorOutRow
        let cursorOutCol = rw.cursorOutCol
        let blank = TerminalGridCell.blank

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

        history = HistoryRingBuffer(newHistory)
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
        } else if w == 2, cursorCol >= cols - 1, autowrap {
            // A wide glyph that can't fit the last column wraps — but only with DECAWM on.
            // With autowrap off (`\e[?7l`) the VT220 behavior is to write the left half at the
            // margin and pin the cursor there (truncate), never scroll; `advance(by: 2)` clamps.
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

    /// Write a run of printable ASCII bytes (each `0x20...0x7E`, always width 1, never combining)
    /// at the cursor. Byte-for-byte equivalent to `print(UInt32(b))` for each `b`, but batched per
    /// row: the cell template (pen + hyperlink, constant across a run with no embedded escapes) is
    /// built once and only the codepoint varies, and a row's columns are filled in a tight loop.
    /// Pending-wrap, autowrap on/off, the scroll region, and soft-wrap flags are honored exactly as
    /// the scalar path does.
    func printASCIIRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        let n = bytes.count
        guard n > 0 else { return }
        var template = makeCell(0, width: .normal)
        var i = 0
        while i < n {
            // Mirror `print`'s leading pending-wrap check (may scroll and move the cursor row).
            if pendingWrap { wrapLine() }
            guard cursorRow >= 0, cursorRow < rows else {
                // Defensive: matches `writeCell`'s bounds guard. Shouldn't happen; finish on the
                // scalar path rather than risk an out-of-range write.
                while i < n { print(UInt32(bytes[i])); i += 1 }
                return
            }
            let rowBase = cursorRow * cols
            if cursorCol < cols - 1 {
                // Fill distinct columns cursorCol..<endCol on this row (endCol <= cols) via the
                // raw buffer to drop the per-store bounds check on this tight inner loop. (Only the
                // fill is wrapped — `wrapLine`/`scrollUp` above open their own mutable-buffer scope,
                // so they must stay outside this one to preserve exclusive access.)
                let endCol = Swift.min(cols, cursorCol + (n - i))
                cells.withUnsafeMutableBufferPointer { buf in
                    let base = buf.baseAddress!
                    var c = cursorCol
                    while c < endCol {
                        template.codepoint = UInt32(bytes[i])
                        base[rowBase + c] = template
                        i += 1
                        c += 1
                    }
                }
                // Mirror `advance(by: 1)` for the last byte written.
                if endCol >= cols {
                    cursorCol = cols - 1
                    pendingWrap = autowrap
                } else {
                    cursorCol = endCol
                    pendingWrap = false
                }
            } else {
                // Cursor pinned at the last column. Write one byte; `advance` keeps the cursor here
                // and arms pendingWrap with autowrap. With autowrap off the cursor stays and every
                // further byte overwrites the last column, so only the run's final byte survives.
                template.codepoint = UInt32(bytes[i])
                cells[rowBase + cols - 1] = template
                i += 1
                pendingWrap = autowrap
                if !autowrap, i < n {
                    template.codepoint = UInt32(bytes[n - 1])
                    cells[rowBase + cols - 1] = template
                    i = n
                }
            }
            // The direct cell writes above bypass `writeCell`, so mark the row we just wrote
            // dirty for incremental frame rebuild. (The scalar fallback marks via `writeCell`;
            // `wrapLine`/`scrollUp` already mark the rows they touch.)
            markRowDirty(cursorRow)
        }
    }

    /// Write a run of already-decoded printable scalars (ASCII + UTF-8) at the cursor. Byte-for-byte
    /// equivalent to `print(cp)` for each `cp`, but batched: the cell template (pen + hyperlink, both
    /// constant across a run with no embedded escapes) is built once, and each row touched is marked
    /// dirty once instead of per cell. Per-scalar width, zero-width (combining) drop, wide-head +
    /// `spacerTail`, pending-wrap, autowrap on/off, and the wide-at-right-margin wrap are handled
    /// exactly as `print` does. `CodepointRunFastPathTests` proves the equivalence (incl. chunk
    /// splits); only the ASCII charset reaches here (DEC special graphics replays scalar-wise).
    func printCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        let n = codepoints.count
        guard n > 0 else { return }
        var template = makeCell(0, width: .normal)
        var lastMarkedRow = -1
        var i = 0
        while i < n {
            let scalar = codepoints[i]
            i += 1
            let w = CharacterWidth.width(of: scalar)
            // Zero-width (combining marks etc.): attach to the previous glyph; never advance the
            // cursor — identical to `print`'s `w == 0` early return.
            if w == 0 { continue }
            // A glyph that cannot fit the remaining columns wraps first (mirrors `print`).
            if pendingWrap {
                wrapLine()
            } else if w == 2, cursorCol >= cols - 1, autowrap {
                wrapLine()
            }
            // Defensive bounds guard, matching `writeCell` / `printASCIIRun`.
            guard cursorRow >= 0, cursorRow < rows else { return }
            let rowBase = cursorRow * cols
            let writeRow = cursorRow
            if w == 2 {
                template.codepoint = scalar
                template.width = .wide
                cells[rowBase + cursorCol] = template
                if cursorCol + 1 < cols {
                    template.codepoint = 0
                    template.width = .spacerTail
                    cells[rowBase + cursorCol + 1] = template
                }
                advance(by: 2)
            } else {
                template.codepoint = scalar
                template.width = .normal
                cells[rowBase + cursorCol] = template
                advance(by: 1)
            }
            // Mark each row we wrote dirty exactly once (the direct writes above bypass `writeCell`);
            // the dirty set is identical to the per-cell scalar path, which marks the same rows.
            if writeRow != lastMarkedRow {
                markRowDirty(writeRow)
                lastMarkedRow = writeRow
            }
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
        markRowDirty(cursorRow)
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
        markRowDirty(cursorRow)
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
        // Clamp to the region height: once every line in the region has scrolled off the
        // region is blank, so a giant SU (`\e[65535S`) past that point is pure wasted work
        // (and a hostile-output DoS — the inner shift is O(cols × region)). The clamped count
        // also keeps `shiftPlacements` correct (images are gone after region-height scrolls).
        let count = min(max(1, n), scrollBottom - scrollTop + 1)
        let blank = erasedCell()
        // A full-screen scroll (top of the screen, history on) accrues scrollback: image anchors
        // are invariant because `history.count` grows in step, so they ride into scrollback rather
        // than being dropped. A region/alternate scroll moves content without history, so anchors
        // shift (handled after the loop).
        let growsHistory = recordsHistory && scrollTop == 0
        let regionRows = scrollBottom - scrollTop + 1
        let survivors = regionRows - count   // region rows that remain after the top `count` leave

        // The `count` lines leaving the top of the screen (not a sub-region) become scrollback,
        // oldest first — carry each soft-wrap flag so reflow can re-join with its continuation.
        if growsHistory {
            for k in 0 ..< count {
                let r = scrollTop + k
                history.append(HistoryLine(cells: Array(cells[r * cols ..< (r + 1) * cols]),
                                           wrapped: rowWrapped[r], mark: rowMarks[r]))
            }
            // `removeFirst` is O(history.count) — trimming every scrolled line would make a
            // terminal at full scrollback pay O(maxHistoryLines) per output line. Amortize: let the
            // buffer overshoot by a bounded slack, then trim back to the cap in one batch (≈O(1)
            // amortized). Readers clamp to `history.count`, so the transient margin just exposes a
            // little extra scrollback — never less than configured. Slack is 0 when scrollback is off.
            let slack = min(1024, maxHistoryLines / 4)
            if history.count > maxHistoryLines + slack {
                dropHistoryHead(history.count - maxHistoryLines)
            }
        }

        // Shift the surviving region up by `count` rows in one contiguous block move, then blank the
        // freed bottom rows. `TerminalGridCell` is a trivial value type (no refs), so `memmove` over
        // the overlapping cell band is safe and replaces the old O(count × region × cols) cell loop.
        cells.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            if survivors > 0 {
                memmove(base + scrollTop * cols,
                        base + (scrollTop + count) * cols,
                        survivors * cols * MemoryLayout<TerminalGridCell>.stride)
            }
            (base + (scrollTop + survivors) * cols).update(repeating: blank, count: count * cols)
        }
        if survivors > 0 {
            for r in scrollTop ..< (scrollTop + survivors) {
                rowWrapped[r] = rowWrapped[r + count]
                rowMarks[r] = rowMarks[r + count]
            }
        }
        for r in (scrollTop + survivors) ... scrollBottom {
            rowWrapped[r] = false
            rowMarks[r] = nil
        }
        markRowsDirty(scrollTop ... scrollBottom)
        // Only region/alternate scrolls move anchors; a history-growing scroll leaves them
        // invariant (the image scrolls into scrollback instead of being dropped).
        if !growsHistory { shiftPlacements(by: -count) }
    }

    func scrollDown(_ n: Int) {
        // Clamp to region height for the same reason as `scrollUp` — beyond it the region is
        // already blank, so a giant SD is wasted O(cols × region) work per extra iteration.
        let count = min(max(1, n), scrollBottom - scrollTop + 1)
        let blank = erasedCell()
        let regionRows = scrollBottom - scrollTop + 1
        let survivors = regionRows - count

        // Shift the surviving region down by `count` rows in one block move (memmove handles the
        // overlap; `TerminalGridCell` is trivial), then blank the freed top rows.
        cells.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            if survivors > 0 {
                memmove(base + (scrollTop + count) * cols,
                        base + scrollTop * cols,
                        survivors * cols * MemoryLayout<TerminalGridCell>.stride)
            }
            (base + scrollTop * cols).update(repeating: blank, count: count * cols)
        }
        if survivors > 0 {
            var r = scrollBottom
            while r >= scrollTop + count {
                rowWrapped[r] = rowWrapped[r - count]
                rowMarks[r] = rowMarks[r - count]
                r -= 1
            }
        }
        for r in scrollTop ..< (scrollTop + count) {
            rowWrapped[r] = false
            rowMarks[r] = nil
        }
        markRowsDirty(scrollTop ... scrollBottom)
        shiftPlacements(by: count)
    }

    // MARK: - Erase / edit

    /// A cleared cell carrying the current background (terminals erase with the active
    /// background color but no glyph/foreground attributes).
    private func erasedCell() -> TerminalGridCell {
        TerminalGridCell(background: pen.background)
    }

    /// Fill a contiguous run of cells `[start, start + count)` with `cell` via a single
    /// vectorizable bulk write instead of a per-cell loop. `count <= 0` is a no-op.
    private func fillCells(_ start: Int, _ count: Int, with cell: TerminalGridCell) {
        guard count > 0 else { return }
        cells.withUnsafeMutableBufferPointer { buf in
            (buf.baseAddress! + start).update(repeating: cell, count: count)
        }
    }

    /// Block-move `count` cells from index `src` to index `dst` in one overlap-safe `memmove`,
    /// replacing a per-cell shift loop. `TerminalGridCell` is a trivial value type (no refs — the
    /// layout test enforces it), so `memmove` over an overlapping band is correct; this is the same
    /// primitive `scrollUp`/`scrollDown` use. `count <= 0` is a no-op.
    private func moveCells(dst: Int, src: Int, count: Int) {
        guard count > 0 else { return }
        cells.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            memmove(base + dst, base + src, count * MemoryLayout<TerminalGridCell>.stride)
        }
    }

    /// ED — erase in display. mode 0: cursor→end, 1: start→cursor, 2/3: all. Cleared full rows
    /// no longer continue a wrapped line, so their soft-wrap flags reset.
    func eraseInDisplay(mode: Int) {
        let blank = erasedCell()
        switch mode {
        case 1:
            // Full rows above the cursor, then the cursor row up to and including the cursor.
            fillCells(0, cursorRow * cols, with: blank)
            for r in 0 ..< cursorRow { rowWrapped[r] = false; rowMarks[r] = nil }
            fillCells(cursorRow * cols, min(cursorCol + 1, cols), with: blank)
            markRowsDirty(0 ... cursorRow)
        case 2, 3:
            fillCells(0, cells.count, with: blank)
            for r in 0 ..< rows { rowWrapped[r] = false; rowMarks[r] = nil }
            clearImages()   // ED 2/3 clears the screen (and scrollback for 3) → drop images
            if mode == 3 { history.removeAll() }
            markFullyDirty()
        default: // 0
            // Cursor → end of its row, then every full row below in one bulk fill.
            fillCells(cursorRow * cols + cursorCol, cols - cursorCol, with: blank)
            rowWrapped[cursorRow] = false
            fillCells((cursorRow + 1) * cols, (rows - cursorRow - 1) * cols, with: blank)
            for r in (cursorRow + 1) ..< rows { rowWrapped[r] = false; rowMarks[r] = nil }
            markRowsDirty(cursorRow ..< rows)
        }
        pendingWrap = false
    }

    /// EL — erase in line. mode 0: cursor→end, 1: start→cursor, 2: whole line. Erasing to the
    /// end of the line (0 or 2) clears its soft-wrap continuation.
    func eraseInLine(mode: Int) {
        let blank = erasedCell()
        let rowStart = cursorRow * cols
        switch mode {
        case 1:
            fillCells(rowStart, min(cursorCol + 1, cols), with: blank)
        case 2:
            fillCells(rowStart, cols, with: blank)
            rowWrapped[cursorRow] = false
            rowMarks[cursorRow] = nil   // whole line cleared → no longer a prompt
        default:
            fillCells(rowStart + cursorCol, cols - cursorCol, with: blank)
            rowWrapped[cursorRow] = false
        }
        markRowDirty(cursorRow)
        pendingWrap = false
    }

    /// ICH — insert `n` blank cells at the cursor, shifting the rest of the line right.
    func insertCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        let rowStart = cursorRow * cols
        // Shift the surviving tail `[cursorCol, cols - count)` right by `count` in one block move,
        // then blank the `count` cells opened at the cursor.
        moveCells(dst: rowStart + cursorCol + count, src: rowStart + cursorCol, count: cols - cursorCol - count)
        fillCells(rowStart + cursorCol, count, with: erasedCell())
        markRowDirty(cursorRow)
        pendingWrap = false
    }

    /// DCH — delete `n` cells at the cursor, shifting the rest of the line left.
    func deleteCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        let rowStart = cursorRow * cols
        // Shift the surviving tail `[cursorCol + count, cols)` left by `count` in one block move,
        // then blank the `count` cells freed at the end of the line.
        moveCells(dst: rowStart + cursorCol, src: rowStart + cursorCol + count, count: cols - cursorCol - count)
        fillCells(rowStart + cols - count, count, with: erasedCell())
        markRowDirty(cursorRow)
        pendingWrap = false
    }

    /// ECH — erase `n` cells at the cursor in place (no shifting).
    func eraseCharacters(_ n: Int) {
        let count = clamp(n, 1, cols - cursorCol)
        // Bulk fill via `fillCells` (vectorized `update(repeating:)`) instead of a scalar per-cell
        // loop — the last edit primitive that still looped. Byte-identical (ECH fills with the
        // background-colored `erasedCell`).
        fillCells(cursorRow * cols + cursorCol, count, with: erasedCell())
        markRowDirty(cursorRow)
    }

    /// IL — insert `n` blank lines at the cursor row, within the scroll region.
    func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = clamp(n, 1, scrollBottom - cursorRow + 1)
        let survivors = scrollBottom - cursorRow + 1 - count   // rows pushed down (kept)
        if survivors > 0 {
            // Shift the surviving rows `[cursorRow, scrollBottom - count]` down by `count` in one
            // block move; their parallel wrap/mark flags shift alongside (top-down, dst > src).
            moveCells(dst: (cursorRow + count) * cols, src: cursorRow * cols, count: survivors * cols)
            var r = scrollBottom
            while r >= cursorRow + count {
                rowWrapped[r] = rowWrapped[r - count]
                rowMarks[r] = rowMarks[r - count]
                r -= 1
            }
        }
        // Blank the `count` inserted rows at the cursor in one bulk fill.
        fillCells(cursorRow * cols, count * cols, with: erasedCell())
        for r in cursorRow ..< (cursorRow + count) { rowWrapped[r] = false; rowMarks[r] = nil }
        markRowsDirty(cursorRow ... scrollBottom)
        pendingWrap = false
    }

    /// DL — delete `n` lines at the cursor row, within the scroll region.
    func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = clamp(n, 1, scrollBottom - cursorRow + 1)
        let survivors = scrollBottom - cursorRow + 1 - count   // rows pulled up (kept)
        if survivors > 0 {
            // Shift the surviving rows `[cursorRow + count, scrollBottom]` up by `count` in one
            // block move; their parallel wrap/mark flags shift alongside (bottom-up, dst < src).
            moveCells(dst: cursorRow * cols, src: (cursorRow + count) * cols, count: survivors * cols)
            var r = cursorRow
            while r + count <= scrollBottom {
                rowWrapped[r] = rowWrapped[r + count]
                rowMarks[r] = rowMarks[r + count]
                r += 1
            }
        }
        // Blank the `count` rows freed at the bottom of the region in one bulk fill.
        let blankTop = scrollBottom - count + 1
        fillCells(blankTop * cols, count * cols, with: erasedCell())
        for r in blankTop ... scrollBottom { rowWrapped[r] = false; rowMarks[r] = nil }
        markRowsDirty(cursorRow ... scrollBottom)
        pendingWrap = false
    }

    // MARK: - SGR (graphic rendition)

    func resetPen() { pen = Pen() }

    /// Apply decoded SGR parameter groups to the pen. Each group is one semicolon-separated
    /// parameter with its colon sub-parameters. Handles all standard attribute toggles,
    /// 16/256/truecolor for fg (38), bg (48), and underline color (58) in BOTH the
    /// semicolon form (`38;5;n`, `38;2;r;g;b`) and the colon form (`38:5:n`, `38:2::r:g:b`),
    /// and `4:N` underline styles (curly/dotted/dashed).
    func applySGR(_ params: CSIParams) {
        guard params.count > 0 else { resetPen(); return }
        var i = 0
        while i < params.count {
            let code = params.first(i)
            if params.subCount(i) > 1 {
                // Colon sub-parameter form: the whole spec lives in this one group.
                switch code {
                case 4: pen.underline = Self.underlineStyle(params.sub(i, 1))
                case 38: if let c = Self.colonColor(params, i) { pen.foreground = c }
                case 48: if let c = Self.colonColor(params, i) { pen.background = c }
                case 58: if let c = Self.colonColor(params, i) { pen.underlineColor = c }
                default: applySingleCode(code)
                }
                i += 1
            } else {
                switch code {
                case 38:
                    if let (c, used) = Self.semicolonColor(params, from: i) { pen.foreground = c; i += used } else { i += 1 }
                case 48:
                    if let (c, used) = Self.semicolonColor(params, from: i) { pen.background = c; i += used } else { i += 1 }
                case 58:
                    if let (c, used) = Self.semicolonColor(params, from: i) { pen.underlineColor = c; i += used } else { i += 1 }
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
        case 30 ... 37: pen.foreground = .palette(UInt8(code - 30))
        case 39: pen.foreground = .none
        case 40 ... 47: pen.background = .palette(UInt8(code - 40))
        case 49: pen.background = .none
        case 53: pen.overline = true
        case 55: pen.overline = false
        case 59: pen.underlineColor = .none
        case 90 ... 97: pen.foreground = .palette(UInt8(code - 90 + 8))
        case 100 ... 107: pen.background = .palette(UInt8(code - 100 + 8))
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

    /// Colon form within one group `g`: `[38, 5, n]` palette, `[38, 2, r, g, b]` or
    /// `[38, 2, colorspace, r, g, b]` truecolor.
    private static func colonColor(_ params: CSIParams, _ g: Int) -> TerminalGridColor? {
        let n = params.subCount(g)
        guard n >= 2 else { return nil }
        switch params.sub(g, 1) {
        case 5:
            guard n >= 3 else { return nil }
            return .palette(clampByte(params.sub(g, 2)))
        case 2:
            if n >= 6 {
                return .rgb(r: clampByte(params.sub(g, 3)), g: clampByte(params.sub(g, 4)), b: clampByte(params.sub(g, 5)))
            } else if n >= 5 {
                return .rgb(r: clampByte(params.sub(g, 2)), g: clampByte(params.sub(g, 3)), b: clampByte(params.sub(g, 4)))
            }
            return nil
        default:
            return nil
        }
    }

    /// Semicolon form across groups: `38;5;n` or `38;2;r;g;b`. Returns the color and how
    /// many groups it consumed (including the `38`/`48`/`58` lead group).
    private static func semicolonColor(_ params: CSIParams, from base: Int) -> (TerminalGridColor, Int)? {
        guard base + 1 < params.count else { return nil }
        switch params.first(base + 1) {
        case 5:
            guard base + 2 < params.count else { return nil }
            return (.palette(clampByte(params.first(base + 2))), 3)
        case 2:
            guard base + 4 < params.count else { return nil }
            let r = clampByte(params.first(base + 2))
            let g = clampByte(params.first(base + 3))
            let b = clampByte(params.first(base + 4))
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
        markFullyDirty()
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
