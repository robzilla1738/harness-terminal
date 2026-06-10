import Foundation
import HarnessCore

/// The single, UI-agnostic copy-mode engine. It evolves a `CopyModeState` in response to
/// `CopyModeAction`s (tmux's `copy-mode -X` vocabulary), reading the grid through a
/// `CopyModeGridSource`. It is **pure**: it returns a new state plus a `CopyModeSideEffect`
/// describing intent, and never touches a pasteboard, a process, or the daemon — so the GUI
/// overlay and the ssh compositor share exactly this one implementation.
public enum CopyModeReducer {
    // MARK: Entry

    /// The state when copy mode opens: cursor at the given live position (default: the
    /// bottom-left of the live viewport), window pinned to the bottom.
    public static func initialState(
        grid: CopyModeGridSource,
        cursorLine: Int? = nil,
        cursorColumn: Int = 0
    ) -> CopyModeState {
        let total = max(1, grid.totalLines)
        let rows = max(1, grid.viewportRows)
        let line = min(max(0, cursorLine ?? (total - 1)), total - 1)
        let state = CopyModeState(
            cursor: GridPosition(line: line, column: max(0, cursorColumn)),
            viewTop: max(0, total - rows)
        )
        return reveal(state, grid: grid)
    }

    // MARK: Reduce

    public static func reduce(
        _ state: CopyModeState,
        _ action: CopyModeAction,
        grid: CopyModeGridSource
    ) -> (state: CopyModeState, effect: CopyModeSideEffect) {
        var s = state
        switch action {
        case .cursorLeft: s.cursor.column = max(0, s.cursor.column - 1)
        case .cursorRight: s.cursor.column = min(maxColumn(grid), s.cursor.column + 1)
        case .cursorUp: s.cursor.line = max(0, s.cursor.line - 1)
        case .cursorDown: s.cursor.line = min(grid.totalLines - 1, s.cursor.line + 1)
        case .startOfLine: s.cursor.column = 0
        case .endOfLine: s.cursor.column = grid.renderedLine(s.cursor.line).lastContentColumn
        case .backToIndentation: s.cursor.column = firstContentColumn(s.cursor.line, grid: grid)
        case .top: s.cursor = GridPosition(line: 0, column: 0)
        case .bottom: s.cursor = GridPosition(line: max(0, grid.totalLines - 1), column: 0)
        // H/M/L move within the *visible window* (relative to viewTop), unlike history-top/bottom
        // which jump to the scrollback extent. Column is preserved (reveal clamps it).
        case .topLine: s.cursor.line = s.viewTop
        case .middleLine: s.cursor.line = min(grid.totalLines - 1, s.viewTop + max(1, grid.viewportRows) / 2)
        case .bottomLine: s.cursor.line = min(grid.totalLines - 1, s.viewTop + max(1, grid.viewportRows) - 1)
        case .previousPrompt:
            if let target = grid.promptRows.last(where: { $0 < s.cursor.line }) {
                s.cursor = GridPosition(line: target, column: 0)
            }
        case .nextPrompt:
            if let target = grid.promptRows.first(where: { $0 > s.cursor.line }) {
                s.cursor = GridPosition(line: target, column: 0)
            }
        case .pageUp: s.cursor.line = max(0, s.cursor.line - grid.viewportRows)
        case .pageDown: s.cursor.line = min(grid.totalLines - 1, s.cursor.line + grid.viewportRows)
        case .halfPageUp: s.cursor.line = max(0, s.cursor.line - max(1, grid.viewportRows / 2))
        case .halfPageDown: s.cursor.line = min(grid.totalLines - 1, s.cursor.line + max(1, grid.viewportRows / 2))
        case .nextWord: s.cursor = nextWord(from: s.cursor, grid: grid)
        case .previousWord: s.cursor = previousWord(from: s.cursor, grid: grid)
        case .nextWordEnd: s.cursor = nextWordEnd(from: s.cursor, grid: grid)

        case let .jump(kind, target):
            // No target yet (the bindable form): ask the front-end to capture the next keystroke
            // and re-dispatch with it filled in. Otherwise perform the on-line jump and remember it.
            guard let ch = target?.first else { return (s, .beginJumpEntry(kind)) }
            if let landing = jump(kind, ch, from: s.cursor, grid: grid, repeating: false) {
                s.cursor = landing
            }
            s.lastJump = CopyModeJump(kind: kind, target: ch)
        case .jumpAgain:
            if let j = s.lastJump, let landing = jump(j.kind, j.target, from: s.cursor, grid: grid, repeating: true) {
                s.cursor = landing
            }
        case .jumpReverse:
            if let j = s.lastJump,
               let landing = jump(j.kind.reversed, j.target, from: s.cursor, grid: grid, repeating: true) {
                s.cursor = landing
            }
        case .otherEnd:
            // Swap the selection anchor and the cursor (vi `o`) so the moving end flips.
            if let a = s.anchor { s.anchor = s.cursor; s.cursor = a }
        case let .gotoLine(n):
            s.cursor = GridPosition(line: min(max(0, n - 1), max(0, grid.totalLines - 1)), column: 0)

        case .beginSelection:
            if s.mode == .char { s.mode = .none; s.anchor = nil }
            else { s.mode = .char; s.anchor = s.cursor }
        case .selectLine:
            if s.mode == .line { s.mode = .none; s.anchor = nil }
            else { s.mode = .line; s.anchor = s.cursor }
        case .rectangleToggle:
            if s.mode == .block { s.mode = .char }
            else {
                if s.anchor == nil { s.anchor = s.cursor }
                s.mode = .block
            }
        case .clearSelection:
            s.mode = .none; s.anchor = nil

        case .searchForward:
            s.search.reverse = false
            return (s, .beginSearchEntry(reverse: false))
        case .searchBackward:
            s.search.reverse = true
            return (s, .beginSearchEntry(reverse: true))
        case .searchAgain:
            s = stepSearch(s, forward: !s.search.reverse, grid: grid)
        case .searchReverse:
            s = stepSearch(s, forward: s.search.reverse, grid: grid)

        case .copySelection:
            let text = selectedText(s, grid: grid)
            s.mode = .none; s.anchor = nil
            return (reveal(s, grid: grid), text.isEmpty ? .none : .copy(text))
        case .copySelectionAndCancel:
            return (s, .copyAndCancel(selectedText(s, grid: grid)))
        case let .copyPipe(command):
            return (s, .pipe(text: selectedText(s, grid: grid), command: command))
        case .paste:
            return (s, .paste)
        case .cancel:
            return (s, .cancel)
        }
        return (reveal(s, grid: grid), .none)
    }

    /// Apply a committed search query (from the front-end's input). Computes every match,
    /// then jumps to the first one in the search direction from the cursor (wrapping).
    public static func applySearch(
        _ state: CopyModeState,
        query: String,
        reverse: Bool,
        grid: CopyModeGridSource
    ) -> CopyModeState {
        var s = state
        s.search.query = query
        s.search.reverse = reverse
        s.search.matches = computeMatches(query, grid: grid)
        s.search.currentIndex = nil
        guard !s.search.matches.isEmpty,
              let idx = matchIndex(after: s.cursor, forward: !reverse, matches: s.search.matches)
        else { return s }
        s.search.currentIndex = idx
        let m = s.search.matches[idx]
        s.cursor = GridPosition(line: m.line, column: m.startColumn)
        return reveal(s, grid: grid)
    }

    // MARK: - Geometry helpers

    private static func maxColumn(_ grid: CopyModeGridSource) -> Int { max(0, grid.columns - 1) }

    /// Clamp the cursor into bounds and scroll `viewTop` just enough to keep it visible.
    private static func reveal(_ state: CopyModeState, grid: CopyModeGridSource) -> CopyModeState {
        var s = state
        let total = max(1, grid.totalLines)
        let rows = max(1, grid.viewportRows)
        s.cursor.line = min(max(0, s.cursor.line), total - 1)
        s.cursor.column = min(max(0, s.cursor.column), maxColumn(grid))
        // Scrollback eviction can shrink the buffer between reduce calls; an anchor left past
        // the new end would make selectedText read out-of-range (blank) lines and silently copy
        // nothing. Clamp it exactly like the cursor.
        if var anchor = s.anchor {
            anchor.line = min(max(0, anchor.line), total - 1)
            anchor.column = min(max(0, anchor.column), maxColumn(grid))
            s.anchor = anchor
        }
        let maxTop = max(0, total - rows)
        if s.cursor.line < s.viewTop { s.viewTop = s.cursor.line }
        else if s.cursor.line >= s.viewTop + rows { s.viewTop = s.cursor.line - rows + 1 }
        s.viewTop = min(max(0, s.viewTop), maxTop)
        return s
    }

    private static func isSeparator(_ c: Character) -> Bool { c == " " || c == "\t" }

    // MARK: - Word motion (crosses line boundaries, vi `w` / `b`)

    private static func nextWord(from pos: GridPosition, grid: CopyModeGridSource) -> GridPosition {
        var line = pos.line
        var rl = grid.renderedLine(line)
        var i = rl.charIndex(atOrAfter: pos.column)
        // If sitting on a word, step past it first.
        while i < rl.chars.count, !isSeparator(rl.chars[i]) { i += 1 }
        // Skip separators, advancing across lines, to land on the next word's first char.
        while true {
            while i < rl.chars.count, isSeparator(rl.chars[i]) { i += 1 }
            if i < rl.chars.count { break }
            if line >= grid.totalLines - 1 {
                return GridPosition(line: line, column: rl.columnOf.last ?? 0)
            }
            line += 1
            rl = grid.renderedLine(line)
            i = 0
            if i < rl.chars.count, !isSeparator(rl.chars[i]) { break }
        }
        return GridPosition(line: line, column: i < rl.columnOf.count ? rl.columnOf[i] : 0)
    }

    /// vi `e` — the end (last char) of the next word, crossing line boundaries. Always advances at
    /// least one character so a repeat steps forward off the current word's end.
    private static func nextWordEnd(from pos: GridPosition, grid: CopyModeGridSource) -> GridPosition {
        var line = pos.line
        var rl = grid.renderedLine(line)
        var i = rl.charIndex(atOrAfter: pos.column) + 1 // step at least one char forward
        // Skip separators, advancing across lines, to land inside the next word.
        while true {
            while i < rl.chars.count, isSeparator(rl.chars[i]) { i += 1 }
            if i < rl.chars.count { break }
            if line >= grid.totalLines - 1 {
                return GridPosition(line: line, column: rl.columnOf.last ?? 0)
            }
            line += 1
            rl = grid.renderedLine(line)
            i = 0
        }
        // Advance to the last non-separator char of this word.
        while i + 1 < rl.chars.count, !isSeparator(rl.chars[i + 1]) { i += 1 }
        return GridPosition(line: line, column: i < rl.columnOf.count ? rl.columnOf[i] : 0)
    }

    /// vi `f`/`F`/`t`/`T` jump-to-char, confined to the cursor's line (like vi). `forward`/`backward`
    /// land on the next/previous `target`; `toForward`/`toBackward` land one cell before/after it.
    /// `repeating` (from `;`/`,`) starts a `to`-jump one extra char along so it doesn't stick on the
    /// target the cursor is already adjacent to. Returns nil when there's no match (cursor unchanged).
    private static func jump(
        _ kind: CopyModeJumpKind,
        _ target: Character,
        from pos: GridPosition,
        grid: CopyModeGridSource,
        repeating: Bool
    ) -> GridPosition? {
        let rl = grid.renderedLine(pos.line)
        let ci = rl.charIndex(atOrAfter: pos.column)
        func at(_ index: Int) -> GridPosition? {
            guard index >= 0, index < rl.columnOf.count else { return nil }
            return GridPosition(line: pos.line, column: rl.columnOf[index])
        }
        switch kind {
        case .forward, .toForward:
            var j = ci + ((kind == .toForward && repeating) ? 2 : 1)
            while j < rl.chars.count, rl.chars[j] != target { j += 1 }
            guard j < rl.chars.count else { return nil }
            return at(kind == .toForward ? j - 1 : j)
        case .backward, .toBackward:
            var j = ci - ((kind == .toBackward && repeating) ? 2 : 1)
            while j >= 0, j < rl.chars.count, rl.chars[j] != target { j -= 1 }
            guard j >= 0, j < rl.chars.count else { return nil }
            return at(kind == .toBackward ? j + 1 : j)
        }
    }

    /// Grid column of the first non-blank character on `line` (0 when the line is blank) — vi `^`.
    private static func firstContentColumn(_ line: Int, grid: CopyModeGridSource) -> Int {
        let rl = grid.renderedLine(line)
        for (i, ch) in rl.chars.enumerated() where !isSeparator(ch) { return rl.columnOf[i] }
        return 0
    }

    private static func previousWord(from pos: GridPosition, grid: CopyModeGridSource) -> GridPosition {
        var line = pos.line
        var rl = grid.renderedLine(line)
        var i = rl.charIndex(atOrBefore: pos.column) - 1
        // Skip separators (and empty lines) backward to the previous word's last char.
        while true {
            while i >= 0, i < rl.chars.count, isSeparator(rl.chars[i]) { i -= 1 }
            if i >= 0, i < rl.chars.count { break }
            if line == 0 { return GridPosition(line: 0, column: 0) }
            line -= 1
            rl = grid.renderedLine(line)
            i = rl.chars.count - 1
        }
        // Back up to the start of this word.
        while i > 0, !isSeparator(rl.chars[i - 1]) { i -= 1 }
        return GridPosition(line: line, column: (i >= 0 && i < rl.columnOf.count) ? rl.columnOf[i] : 0)
    }

    // MARK: - Selection text extraction

    private static func selectedText(_ s: CopyModeState, grid: CopyModeGridSource) -> String {
        guard var anchor = s.anchor, s.mode != .none else { return "" }
        // Copy actions read the selection *before* reveal() runs, so a stale anchor/cursor from
        // a scrollback eviction must be clamped here too — never index past the live buffer.
        let total = max(1, grid.totalLines)
        var cursor = s.cursor
        anchor.line = min(max(0, anchor.line), total - 1)
        anchor.column = min(max(0, anchor.column), maxColumn(grid))
        cursor.line = min(max(0, cursor.line), total - 1)
        cursor.column = min(max(0, cursor.column), maxColumn(grid))
        switch s.mode {
        case .char:
            return linearText(from: Swift.min(anchor, cursor), to: Swift.max(anchor, cursor), grid: grid)
        case .line:
            let r0 = Swift.min(anchor.line, cursor.line)
            let r1 = Swift.max(anchor.line, cursor.line)
            return (r0...r1).map { trimTrailing(grid.renderedLine($0).text) }.joined(separator: "\n")
        case .block:
            let r0 = Swift.min(anchor.line, cursor.line)
            let r1 = Swift.max(anchor.line, cursor.line)
            let c0 = Swift.min(anchor.column, cursor.column)
            let c1 = Swift.max(anchor.column, cursor.column)
            return (r0...r1).map { grid.renderedLine($0).substring(fromColumn: c0, toColumn: c1 + 1) }
                .joined(separator: "\n")
        case .none:
            return ""
        }
    }

    /// Text of a linear (line-wrapping) selection from `a` to `b` (a ≤ b), trailing-trimmed
    /// on every line except where it would cut the selection short on the last line.
    private static func linearText(from a: GridPosition, to b: GridPosition, grid: CopyModeGridSource) -> String {
        if a.line == b.line {
            return grid.renderedLine(a.line).substring(fromColumn: a.column, toColumn: b.column + 1)
        }
        var parts: [String] = []
        parts.append(trimTrailing(grid.renderedLine(a.line).substring(fromColumn: a.column, toColumn: grid.columns)))
        if b.line - a.line > 1 {
            for l in (a.line + 1)..<b.line { parts.append(trimTrailing(grid.renderedLine(l).text)) }
        }
        parts.append(grid.renderedLine(b.line).substring(fromColumn: 0, toColumn: b.column + 1))
        return parts.joined(separator: "\n")
    }

    private static func trimTrailing(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == " " || s[prev] == "\t" { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    // MARK: - Search

    private static func stepSearch(_ state: CopyModeState, forward: Bool, grid: CopyModeGridSource) -> CopyModeState {
        var s = state
        guard !s.search.query.isEmpty else { return s }
        // Scrollback eviction shifts virtual line numbers under the stored matches, so n/N on a
        // cached list would jump to (or highlight) the wrong rows. Recompute from the live grid —
        // the same scan the initial search commit already does, at a human keypress cadence.
        s.search.matches = computeMatches(s.search.query, grid: grid)
        guard !s.search.matches.isEmpty else {
            s.search.currentIndex = nil
            return s
        }
        let idx = matchIndex(after: s.cursor, forward: forward, matches: s.search.matches) ?? (forward ? 0 : s.search.matches.count - 1)
        s.search.currentIndex = idx
        let m = s.search.matches[idx]
        s.cursor = GridPosition(line: m.line, column: m.startColumn)
        return reveal(s, grid: grid)
    }

    /// Index of the next match strictly after `cursor` in reading order (wrapping). `matches`
    /// are assumed sorted by `(line, startColumn)`.
    private static func matchIndex(after cursor: GridPosition, forward: Bool, matches: [CopyModeMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            for (i, m) in matches.enumerated() where (m.line, m.startColumn) > (cursor.line, cursor.column) {
                return i
            }
            return 0 // wrap
        } else {
            for i in stride(from: matches.count - 1, through: 0, by: -1) {
                let m = matches[i]
                if (m.line, m.startColumn) < (cursor.line, cursor.column) { return i }
            }
            return matches.count - 1 // wrap
        }
    }

    /// Every match of `query` across the buffer, in reading order. The query is treated as a
    /// regex (case-insensitive); an invalid pattern falls back to a literal substring scan, so
    /// a stray `(` searches literally rather than erroring.
    static func computeMatches(_ query: String, grid: CopyModeGridSource) -> [CopyModeMatch] {
        guard !query.isEmpty else { return [] }
        let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive])
        var out: [CopyModeMatch] = []
        for line in 0..<grid.totalLines {
            let rl = grid.renderedLine(line)
            guard !rl.chars.isEmpty else { continue }
            for range in matchRanges(in: rl.text, query: query, regex: regex) {
                guard range.lowerBound < rl.columnOf.count, range.upperBound - 1 < rl.columnOf.count else { continue }
                let startCol = rl.columnOf[range.lowerBound]
                let last = range.upperBound - 1
                let endCol = rl.columnOf[last] + rl.widthOf[last]
                out.append(CopyModeMatch(line: line, startColumn: startCol, endColumn: endCol))
            }
        }
        return out
    }

    /// Character-index ranges of `query` in `text` (regex if it compiled, else literal).
    private static func matchRanges(in text: String, query: String, regex: NSRegularExpression?) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        if let regex {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                guard let r = Range(m.range, in: text) else { continue }
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                let hi = text.distance(from: text.startIndex, to: r.upperBound)
                if hi > lo { ranges.append(lo..<hi) }
            }
            return ranges
        }
        // Literal, case-insensitive fallback.
        let hay = Array(text.lowercased())
        let needle = Array(query.lowercased())
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var i = 0
        while i + needle.count <= hay.count {
            if Array(hay[i..<(i + needle.count)]) == needle {
                ranges.append(i..<(i + needle.count))
                i += needle.count
            } else {
                i += 1
            }
        }
        return ranges
    }
}
