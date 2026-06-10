import XCTest
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessCopyMode

/// Roadmap PR-15: jump-to-char (vi `f`/`F`/`t`/`T` + `;`/`,`), other-end (`o`), and goto-line.
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

final class CopyModeJumpMotionTests: XCTestCase {
    private func reduce(_ s: CopyModeState, _ a: CopyModeAction, _ g: CopyModeGridSource) -> CopyModeState {
        CopyModeReducer.reduce(s, a, grid: g).state
    }

    // MARK: jump-to-char

    func testJumpForwardLandsOnTarget() {
        let grid = FakeGrid(["a.b.c"]) // columns: a0 .1 b2 .3 c4
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .jump(.forward, "."), grid)
        XCTAssertEqual(s.cursor.column, 1, "f. lands on the first '.'")
        // `;` repeats forward to the next '.'.
        s = reduce(s, .jumpAgain, grid)
        XCTAssertEqual(s.cursor.column, 3, "; advances to the next '.'")
        // `,` reverses the last jump (now backward) to the previous '.'.
        s = reduce(s, .jumpReverse, grid)
        XCTAssertEqual(s.cursor.column, 1, ", jumps back to the previous '.'")
    }

    func testJumpBackwardLandsOnPreviousTarget() {
        let grid = FakeGrid(["a.b.c"])
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 4)
        s = reduce(s, .jump(.backward, "."), grid)
        XCTAssertEqual(s.cursor.column, 3, "F. lands on the nearest '.' to the left")
    }

    func testJumpToForwardLandsBeforeTarget() {
        let grid = FakeGrid(["ab.cd"]) // a0 b1 .2 c3 d4
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .jump(.toForward, "."), grid)
        XCTAssertEqual(s.cursor.column, 1, "t. lands one cell before the '.'")
    }

    func testJumpToBackwardLandsAfterTarget() {
        let grid = FakeGrid(["ab.cd"])
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 4)
        s = reduce(s, .jump(.toBackward, "."), grid)
        XCTAssertEqual(s.cursor.column, 3, "T. lands one cell after the '.'")
    }

    func testJumpWithNoTargetRequestsCapture() {
        let grid = FakeGrid(["a.b"])
        let s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        let (_, effect) = CopyModeReducer.reduce(s, .jump(.forward, nil), grid: grid)
        XCTAssertEqual(effect, .beginJumpEntry(.forward), "the bindable form asks the front-end to capture the target")
    }

    func testJumpNoMatchLeavesCursorPut() {
        let grid = FakeGrid(["abc"])
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .jump(.forward, "z"), grid)
        XCTAssertEqual(s.cursor.column, 0, "no match → cursor unchanged")
    }

    // MARK: other-end

    func testOtherEndSwapsAnchorAndCursor() {
        let grid = FakeGrid(["hello world"])
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 0)
        s = reduce(s, .beginSelection, grid)        // anchor at col 0
        s = reduce(s, .jump(.forward, "w"), grid)   // cursor moves to the 'w' (col 6)
        XCTAssertEqual(s.cursor.column, 6)
        XCTAssertEqual(s.anchor?.column, 0)
        s = reduce(s, .otherEnd, grid)
        XCTAssertEqual(s.cursor.column, 0, "other-end moves the cursor to the old anchor")
        XCTAssertEqual(s.anchor?.column, 6, "and the anchor to the old cursor")
    }

    // MARK: goto-line (1-based)

    func testGotoLineJumpsToOneBasedLine() {
        let grid = FakeGrid(["one", "two", "three"], viewportRows: 3)
        var s = CopyModeReducer.initialState(grid: grid, cursorLine: 0, cursorColumn: 2)
        s = reduce(s, .gotoLine(2), grid)
        XCTAssertEqual(s.cursor.line, 1, "goto-line 2 is the second (0-based index 1) line")
        XCTAssertEqual(s.cursor.column, 0)
        s = reduce(s, .gotoLine(999), grid)
        XCTAssertEqual(s.cursor.line, 2, "out-of-range clamps to the last line")
    }

    // MARK: parsing (the headline: these names used to be parse-time failures)

    func testTmuxNamesRoundTripAndParse() {
        XCTAssertEqual(CopyModeAction(tmuxName: "jump-forward"), .jump(.forward, nil))
        XCTAssertEqual(CopyModeAction(tmuxName: "jump-to-backward"), .jump(.toBackward, nil))
        XCTAssertEqual(CopyModeAction(tmuxName: "jump-again"), .jumpAgain)
        XCTAssertEqual(CopyModeAction(tmuxName: "other-end"), .otherEnd)
        XCTAssertEqual(CopyModeAction(tmuxName: "goto-line", argument: "5"), .gotoLine(5))
        XCTAssertEqual(CopyModeAction(tmuxName: "next-space"), .nextWord) // big-WORD aliases the word motion
        XCTAssertEqual(CopyModeAction.jump(.forward, nil).tmuxName, "jump-forward")
    }
}
