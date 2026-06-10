import XCTest
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessCopyMode

/// Roadmap PR-8: three copy-mode action aliases were silently wrong — `next-word-end` landed on a
/// word *start*, `top-line`/`bottom-line` jumped to the scrollback *extent* (history-top/bottom)
/// instead of the visible top/bottom row, and `back-to-indentation` went to column 0 ignoring
/// indent. These verify the now-distinct motions and that the tmux names are un-aliased.
private struct FakeGrid: CopyModeGridSource {
    let lines: [String]
    let columns: Int
    let viewportRows: Int

    init(_ lines: [String], columns: Int? = nil, viewportRows: Int? = nil) {
        self.lines = lines
        self.columns = columns ?? (lines.map(\.count).max() ?? 1)
        self.viewportRows = viewportRows ?? lines.count
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

final class CopyModeAliasMotionTests: XCTestCase {
    private func reduce(_ s: CopyModeState, _ a: CopyModeAction, _ g: CopyModeGridSource) -> CopyModeState {
        CopyModeReducer.reduce(s, a, grid: g).state
    }

    // MARK: next-word-end (vi `e`)

    func testNextWordEndLandsOnWordEndNotStart() {
        let grid = FakeGrid(["foo bar baz"], columns: 11)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .nextWordEnd, grid)
        XCTAssertEqual(s.cursor.column, 2, "end of 'foo'")
        s = reduce(s, .nextWordEnd, grid)
        XCTAssertEqual(s.cursor.column, 6, "end of 'bar'")
        // Distinct from next-word, which lands on the *start* of the next word.
        var w = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        w = reduce(w, .nextWord, grid)
        XCTAssertEqual(w.cursor.column, 4, "start of 'bar'")
    }

    func testNextWordEndCrossesLines() {
        let grid = FakeGrid(["ab", "cd"], columns: 2)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 1) // end of "ab"
        s = reduce(s, .nextWordEnd, grid)
        XCTAssertEqual(s.cursor.line, 1)
        XCTAssertEqual(s.cursor.column, 1, "end of 'cd' on the next line")
    }

    // MARK: back-to-indentation (vi `^`)

    func testBackToIndentationLandsOnFirstNonBlank() {
        let grid = FakeGrid(["    hi"], columns: 6)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 5)
        s = reduce(s, .backToIndentation, grid)
        XCTAssertEqual(s.cursor.column, 4, "first non-blank column, not 0")
        // start-of-line still goes to column 0 (distinct action).
        s = reduce(s, .startOfLine, grid)
        XCTAssertEqual(s.cursor.column, 0)
    }

    func testBackToIndentationBlankLineGoesToZero() {
        let grid = FakeGrid(["      "], columns: 6)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 3)
        s = reduce(s, .backToIndentation, grid)
        XCTAssertEqual(s.cursor.column, 0)
    }

    // MARK: H / M / L — visible window, not history extent

    func testTopMiddleBottomLineMoveWithinVisibleWindow() {
        // 6 lines, a 3-row window scrolled so viewTop = 2 (lines 2,3,4 visible).
        let grid = FakeGrid(["l0", "l1", "l2", "l3", "l4", "l5"], columns: 2, viewportRows: 3)
        var s = CopyModeState(cursor: GridPosition(line: 3, column: 0), viewTop: 2)
        s = reduce(s, .topLine, grid)
        XCTAssertEqual(s.cursor.line, 2, "top-line → top visible row, not history top (0)")
        XCTAssertEqual(s.viewTop, 2, "no scroll: the row was already visible")
        s = reduce(s, .middleLine, grid)
        XCTAssertEqual(s.cursor.line, 3, "middle of the 3-row window")
        s = reduce(s, .bottomLine, grid)
        XCTAssertEqual(s.cursor.line, 4, "bottom-line → bottom visible row, not history bottom (5)")
        XCTAssertEqual(s.viewTop, 2)
    }

    func testBottomLineClampsToBufferEnd() {
        // Window taller than the remaining buffer: bottom-line clamps to the last line.
        let grid = FakeGrid(["a", "b"], columns: 1, viewportRows: 10)
        var s = CopyModeState(cursor: GridPosition(line: 0, column: 0), viewTop: 0)
        s = reduce(s, .bottomLine, grid)
        XCTAssertEqual(s.cursor.line, 1)
    }

    // MARK: tmux name round-trips are un-aliased

    func testTmuxNamesAreDistinctAndRoundTrip() {
        XCTAssertEqual(CopyModeAction(tmuxName: "next-word-end"), .nextWordEnd)
        XCTAssertEqual(CopyModeAction(tmuxName: "back-to-indentation"), .backToIndentation)
        XCTAssertEqual(CopyModeAction(tmuxName: "top-line"), .topLine)
        XCTAssertEqual(CopyModeAction(tmuxName: "middle-line"), .middleLine)
        XCTAssertEqual(CopyModeAction(tmuxName: "bottom-line"), .bottomLine)
        // The previously-aliased targets keep their own names.
        XCTAssertEqual(CopyModeAction(tmuxName: "next-word"), .nextWord)
        XCTAssertEqual(CopyModeAction(tmuxName: "start-of-line"), .startOfLine)
        XCTAssertEqual(CopyModeAction(tmuxName: "history-top"), .top)
        XCTAssertEqual(CopyModeAction(tmuxName: "history-bottom"), .bottom)
        XCTAssertEqual(CopyModeAction.nextWordEnd.tmuxName, "next-word-end")
        XCTAssertEqual(CopyModeAction.backToIndentation.tmuxName, "back-to-indentation")
        XCTAssertEqual(CopyModeAction.topLine.tmuxName, "top-line")
        XCTAssertEqual(CopyModeAction.middleLine.tmuxName, "middle-line")
        XCTAssertEqual(CopyModeAction.bottomLine.tmuxName, "bottom-line")
    }
}
