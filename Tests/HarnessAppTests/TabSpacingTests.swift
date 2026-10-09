import AppKit
import XCTest
import HarnessCore
@testable import HarnessApp

@MainActor
final class TabSpacingTests: XCTestCase {
    func testHidingMachineIndicatorReturnsItsSpaceToTabs() throws {
        let coordinator = SessionCoordinator.shared
        let saved = coordinator.settings.showMachineIndicator
        defer { coordinator.settings.showMachineIndicator = saved }
        coordinator.settings.showMachineIndicator = true
        let bar = TerminalTabBarView(frame: NSRect(x: 0, y: 0, width: 960, height: HarnessDesign.tabBarHeight))
        let tab = Tab()
        bar.reload(tabs: [tab], activeTabID: tab.id)
        bar.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(bar.subviews.first { $0.accessibilityRole() == .radioButton })
        let originalX = pill.frame.minX
        coordinator.settings.showMachineIndicator = false
        bar.applyChrome()
        bar.layoutSubtreeIfNeeded()
        XCTAssertLessThan(pill.frame.minX, originalX - 100)
        XCTAssertTrue(try XCTUnwrap(bar.subviews.compactMap { $0 as? MachineIndicatorButton }.first).isHidden)
    }

    func testMachineIndicatorLeavesRoomForTabsAndControlsAtNarrowWidths() throws {
        let coordinator = SessionCoordinator.shared
        let saved = coordinator.settings.showMachineIndicator
        defer { coordinator.settings.showMachineIndicator = saved }
        coordinator.settings.showMachineIndicator = true
        for width: CGFloat in [480, 700, 960] {
            let bar = TerminalTabBarView(frame: NSRect(x: 0, y: 0, width: width, height: HarnessDesign.tabBarHeight))
            bar.leadingInset = HarnessDesign.trafficLightClearance
            let tabs = [Tab(), Tab(), Tab()]
            bar.reload(tabs: tabs, activeTabID: tabs[2].id)
            for owner in [DaemonSidebar.localID, "test-remote"] {
                bar.updateMachine(owner: owner)
                bar.layoutSubtreeIfNeeded()
                let indicator = try XCTUnwrap(bar.subviews.compactMap { $0 as? MachineIndicatorButton }.first)
                XCTAssertEqual(indicator.isRemote, owner != DaemonSidebar.localID)
                XCTAssertEqual(indicator.compact, width < 720)
                if !indicator.compact && !indicator.isRemote {
                    indicator.layoutSubtreeIfNeeded()
                    let label = try XCTUnwrap(indicator.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "This Mac" })
                    XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width)
                }
                let pills = bar.subviews.filter { $0.accessibilityRole() == .radioButton && !$0.isHidden }
                XCTAssertFalse(pills.isEmpty)
                for pill in pills {
                    XCTAssertGreaterThan(pill.frame.minX, indicator.frame.maxX)
                    XCTAssertLessThanOrEqual(pill.frame.maxX, width - 40)
                }
            }
        }
    }

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
