import XCTest
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessCopyMode

/// A literal-text grid for exercising the reducer with zero platform dependencies — the same
/// surface both the GUI emulator and the compositor terminal present.
private struct FakeGrid: CopyModeGridSource {
    let lines: [String]
    let columns: Int
    let viewportRows: Int
    let promptRows: [Int]

    init(_ lines: [String], columns: Int? = nil, viewportRows: Int? = nil, prompts: [Int] = []) {
        self.lines = lines
        self.columns = columns ?? (lines.map(\.count).max() ?? 1)
        self.viewportRows = viewportRows ?? lines.count
        self.promptRows = prompts
    }

    var totalLines: Int { lines.count }

    func line(_ index: Int) -> [TerminalGridCell] {
        var cells = Array(repeating: TerminalGridCell.blank, count: columns)
        guard index >= 0, index < lines.count else { return cells }
        for (i, scalar) in lines[index].unicodeScalars.enumerated() where i < columns {
            cells[i] = TerminalGridCell(codepoint: scalar.value)
        }
        return cells
    }
}

final class CopyModeReducerTests: XCTestCase {
    private func reduce(_ state: CopyModeState, _ action: CopyModeAction, _ grid: CopyModeGridSource) -> CopyModeState {
        CopyModeReducer.reduce(state, action, grid: grid).state
    }

    // MARK: Entry + motion

    func testInitialStatePinsToBottom() {
        let grid = FakeGrid(["a", "b", "c"], viewportRows: 3)
        let s = CopyModeReducer.initialState(grid: grid)
        XCTAssertEqual(s.cursor, GridPosition(line: 2, column: 0))
        XCTAssertEqual(s.viewTop, 0)
        XCTAssertEqual(s.mode, .none)
    }

    func testHorizontalMotionClamps() {
        let grid = FakeGrid(["hello"], columns: 5)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .cursorLeft, grid)
        XCTAssertEqual(s.cursor.column, 0) // clamped at 0
        for _ in 0..<10 { s = reduce(s, .cursorRight, grid) }
        XCTAssertEqual(s.cursor.column, 4) // clamped at columns-1
    }

    func testEndOfLineLandsOnLastContent() {
        let grid = FakeGrid(["hi"], columns: 10)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0)
        s = reduce(s, .endOfLine, grid)
        XCTAssertEqual(s.cursor.column, 1) // 'i'
        s = reduce(s, .startOfLine, grid)
        XCTAssertEqual(s.cursor.column, 0)
    }

    func testTopBottom() {
        let grid = FakeGrid(["one", "two", "three"], viewportRows: 2)
        var s = CopyModeReducer.initialState(grid: grid)
        s = reduce(s, .top, grid)
        XCTAssertEqual(s.cursor.line, 0)
        XCTAssertEqual(s.viewTop, 0)
        s = reduce(s, .bottom, grid)
        XCTAssertEqual(s.cursor.line, 2)
        XCTAssertEqual(s.viewTop, 1) // 3 lines, 2 rows → bottom row scrolled to viewTop 1
    }

    func testPromptJumpMotions() {
        // Prompts on lines 1 and 4 of a 6-line buffer.
        let grid = FakeGrid(["out", "$ a", "r1", "r2", "$ b", "r3"], viewportRows: 6, prompts: [1, 4])
        var s = CopyModeReducer.initialState(grid: grid) // cursor at bottom (line 5)
        s = reduce(s, .previousPrompt, grid)
        XCTAssertEqual(s.cursor.line, 4, "previous-prompt lands on the nearest prompt above")
        s = reduce(s, .previousPrompt, grid)
        XCTAssertEqual(s.cursor.line, 1)
        s = reduce(s, .previousPrompt, grid)
        XCTAssertEqual(s.cursor.line, 1, "no prompt above the first → stays put")
        s = reduce(s, .nextPrompt, grid)
        XCTAssertEqual(s.cursor.line, 4, "next-prompt lands on the nearest prompt below")
        s = reduce(s, .nextPrompt, grid)
        XCTAssertEqual(s.cursor.line, 4, "no prompt below the last → stays put")
    }

    func testPromptJumpNoOpWithoutMarks() {
        let grid = FakeGrid(["a", "b", "c"], viewportRows: 3) // no prompts
        var s = CopyModeReducer.initialState(grid: grid)
        s = reduce(s, .previousPrompt, grid)
        XCTAssertEqual(s.cursor.line, 2, "no marks → previous-prompt is a no-op")
    }

    func testWordMotion() {
        let grid = FakeGrid(["foo bar baz"], columns: 11)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .nextWord, grid)
        XCTAssertEqual(s.cursor.column, 4) // start of "bar"
        s = reduce(s, .nextWord, grid)
        XCTAssertEqual(s.cursor.column, 8) // start of "baz"
        s = reduce(s, .previousWord, grid)
        XCTAssertEqual(s.cursor.column, 4) // back to "bar"
    }

    func testVerticalMotionScrollsView() {
        let grid = FakeGrid((0..<10).map { "line\($0)" }, columns: 8, viewportRows: 4)
        var s = CopyModeReducer.initialState(grid: grid) // cursor line 9, viewTop 6
        XCTAssertEqual(s.viewTop, 6)
        for _ in 0..<4 { s = reduce(s, .cursorUp, grid) }
        XCTAssertEqual(s.cursor.line, 5)
        XCTAssertEqual(s.viewTop, 5) // scrolled up to keep cursor visible
    }

    // MARK: Selection extraction

    func testCharSelectionText() {
        let grid = FakeGrid(["hello world"], columns: 11)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .beginSelection, grid)
        XCTAssertEqual(s.mode, .char)
        for _ in 0..<4 { s = reduce(s, .cursorRight, grid) } // cursor at col 4 ('o')
        let (_, effect) = CopyModeReducer.reduce(s, .copySelectionAndCancel, grid: grid)
        XCTAssertEqual(effect, .copyAndCancel("hello"))
    }

    func testLineSelectionText() {
        let grid = FakeGrid(["alpha", "beta", "gamma"], columns: 6)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .selectLine, grid)
        s = reduce(s, .cursorDown, grid) // lines 0..1
        let (_, effect) = CopyModeReducer.reduce(s, .copySelectionAndCancel, grid: grid)
        XCTAssertEqual(effect, .copyAndCancel("alpha\nbeta"))
    }

    func testBlockSelectionText() {
        let grid = FakeGrid(["abcd", "efgh", "ijkl"], columns: 4)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 1)
        s = reduce(s, .rectangleToggle, grid) // anchor (0,1), block
        s = reduce(s, .cursorDown, grid)
        s = reduce(s, .cursorDown, grid)
        s = reduce(s, .cursorRight, grid) // cursor (2,2)
        let (_, effect) = CopyModeReducer.reduce(s, .copySelectionAndCancel, grid: grid)
        XCTAssertEqual(effect, .copyAndCancel("bc\nfg\njk"))
    }

    func testCopyPipeAndPasteEffects() {
        let grid = FakeGrid(["data"], columns: 4)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .beginSelection, grid)
        for _ in 0..<3 { s = reduce(s, .cursorRight, grid) }
        let pipe = CopyModeReducer.reduce(s, .copyPipe("pbcopy"), grid: grid).effect
        XCTAssertEqual(pipe, .pipe(text: "data", command: "pbcopy"))
        XCTAssertEqual(CopyModeReducer.reduce(s, .paste, grid: grid).effect, .paste)
        XCTAssertEqual(CopyModeReducer.reduce(s, .cancel, grid: grid).effect, .cancel)
    }

    // MARK: Search

    func testSearchFindsAllMatchesAndCycles() {
        let grid = FakeGrid(["foo", "bar", "foo baz foo"], columns: 11)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = CopyModeReducer.applySearch(s, query: "foo", reverse: false, grid: grid)
        XCTAssertEqual(s.search.matches.count, 3) // line0, line2x2
        // First match after (0,0) is line2 col0.
        XCTAssertEqual(s.cursor.line, 2)
        XCTAssertEqual(s.cursor.column, 0)
        // search-again forward → next match (line2, col8), then wrap to (line0, col0).
        s = reduce(s, .searchAgain, grid)
        XCTAssertEqual(GridPosition(line: s.cursor.line, column: s.cursor.column), GridPosition(line: 2, column: 8))
        s = reduce(s, .searchAgain, grid)
        XCTAssertEqual(s.cursor, GridPosition(line: 0, column: 0)) // wrapped
    }

    func testSearchBeginEntryEffect() {
        let grid = FakeGrid(["x"], columns: 1)
        let s = CopyModeReducer.initialState(grid: grid, cursorLine: 0)
        XCTAssertEqual(CopyModeReducer.reduce(s, .searchForward, grid: grid).effect, .beginSearchEntry(reverse: false))
        XCTAssertEqual(CopyModeReducer.reduce(s, .searchBackward, grid: grid).effect, .beginSearchEntry(reverse: true))
    }

    func testSearchMatchColumnsWithWideChar() {
        // A wide (CJK) leading cell + spacer, then "ok": columns 0(wide),1(spacer),2,3.
        var cells = Array(repeating: TerminalGridCell.blank, count: 4)
        cells[0] = TerminalGridCell(codepoint: 0x4E16, width: .wide) // 世
        cells[1] = TerminalGridCell(width: .spacerTail)
        cells[2] = TerminalGridCell(codepoint: UInt32(("o" as Unicode.Scalar).value))
        cells[3] = TerminalGridCell(codepoint: UInt32(("k" as Unicode.Scalar).value))
        struct WideGrid: CopyModeGridSource {
            let cells: [TerminalGridCell]
            var totalLines: Int { 1 }
            var viewportRows: Int { 1 }
            var columns: Int { 4 }
            func line(_ index: Int) -> [TerminalGridCell] { cells }
        }
        let matches = CopyModeReducer.computeMatches("ok", grid: WideGrid(cells: cells))
        XCTAssertEqual(matches, [CopyModeMatch(line: 0, startColumn: 2, endColumn: 4)])
    }

    // MARK: Scrollback eviction (v1.7 audit regressions)

    /// Scrollback eviction shrinks the buffer between reduce calls; copying with a selection
    /// anchored above the new head must clamp into the live buffer instead of silently
    /// extracting blank out-of-range lines.
    func testCopyAfterEvictionClampsStaleAnchorAndCursor() {
        let big = FakeGrid((0..<10).map { "line\($0)" }, columns: 6, viewportRows: 3)
        var s = CopyModeReducer.initialState(grid: big, cursorLine: 8, cursorColumn: 0)
        s = reduce(s, .beginSelection, big) // anchor (8,0)
        s = reduce(s, .cursorDown, big)     // cursor (9,0)
        // The buffer shrank to 4 lines under the live selection (history head evicted).
        let small = FakeGrid(["l0", "l1", "l2", "l3"], columns: 6, viewportRows: 3)
        let effect = CopyModeReducer.reduce(s, .copySelectionAndCancel, grid: small).effect
        // Both ends clamp to the last live line → its first cell, never whitespace garbage.
        XCTAssertEqual(effect, .copyAndCancel("l"))
    }

    /// Any motion routed through reveal() must clamp a stale anchor the same way as the cursor.
    func testEvictionClampsAnchorOnNextMotion() {
        let big = FakeGrid((0..<10).map { "line\($0)" }, columns: 6, viewportRows: 3)
        var s = CopyModeReducer.initialState(grid: big, cursorLine: 9, cursorColumn: 2)
        s = reduce(s, .beginSelection, big) // anchor (9,2)
        let small = FakeGrid(["a", "b"], columns: 6, viewportRows: 3)
        s = reduce(s, .cursorLeft, small)
        XCTAssertEqual(s.anchor?.line, 1) // clamped to the live tail
    }

    /// Block/char extraction includes a wide glyph whose span merely intersects the column
    /// range — selecting only its trailing cell still copies the glyph the highlight covers.
    func testSubstringIncludesWideCharOnPartialOverlap() {
        var cells = Array(repeating: TerminalGridCell.blank, count: 4)
        cells[0] = TerminalGridCell(codepoint: 0x4E16, width: .wide) // 世 at cols 0-1
        cells[1] = TerminalGridCell(width: .spacerTail)
        cells[2] = TerminalGridCell(codepoint: UInt32(("a" as Unicode.Scalar).value))
        cells[3] = TerminalGridCell(codepoint: UInt32(("b" as Unicode.Scalar).value))
        struct WideGrid: CopyModeGridSource {
            let cells: [TerminalGridCell]
            var totalLines: Int { 1 }
            var viewportRows: Int { 1 }
            var columns: Int { 4 }
            func line(_ index: Int) -> [TerminalGridCell] { cells }
        }
        let rl = WideGrid(cells: cells).renderedLine(0)
        XCTAssertEqual(rl.substring(fromColumn: 1, toColumn: 4), "世ab") // trailing cell covered
        XCTAssertEqual(rl.substring(fromColumn: 2, toColumn: 4), "ab")  // glyph fully outside
    }

    /// n/N re-derive matches from the live grid: eviction shifts virtual line numbers, so a
    /// cached match list would jump to (and highlight) the wrong rows.
    func testSearchAgainRecomputesAfterEviction() {
        let grid = FakeGrid(["foo", "bar", "foo"], columns: 3)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = CopyModeReducer.applySearch(s, query: "foo", reverse: false, grid: grid)
        XCTAssertEqual(s.search.matches.count, 2)
        // The first "foo" line evicted; matches must re-derive from the live grid.
        let evicted = FakeGrid(["bar", "foo"], columns: 3)
        s = reduce(s, .searchAgain, evicted)
        XCTAssertEqual(s.search.matches, [CopyModeMatch(line: 1, startColumn: 0, endColumn: 3)])
        XCTAssertEqual(s.cursor, GridPosition(line: 1, column: 0))
    }

    // MARK: Render projection

    func testViewportProjection() {
        let grid = FakeGrid((0..<8).map { "row\($0)" }, columns: 6, viewportRows: 4)
        var s = CopyModeReducer.initialState(grid: grid) // line7, viewTop4
        s = reduce(s, .beginSelection, grid)
        s = reduce(s, .cursorUp, grid) // anchor(7,0) cursor(6,0)
        let sel = s.viewportSelection(rows: 4, columns: 6)
        XCTAssertEqual(sel?.kind, .linear)
        XCTAssertEqual(sel?.startRow, 2) // line6 - viewTop4
        XCTAssertEqual(sel?.endRow, 3)   // line7 - viewTop4
        XCTAssertEqual(s.viewportCursor(rows: 4)?.row, 2)
        XCTAssertEqual(s.scrollbackOffset(historyCount: 4), 0) // viewTop4, hist4 → offset 0 (live)
    }
}
