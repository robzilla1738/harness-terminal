import AppKit
import XCTest
import HarnessCore
@testable import HarnessApp

@MainActor
final class TabDragTests: XCTestCase {
    func testStraightDownDragTearsOffWithoutSelectingFirst() throws {
        let (bar, delegate, tabs) = makeBar()
        let pill = try XCTUnwrap(bar.subviews.first { $0.accessibilityRole() == .radioButton })
        let start = NSPoint(x: pill.frame.midX, y: pill.frame.midY)
        pill.mouseDown(with: event(.leftMouseDown, at: start))
        pill.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: start.x, y: -100)))
        pill.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: start.x, y: -100)))
        XCTAssertEqual(delegate.tornOff, tabs[0].id)
        XCTAssertNil(delegate.selected)
    }

    func testSingleDragReordersInactiveTab() throws {
        let (bar, delegate, tabs) = makeBar()
        let pills = bar.subviews.filter { $0.accessibilityRole() == .radioButton }
        let pill = try XCTUnwrap(pills.first)
        let start = NSPoint(x: pill.frame.midX, y: pill.frame.midY)
        let end = NSPoint(x: pills[1].frame.midX + 10, y: start.y)
        pill.mouseDown(with: event(.leftMouseDown, at: start))
        // A snapshot arriving after mouse-down must retain the gesture's view.
        bar.reload(tabs: tabs, activeTabID: tabs[1].id)
        XCTAssertTrue(pill.superview === bar)
        pill.mouseDragged(with: event(.leftMouseDragged, at: end))
        pill.mouseUp(with: event(.leftMouseUp, at: end))
        XCTAssertEqual(delegate.reordered, tabs[0].id)
        XCTAssertEqual(delegate.index, 1)
    }

    private func makeBar() -> (TerminalTabBarView, DragDelegate, [Tab]) {
        let bar = TerminalTabBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 64))
        let delegate = DragDelegate()
        bar.delegate = delegate
        let tabs = [Tab(), Tab()]
        bar.reload(tabs: tabs, activeTabID: tabs[1].id)
        bar.layoutSubtreeIfNeeded()
        return (bar, delegate, tabs)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

@MainActor
private final class DragDelegate: TerminalTabBarDelegate {
    var selected: TabID?
    var tornOff: TabID?
    var reordered: TabID?
    var index: Int?
    func tabBarDidSelect(tabID: TabID) { selected = tabID }
    func tabBarDidRequestNewTab() {}
    func tabBarDidReorder(tabID: TabID, toIndex: Int) { reordered = tabID; index = toIndex }
    func tabBarDidReceivePane(_ surfaceID: SurfaceID, onTab tabID: TabID?) {}
    func tabBarDidTearOff(tabID: TabID, at screenPoint: NSPoint) { tornOff = tabID }
}
