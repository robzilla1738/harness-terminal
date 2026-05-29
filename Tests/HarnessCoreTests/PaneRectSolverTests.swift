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

    private func overlaps(_ a: PaneRect, _ b: PaneRect) -> Bool {
        let ax2 = a.x + a.cols, ay2 = a.y + a.rows
        let bx2 = b.x + b.cols, by2 = b.y + b.rows
        return a.x < bx2 && b.x < ax2 && a.y < by2 && b.y < ay2
    }
}
