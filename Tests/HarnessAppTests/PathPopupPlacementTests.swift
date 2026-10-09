import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class PathPopupPlacementTests: XCTestCase {
    func testPopupStartsImmediatelyBelowTheCursor() {
        let cursor = NSRect(x: 300, y: 600, width: 8, height: 18)
        let frame = DirectoryBrowserController.popupFrame(anchor: cursor, available: NSRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.minX, cursor.minX - 8)
        XCTAssertEqual(frame.maxY, cursor.minY - 5)
    }

    func testBottomRightCursorFlipsAboveAndKeepsWholePopupVisible() {
        let available = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let cursor = NSRect(x: 950, y: 40, width: 8, height: 18)
        let frame = DirectoryBrowserController.popupFrame(anchor: cursor, available: available)
        XCTAssertEqual(frame.minY, cursor.maxY + 5)
        XCTAssertTrue(available.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testFilteringKeepsPopupOnTheSameSideOfTheCursor() {
        let cursor = NSRect(x: 300, y: 250, width: 8, height: 18)
        let available = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let full = DirectoryBrowserController.popupFrame(anchor: cursor, available: available)
        let filtered = DirectoryBrowserController.popupFrame(anchor: cursor, available: available, visibleRows: 1)
        XCTAssertEqual(full.minY, cursor.maxY + 5)
        XCTAssertEqual(filtered.minY, full.minY)
        XCTAssertLessThan(filtered.height, full.height)
    }

    func testNarrowWindowOnNegativeOriginDisplayContainsPopup() {
        let available = NSRect(x: -900, y: -400, width: 320, height: 320)
        let frame = DirectoryBrowserController.popupFrame(anchor: NSRect(x: -550, y: -250, width: 8, height: 18), available: available)
        XCTAssertEqual(frame.width, 304)
        XCTAssertTrue(available.insetBy(dx: 8, dy: 8).contains(frame))
    }
}
