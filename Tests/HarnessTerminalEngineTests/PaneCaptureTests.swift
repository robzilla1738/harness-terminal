import XCTest
@testable import HarnessTerminalEngine

final class PaneCaptureTests: XCTestCase {
    func testTextHTMLAndVTShareOneGrid() {
        let bytes = Data("\u{1b}[1;31m<\u{1b}[0m\r\n".utf8)
        let text = PaneCapture.render(bytes: bytes, cols: 8, rows: 4, format: "text", trim: false, unwrap: false)
        let html = PaneCapture.render(bytes: bytes, cols: 8, rows: 4, format: "html", trim: true, unwrap: false)
        let vt = PaneCapture.render(bytes: bytes, cols: 8, rows: 4, format: "vt", trim: true, unwrap: false)
        XCTAssertTrue(text.contains("<"))
        XCTAssertTrue(html.hasPrefix("<pre>"))
        XCTAssertTrue(html.contains("&lt;"))
        XCTAssertTrue(html.contains("font-weight:bold"))
        XCTAssertTrue(html.contains("color:#cd0000"))
        XCTAssertTrue(vt.contains("\u{1b}[1;31m"))
        XCTAssertTrue(vt.contains("\u{1b}[0m"))
        XCTAssertFalse(vt.contains("&lt;"))
    }

    func testTrimDropsTrailingSpacesAndBlankLines() {
        let bytes = Data("hi  \r\n\r\n".utf8)
        let raw = PaneCapture.render(bytes: bytes, cols: 8, rows: 4, format: "text", trim: false, unwrap: false)
        let trimmed = PaneCapture.render(bytes: bytes, cols: 8, rows: 4, format: "text", trim: true, unwrap: false)
        XCTAssertTrue(raw.contains("hi"))
        XCTAssertEqual(trimmed, "hi")
    }

    func testUnwrapJoinsASoftWrappedRow() {
        let bytes = Data("abcdef".utf8)
        let wrapped = PaneCapture.render(bytes: bytes, cols: 3, rows: 4, format: "text", trim: true, unwrap: false)
        let joined = PaneCapture.render(bytes: bytes, cols: 3, rows: 4, format: "text", trim: true, unwrap: true)
        XCTAssertTrue(wrapped.contains("abc"))
        XCTAssertTrue(wrapped.contains("def"))
        XCTAssertNotEqual(wrapped, joined)
        XCTAssertTrue(joined.contains("abcdef"))
    }
}
