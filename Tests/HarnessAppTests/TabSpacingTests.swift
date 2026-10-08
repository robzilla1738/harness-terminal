import AppKit
import XCTest
import HarnessCore
@testable import HarnessApp

@MainActor
final class TabSpacingTests: XCTestCase {
    func testTabsStayCenteredBetweenWindowTopAndPaneBorderAtEverySpacing() throws {
        let bar = TerminalTabBarView(frame: NSRect(x: 0, y: 0, width: 1000,
                                                  height: HarnessDesign.tabBarHeight))
        let tabs = [Tab(), Tab()]
        bar.reload(tabs: tabs, activeTabID: tabs[0].id)
        bar.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(bar.subviews.first { $0.accessibilityRole() == .radioButton })
        let gapAbove = bar.bounds.height - pill.frame.maxY
        XCTAssertGreaterThan(gapAbove, 0)

        for separated in [true, false] {
            for gap in stride(from: 0.0, through: 24.0, by: 0.5) {
                let card = ChromeLayout.cardInsets(separated: separated, gap: gap)
                let container = ChromeLayout.containerPadding(separated: separated, gap: gap)
                let gapBelow = pill.frame.minY + card.top + container.top
                XCTAssertEqual(gapAbove, gapBelow, accuracy: 0.001,
                               "Unbalanced tab at spacing \(gap), separated: \(separated)")
            }
        }
    }
}
