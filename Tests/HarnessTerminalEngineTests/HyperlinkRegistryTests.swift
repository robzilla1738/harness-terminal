import XCTest
@testable import HarnessTerminalEngine

/// OSC 8 hyperlink registry: ID stability, explicit-id reuse, and the flood-bound purge.
final class HyperlinkRegistryTests: XCTestCase {
    private func openLink(_ uri: String, id: String? = nil) -> String {
        let params = id.map { "id=\($0)" } ?? ""
        return "\u{1b}]8;\(params);\(uri)\u{1b}\\"
    }

    func testSameURIReusesOneID() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        term.feed("\(openLink("https://example.com"))A\u{1b}]8;;\u{1b}\\ \(openLink("https://example.com"))B")
        let grid = term.readGrid()!
        let first = grid.cell(row: 0, col: 0)!.hyperlinkID
        let second = grid.cell(row: 0, col: 2)!.hyperlinkID
        XCTAssertNotEqual(first, 0)
        XCTAssertEqual(second, first, "identical URI must reuse the registry entry")
    }

    func testExplicitIDSharesAcrossRunsAndDistinguishesURIs() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        term.feed("\(openLink("https://a.example", id: "x"))A\u{1b}]8;;\u{1b}\\\(openLink("https://a.example", id: "x"))B\(openLink("https://b.example", id: "x"))C")
        let grid = term.readGrid()!
        let a = grid.cell(row: 0, col: 0)!.hyperlinkID
        let b = grid.cell(row: 0, col: 1)!.hyperlinkID
        let c = grid.cell(row: 0, col: 2)!.hyperlinkID
        XCTAssertEqual(b, a, "same id= + same URI is one link across runs")
        XCTAssertNotEqual(c, a, "same id= but different URI is a different link")
    }

    func testFloodPurgeNeverAliasesStaleCellIDs() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // Stamp one cell with a pre-purge link.
        term.feed("\(openLink("https://victim.example"))V\u{1b}]8;;\u{1b}\\")
        let victimID = term.readGrid()!.cell(row: 0, col: 0)!.hyperlinkID
        XCTAssertEqual(term.hyperlinkURL(id: victimID), "https://victim.example")
        // Flood the registry past the 16,384-entry bound to force the purge.
        var flood = ""
        flood.reserveCapacity(16_500 * 40)
        for i in 0 ..< 16_500 {
            flood += "\u{1b}]8;;https://flood.example/\(i)\u{1b}\\\u{1b}]8;;\u{1b}\\"
        }
        term.feed(flood)
        // The stale cell ID must now resolve to nothing — never to a flood URL.
        XCTAssertNil(term.hyperlinkURL(id: victimID),
                     "pre-purge IDs must go dead, not alias a post-purge URL")
        // A fresh link after the purge gets a brand-new ID, beyond every pre-purge ID.
        term.feed("\r\n\(openLink("https://fresh.example"))F")
        let grid = term.readGrid()!
        let freshID = grid.cell(row: 1, col: 0)!.hyperlinkID
        XCTAssertGreaterThan(freshID, victimID, "ID counter must not reset at the purge")
        XCTAssertEqual(term.hyperlinkURL(id: freshID), "https://fresh.example")
    }
}
