import XCTest
@testable import HarnessCore

final class SGRMouseTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testParsePress() {
        // ESC [ < 0 ; 10 ; 5 M  — left button press at col 10, row 5.
        let e = SGRMouse.parse(bytes("\u{1b}[<0;10;5M"))
        XCTAssertEqual(e, SGRMouseEvent(button: 0, column: 10, row: 5, release: false, motion: false, wheel: false, shift: false, meta: false, control: false))
    }

    func testParseReleaseAndModifiers() {
        // button param 22 = 0b10110 → button low bits 0b10=2 (right), shift(4)+meta(8)... 22 = 16+4+2 = ctrl+shift+button2.
        let e = SGRMouse.parse(bytes("\u{1b}[<22;3;4m"))
        XCTAssertEqual(e?.button, 2)
        XCTAssertTrue(e?.release == true)
        XCTAssertTrue(e?.shift == true)
        XCTAssertTrue(e?.control == true)
        XCTAssertFalse(e?.meta == true)
    }

    func testParseMotionAndWheel() {
        let motion = SGRMouse.parse(bytes("\u{1b}[<32;1;1M")) // 32 = motion bit
        XCTAssertTrue(motion?.motion == true)
        let wheel = SGRMouse.parse(bytes("\u{1b}[<64;1;1M")) // 64 = wheel up
        XCTAssertTrue(wheel?.wheel == true)
    }

    func testParseRejectsNonMouse() {
        XCTAssertNil(SGRMouse.parse(bytes("\u{1b}[A")))         // cursor up
        XCTAssertNil(SGRMouse.parse(bytes("\u{1b}[<0;10M")))    // too few params
        XCTAssertNil(SGRMouse.parse(bytes("\u{1b}[<0;x;5M")))   // non-numeric
    }

    func testRouteToPane() {
        let s = UUID()
        let left = PaneRect(paneID: UUID(), surfaceID: s, x: 0, y: 0, cols: 10, rows: 8)
        let right = PaneRect(paneID: UUID(), surfaceID: s, x: 11, y: 0, cols: 10, rows: 8)
        // Column 13 (1-based) = col0 12 → inside right pane (x 11..20), local col 1.
        let r = SGRMouse.route(column: 13, row: 3, rects: [left, right])
        XCTAssertEqual(r?.index, 1)
        XCTAssertEqual(r?.localColumn, 1)
        XCTAssertEqual(r?.localRow, 2)
        // Column 11 (1-based) = col0 10 → the divider between panes → no pane.
        XCTAssertNil(SGRMouse.route(column: 11, row: 3, rects: [left, right]))
        // Inside left pane.
        XCTAssertEqual(SGRMouse.route(column: 1, row: 1, rects: [left, right])?.index, 0)
    }
}
