import Foundation
@testable import HarnessCore
import XCTest

final class PaneRectSolverTests: XCTestCase {
    private func leaf() -> PaneNode { .leaf(PaneLeaf()) }

    func testSingleLeafCoversFullArea() {
        let rects = PaneRectSolver.solve(leaf(), cols: 80, rows: 24)
        XCTAssertEqual(rects.count, 1)
        let r = rects[0]
        XCTAssertEqual([r.x, r.y, r.cols, r.rows], [0, 0, 80, 24])
        XCTAssertNil(r.labelRow, "no pane-border-status → no reserved label row")
    }

    func testPaneBorderStatusTopReservesTopRow() {
        let rects = PaneRectSolver.solve(leaf(), cols: 80, rows: 24, paneBorderStatus: .top)
        let r = rects[0]
        // Interior shifts down one row; the label sits on the original top row.
        XCTAssertEqual([r.x, r.y, r.cols, r.rows], [0, 1, 80, 23])
        XCTAssertEqual(r.labelRow, 0)
    }

    func testPaneBorderStatusBottomReservesBottomRow() {
        let rects = PaneRectSolver.solve(leaf(), cols: 80, rows: 24, paneBorderStatus: .bottom)
        let r = rects[0]
        XCTAssertEqual([r.x, r.y, r.cols, r.rows], [0, 0, 80, 23])
        XCTAssertEqual(r.labelRow, 23)
    }

    func testPaneBorderStatusReservesPerPaneInSplit() {
        // Each stacked pane reserves its own top label row.
        let node = PaneNode.branch(direction: .vertical, ratio: 0.5, first: leaf(), second: leaf())
        let rects = PaneRectSolver.solve(node, cols: 80, rows: 25, paneBorderStatus: .top)
        XCTAssertEqual(rects[0].labelRow, 0)            // top pane label on row 0
        XCTAssertEqual(rects[0].y, 1)                   // its content starts below
        XCTAssertEqual(rects[1].labelRow, rects[1].y - 1) // bottom pane label just above its content
    }

    func testPaneBorderStatusSkippedForOneRowPane() {
        // A 1-row pane can't spare a row for the label.
        let rects = PaneRectSolver.solve(leaf(), cols: 80, rows: 1, paneBorderStatus: .top)
        XCTAssertEqual(rects[0].rows, 1)
        XCTAssertNil(rects[0].labelRow)
    }

    func testPaneBorderStatusOptionParsing() {
        XCTAssertEqual(PaneBorderStatus(option: "top"), .top)
        XCTAssertEqual(PaneBorderStatus(option: "BOTTOM"), .bottom)
        XCTAssertEqual(PaneBorderStatus(option: "off"), .off)
        XCTAssertEqual(PaneBorderStatus(option: "garbage"), .off)
    }

    func testYOriginShiftsEveryRect() {
        // A top status band reserves N rows: the pane area starts at `yOrigin` and the
        // interior + label rows shift down by exactly that, staying absolute for the compositor.
        let node = PaneNode.branch(direction: .vertical, ratio: 0.5, first: leaf(), second: leaf())
        let base = PaneRectSolver.solve(node, cols: 80, rows: 23, paneBorderStatus: .top)
        let shifted = PaneRectSolver.solve(node, cols: 80, rows: 23, paneBorderStatus: .top, yOrigin: 1)
        XCTAssertEqual(base.count, shifted.count)
        for (b, s) in zip(base, shifted) {
            XCTAssertEqual(s.y, b.y + 1, "interior row shifts by yOrigin")
            XCTAssertEqual(s.labelRow, b.labelRow.map { $0 + 1 }, "label row shifts by yOrigin")
            XCTAssertEqual([s.x, s.cols, s.rows], [b.x, b.cols, b.rows], "only y shifts")
        }
    }

    func testYOriginDefaultsToZero() {
        let node = leaf() // same node both times so the rects' pane/surface IDs match
        let withDefault = PaneRectSolver.solve(node, cols: 80, rows: 24)
        let withZero = PaneRectSolver.solve(node, cols: 80, rows: 24, yOrigin: 0)
        XCTAssertEqual(withDefault, withZero, "yOrigin 0 is the existing behavior")
    }

    func testStatusPositionOptionParsing() {
        XCTAssertEqual(StatusPosition(option: "top"), .top)
        XCTAssertEqual(StatusPosition(option: "BOTTOM"), .bottom)
        XCTAssertEqual(StatusPosition(option: "garbage"), .bottom, "unknown → safe default bottom")
    }

    func testHorizontalSplitIsSideBySideWithDivider() {
        // .horizontal => left | right, first = left, ratio = left fraction.
        let node = PaneNode.branch(direction: .horizontal, ratio: 0.5, first: leaf(), second: leaf())
        let rects = PaneRectSolver.solve(node, cols: 81, rows: 24)
        XCTAssertEqual(rects.count, 2)
        let left = rects[0], right = rects[1]
        // 81 - 1 divider = 80 split 40/40; left at x=0, right at x=41.
        XCTAssertEqual([left.x, left.y, left.cols, left.rows], [0, 0, 40, 24])
        XCTAssertEqual([right.x, right.y, right.cols, right.rows], [41, 0, 40, 24])
        // One-cell divider gap between them.
        XCTAssertEqual(right.x, left.x + left.cols + 1)
    }

    func testVerticalSplitIsStackedWithDivider() {
        // .vertical => top / bottom, first = top.
        let node = PaneNode.branch(direction: .vertical, ratio: 0.5, first: leaf(), second: leaf())
        let rects = PaneRectSolver.solve(node, cols: 80, rows: 25)
        XCTAssertEqual(rects.count, 2)
        let top = rects[0], bottom = rects[1]
        // 25 - 1 divider = 24 split 12/12; top at y=0, bottom at y=13.
        XCTAssertEqual([top.x, top.y, top.cols, top.rows], [0, 0, 80, 12])
        XCTAssertEqual([bottom.x, bottom.y, bottom.cols, bottom.rows], [0, 13, 80, 12])
        XCTAssertEqual(bottom.y, top.y + top.rows + 1)
    }

    func testRatioRespected() {
        let node = PaneNode.branch(direction: .horizontal, ratio: 0.25, first: leaf(), second: leaf())
        let rects = PaneRectSolver.solve(node, cols: 101, rows: 10)
        // 100 available, first = 25, second = 75.
        XCTAssertEqual(rects[0].cols, 25)
        XCTAssertEqual(rects[1].cols, 75)
    }

    func testNestedSplitsTileWithoutOverlap() {
        // Left pane, right column split into top/bottom.
        let node = PaneNode.branch(
            direction: .horizontal,
            ratio: 0.5,
            first: leaf(),
            second: .branch(direction: .vertical, ratio: 0.5, first: leaf(), second: leaf())
        )
        let rects = PaneRectSolver.solve(node, cols: 81, rows: 25)
        XCTAssertEqual(rects.count, 3)
        // No two interior rects overlap.
        for i in 0 ..< rects.count {
            for j in (i + 1) ..< rects.count {
                XCTAssertFalse(overlaps(rects[i], rects[j]), "rect \(i) overlaps \(j)")
            }
        }
    }

    func testBothChildrenStayVisibleWhenTiny() {
        // Too small for a divider: both panes still get >= 1 cell.
        let node = PaneNode.branch(direction: .horizontal, ratio: 0.5, first: leaf(), second: leaf())
        let rects = PaneRectSolver.solve(node, cols: 2, rows: 5)
        XCTAssertEqual(rects.count, 2)
        XCTAssertGreaterThanOrEqual(rects[0].cols, 1)
        XCTAssertGreaterThanOrEqual(rects[1].cols, 1)
        XCTAssertFalse(overlaps(rects[0], rects[1]))
    }

    func testSplitIntoOneCellDropsZeroSizeChild() {
        // A split rendered into a single row/column can't fit two panes; the solver must emit the
        // first pane only — never a 0-size rect (the old clamp produced a second pane of 0 cells).
        let vertical = PaneNode.branch(direction: .vertical, ratio: 0.5, first: leaf(), second: leaf())
        let oneRow = PaneRectSolver.solve(vertical, cols: 80, rows: 1)
        XCTAssertEqual(oneRow.count, 1)
        XCTAssertTrue(oneRow.allSatisfy { $0.rows >= 1 && $0.cols >= 1 }, "no zero-size rect")

        let horizontal = PaneNode.branch(direction: .horizontal, ratio: 0.5, first: leaf(), second: leaf())
        let oneCol = PaneRectSolver.solve(horizontal, cols: 1, rows: 24)
        XCTAssertEqual(oneCol.count, 1)
        XCTAssertTrue(oneCol.allSatisfy { $0.rows >= 1 && $0.cols >= 1 }, "no zero-size rect")
    }

    private func overlaps(_ a: PaneRect, _ b: PaneRect) -> Bool {
        let ax2 = a.x + a.cols, ay2 = a.y + a.rows
        let bx2 = b.x + b.cols, by2 = b.y + b.rows
        return a.x < bx2 && b.x < ax2 && a.y < by2 && b.y < ay2
    }
}
