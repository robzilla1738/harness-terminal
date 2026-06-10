import Foundation
import HarnessCore

/// A position in virtual line space (`[scrollback ++ viewport]`): a virtual line index and
/// a grid column. Ordered in reading order so selection endpoints normalize with `min`/`max`.
public struct GridPosition: Equatable, Sendable, Comparable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (a: GridPosition, b: GridPosition) -> Bool {
        (a.line, a.column) < (b.line, b.column)
    }
}

/// Copy-mode selection shape — matches tmux's char (`v`), line (`V`), and rectangle
/// (`C-v`) modes, plus `none` (cursor only, no highlight).
public enum CopyModeSelectionMode: Equatable, Sendable { case none, char, line, block }

/// One search hit: a half-open grid-column span `[startColumn, endColumn)` on a virtual line.
public struct CopyModeMatch: Equatable, Sendable {
    public var line: Int
    public var startColumn: Int
    public var endColumn: Int

    public init(line: Int, startColumn: Int, endColumn: Int) {
        self.line = line
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

/// Search state: the query, **every** match across the buffer (not just the next one, so the
/// overlay can highlight them all), the current match index, and the search direction.
public struct CopyModeSearch: Equatable, Sendable {
    public var query: String = ""
    public var matches: [CopyModeMatch] = []
    public var currentIndex: Int?
    public var reverse: Bool = false

    public init() {}
}

/// The intent a reducer step produces. The reducer NEVER performs I/O (no pasteboard, no
/// process, no daemon call) — it returns one of these and the front-end carries it out. This
/// is what lets the GUI overlay and the ssh compositor share one reducer: only the thin I/O
/// tail differs per surface.
public enum CopyModeSideEffect: Equatable, Sendable {
    case none
    /// Copy this text (clipboard + paste buffer); stay in copy mode.
    case copy(String)
    /// Copy this text, then exit copy mode. Empty text just exits.
    case copyAndCancel(String)
    /// Pipe this text to a shell command's stdin, then exit (tmux `copy-pipe`).
    case pipe(text: String, command: String)
    /// Paste the most-recent buffer into the pane, then exit.
    case paste
    /// Exit copy mode.
    case cancel
    /// Open the front-end's search input (interactive query entry); `reverse` is the direction.
    case beginSearchEntry(reverse: Bool)
    /// Capture the next single keystroke as the target of a jump-to-char motion (`f`/`F`/`t`/`T`),
    /// then re-issue `.jump(kind, "<char>")`. The front-end owns the one-key capture.
    case beginJumpEntry(CopyModeJumpKind)
}

/// The full copy-mode model: cursor + selection in virtual coordinates, the visible-window
/// top, and search state. A pure value type — `CopyModeReducer` evolves it; front-ends render
/// it. No platform types, so it is exhaustively unit-testable.
public struct CopyModeState: Equatable, Sendable {
    /// Cursor in virtual coordinates (line in `[0, totalLines)`, grid column).
    public var cursor: GridPosition
    /// Selection anchor (nil when there is no active selection).
    public var anchor: GridPosition?
    public var mode: CopyModeSelectionMode
    /// Virtual line index shown at the top of the rendered viewport.
    public var viewTop: Int
    public var search: CopyModeSearch
    /// The last jump-to-char performed, so `jump-again` (`;`) / `jump-reverse` (`,`) can repeat it.
    public var lastJump: CopyModeJump?

    public init(
        cursor: GridPosition,
        anchor: GridPosition? = nil,
        mode: CopyModeSelectionMode = .none,
        viewTop: Int = 0,
        search: CopyModeSearch = CopyModeSearch(),
        lastJump: CopyModeJump? = nil
    ) {
        self.cursor = cursor
        self.anchor = anchor
        self.mode = mode
        self.viewTop = viewTop
        self.search = search
        self.lastJump = lastJump
    }

    /// tmux-style mode label for the status indicator.
    public var modeName: String {
        switch mode {
        case .none: return "NORMAL"
        case .char: return "VISUAL"
        case .line: return "V-LINE"
        case .block: return "V-BLOCK"
        }
    }

    public var hasSelection: Bool { mode != .none && anchor != nil }

    /// A one-line status string: mode, cursor position (1-based), and match progress.
    public func statusLine() -> String {
        var s = "-- \(modeName) --  \(cursor.line + 1):\(cursor.column + 1)"
        if !search.matches.isEmpty {
            let n = (search.currentIndex ?? 0) + 1
            s += "  ·  \(n)/\(search.matches.count)"
        }
        return s
    }

    // MARK: Render projection

    /// The scrollback offset a front-end renders at so `viewTop` is the top viewport row.
    /// (`snapshot(scrollbackOffset: off)` shows virtual rows `[historyCount - off …]`.)
    public func scrollbackOffset(historyCount: Int) -> Int {
        max(0, historyCount - viewTop)
    }

    /// The copy-mode cursor in viewport coordinates, or nil when scrolled out of view.
    public func viewportCursor(rows: Int) -> (row: Int, column: Int)? {
        let row = cursor.line - viewTop
        guard row >= 0, row < rows else { return nil }
        return (row, cursor.column)
    }

    /// The selection projected into viewport rows (`viewTop`-relative). Rows above/below the
    /// viewport stay out of range and the renderer clips them. `columns` sizes line selection.
    public func viewportSelection(rows: Int, columns: Int) -> CopyModeViewportSelection? {
        guard mode != .none, let anchor else { return nil }
        switch mode {
        case .char:
            let lo = Swift.min(anchor, cursor), hi = Swift.max(anchor, cursor)
            return CopyModeViewportSelection(
                kind: .linear,
                startRow: lo.line - viewTop, startColumn: lo.column,
                endRow: hi.line - viewTop, endColumn: hi.column
            )
        case .line:
            let r0 = Swift.min(anchor.line, cursor.line) - viewTop
            let r1 = Swift.max(anchor.line, cursor.line) - viewTop
            return CopyModeViewportSelection(
                kind: .linear,
                startRow: r0, startColumn: 0, endRow: r1, endColumn: max(0, columns - 1)
            )
        case .block:
            let r0 = Swift.min(anchor.line, cursor.line) - viewTop
            let r1 = Swift.max(anchor.line, cursor.line) - viewTop
            let c0 = Swift.min(anchor.column, cursor.column)
            let c1 = Swift.max(anchor.column, cursor.column)
            return CopyModeViewportSelection(
                kind: .block, startRow: r0, startColumn: c0, endRow: r1, endColumn: c1
            )
        case .none:
            return nil
        }
    }

    /// Search hits that fall within the rendered viewport, with `line` rebased to a viewport
    /// row. The overlay highlights all of these; the current match also carries the cursor.
    public func viewportSearchHits(rows: Int) -> [CopyModeMatch] {
        search.matches.compactMap { m in
            let row = m.line - viewTop
            guard row >= 0, row < rows else { return nil }
            return CopyModeMatch(line: row, startColumn: m.startColumn, endColumn: m.endColumn)
        }
    }
}

/// A selection projected into viewport coordinates, renderer-agnostic. The front-end maps
/// `.linear` → the renderer's line-wrapping selection and `.block` → its rectangle selection.
public struct CopyModeViewportSelection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case linear, block }
    public var kind: Kind
    /// Inclusive cell bounds in viewport rows/columns.
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    public init(kind: Kind, startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        self.kind = kind
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
    }

    /// Whether a viewport cell is selected. `linear` includes full intermediate rows; `block`
    /// is the row × column rectangle.
    public func contains(row: Int, column: Int) -> Bool {
        switch kind {
        case .block:
            return row >= startRow && row <= endRow && column >= startColumn && column <= endColumn
        case .linear:
            if row < startRow || row > endRow { return false }
            if startRow == endRow { return column >= startColumn && column <= endColumn }
            if row == startRow { return column >= startColumn }
            if row == endRow { return column <= endColumn }
            return true
        }
    }
}
