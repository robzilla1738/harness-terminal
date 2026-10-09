import AppKit
import XCTest
@testable import HarnessTerminalKit

@MainActor
final class TerminalScrollbarTests: XCTestCase {
    func testBothSystemStylesHideAfterScrollingStops() async throws {
        for style: NSScroller.Style in [.legacy, .overlay] {
            let scrollbar = TerminalScrollbarView(frame: .zero)
            scrollbar.scrollerStyle = style
            scrollbar.show(topLine: 40, totalLines: 120, visibleRows: 40, fadeOutAfter: 0.01)
            XCTAssertFalse(scrollbar.isHidden)
            XCTAssertEqual(scrollbar.doubleValue, 0.5, accuracy: 0.001)
            XCTAssertEqual(scrollbar.knobProportion, 1.0 / 3, accuracy: 0.001)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(scrollbar.isHidden)
        }
    }

    func testContinuedScrollingResetsTheHideDeadline() async throws {
        let scrollbar = TerminalScrollbarView(frame: .zero)
        scrollbar.show(topLine: 0, totalLines: 100, visibleRows: 20, fadeOutAfter: 0.01)
        scrollbar.show(topLine: 80, totalLines: 100, visibleRows: 20, fadeOutAfter: 0.3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(scrollbar.isHidden)
        XCTAssertEqual(scrollbar.doubleValue, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(scrollbar.isHidden)
    }

    func testNoScrollbackHidesImmediately() {
        let scrollbar = TerminalScrollbarView(frame: .zero)
        scrollbar.show(topLine: 0, totalLines: 100, visibleRows: 20)
        scrollbar.show(topLine: 0, totalLines: 20, visibleRows: 20)
        XCTAssertTrue(scrollbar.isHidden)
        XCTAssertFalse(scrollbar.isEnabled)
    }
}
