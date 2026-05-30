import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// OSC 52 (`set-clipboard`): a program copies to the system clipboard by writing
/// `ESC ] 52 ; c ; <base64> BEL`. The engine decodes and reports the text; the
/// consumer (GUI / compositor) gates on the `set-clipboard` option.
final class ClipboardOSCTests: XCTestCase {
    private func encoded(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    func testOSC52SetsClipboard() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        term.feed("\u{1b}]52;c;\(encoded("hello world"))\u{07}")
        XCTAssertEqual(captured, "hello world")
    }

    func testOSC52WithStringTerminator() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        // ST (ESC \) terminator instead of BEL.
        term.feed("\u{1b}]52;c;\(encoded("via ST"))\u{1b}\\")
        XCTAssertEqual(captured, "via ST")
    }

    func testOSC52QueryIsIgnored() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var fired = false
        term.onSetClipboard = { _ in fired = true }
        term.feed("\u{1b}]52;c;?\u{07}")
        XCTAssertFalse(fired, "a clipboard query must not fire a set")
    }

    func testOSC52IgnoresInvalidBase64() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var fired = false
        term.onSetClipboard = { _ in fired = true }
        term.feed("\u{1b}]52;c;@@not-base64@@\u{07}")
        XCTAssertFalse(fired)
    }
}
