import XCTest
@testable import HarnessCore

final class PaneSpacingTests: XCTestCase {
    func testSavedSpacingRoundTripsAndOlderSettingsUseOriginalDefault() throws {
        let decoder = JSONDecoder()
        let saved = HarnessSettings(paneSpacing: 12)
        let decoded = try decoder.decode(HarnessSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.paneSpacing, 12)
        XCTAssertEqual(try decoder.decode(HarnessSettings.self, from: Data("{}".utf8)).paneSpacing, 8)
    }

    func testSpacingIsBoundedWhenLoadingSettings() throws {
        for (input, expected) in [(-8, 0), (80, 24)] {
            let data = Data("{\"paneSpacing\":\(input)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(HarnessSettings.self, from: data).paneSpacing, Double(expected))
        }
        XCTAssertEqual(HarnessSettings.clampedPaneSpacing(.nan), 8)
        XCTAssertEqual(HarnessSettings.clampedPaneSpacing(.infinity), 8)
    }

    func testWindowEdgesAndAdjacentPanesUseTheSameConfiguredGap() {
        for gap in [0.0, 4, 8, 12, 24] {
            let card = ChromeLayout.cardInsets(separated: true, gap: gap)
            let outer = ChromeLayout.containerPadding(separated: true, padsTop: true, gap: gap)
            XCTAssertEqual(card.leading + outer.leading, gap)
            XCTAssertEqual(card.top + outer.top, gap)
            XCTAssertEqual(card.bottom + outer.bottom, gap)
            XCTAssertEqual(card.trailing + card.leading, gap)
            let compact = ChromeLayout.cardInsets(separated: false, gap: gap)
            XCTAssertEqual(compact.leading, 0)
            XCTAssertEqual(ChromeLayout.containerPadding(separated: false, padsTop: true, gap: gap).top, 0)
        }
    }
}
