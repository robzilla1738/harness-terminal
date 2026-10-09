import AppKit
import XCTest
import HarnessTerminalEngine
@testable import HarnessTerminalKit

@MainActor
final class AsyncFindTests: XCTestCase {
    func testReturnCommitsMarkedTextBeforeNavigatingMatches() {
        let bar = TerminalFindBar(frame: .zero)
        let editor = NSTextView()
        var navigations = 0
        bar.onNext = { navigations += 1 }
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(bar.control(NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(navigations, 0)
        editor.unmarkText()
        XCTAssertTrue(bar.control(NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(navigations, 1)
    }

    func testNewQueryReplacesPendingSearchAndInvalidRegexIsReported() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("old old old\r\n世界 family 👩🏽‍💻\r\n")
        let found = expectation(description: "Only the latest query lands")
        view.onFindResultsChanged = { _, count in
            if count > 0 { XCTAssertEqual(count, 1); found.fulfill() }
        }
        view.updateFind(query: "old")
        view.updateFind(query: "世界")
        await fulfillment(of: [found], timeout: 2)
        view.onFindResultsChanged = nil
        let invalid = expectation(description: "Regex error is visible")
        view.onFindStatusChanged = { status in
            if status?.hasPrefix("Invalid pattern:") == true { invalid.fulfill() }
        }
        view.updateFind(query: "[", options: TerminalBufferSearchOptions(isRegex: true))
        await fulfillment(of: [invalid], timeout: 2)
        view.endFind()
    }
}
