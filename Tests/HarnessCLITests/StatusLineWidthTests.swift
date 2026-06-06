import XCTest
@testable import HarnessCLI
import HarnessCore

/// Display-width measurement + clipping for the attach-window status band. Scalar counting
/// overflowed the row by one column per wide (CJK) glyph and under-truncated overrides; these
/// pin the column-accurate behavior.
final class StatusLineWidthTests: XCTestCase {
    func testDisplayWidthCountsColumnsNotScalars() {
        XCTAssertEqual(StatusLineWidth.displayWidth("abc"), 3)
        XCTAssertEqual(StatusLineWidth.displayWidth("中"), 2) // one scalar, two columns
        XCTAssertEqual(StatusLineWidth.displayWidth("中A"), 3)
        XCTAssertEqual(StatusLineWidth.displayWidth("e\u{0301}"), 1) // combining mark = 0 columns
        XCTAssertEqual(StatusLineWidth.displayWidth(""), 0)
    }

    func testClipCutsAtDisplayColumns() {
        XCTAssertEqual(StatusLineWidth.clip("中AB", to: 2), "中")
        XCTAssertEqual(StatusLineWidth.clip("中AB", to: 3), "中A")
        XCTAssertEqual(StatusLineWidth.clip("abc", to: 5), "abc")
        XCTAssertEqual(StatusLineWidth.clip("abc", to: 0), "")
    }

    /// A wide glyph that would straddle the cut is dropped entirely — overflowing the row by
    /// its trailing cell is exactly the bug this replaced.
    func testClipDropsStraddlingWideGlyph() {
        XCTAssertEqual(StatusLineWidth.clip("A中B", to: 2), "A")
        XCTAssertEqual(StatusLineWidth.clip("中中", to: 3), "中")
    }

    func testClipKeepsCombiningMarksOnKeptBase() {
        XCTAssertEqual(StatusLineWidth.clip("e\u{0301}x", to: 1), "e\u{0301}")
    }

    func testClipSegmentsTruncatesTheOverflowingSegment() {
        let segs = [StyledSegment(text: "中中"), StyledSegment(text: "xyz")]
        let out = StatusLineWidth.clipSegments(segs, to: 5)
        XCTAssertEqual(out.map(\.text), ["中中", "x"])
        XCTAssertEqual(StatusLineWidth.displayWidth(of: out), 5)
    }

    func testClipSegmentsDropsSegmentsPastTheCut() {
        let segs = [StyledSegment(text: "abcd"), StyledSegment(text: "ef")]
        let out = StatusLineWidth.clipSegments(segs, to: 4)
        XCTAssertEqual(out.map(\.text), ["abcd"])
    }
}
