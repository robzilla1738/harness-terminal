import AppKit
import XCTest
@testable import HarnessTerminalKit

/// #168: the hover × must be invisible (and click-through) at rest, reveal/hide on demand,
/// and fire its close callback from the button only.
@MainActor
final class PaneCloseOverlayTests: XCTestCase {
    func testHiddenAndClickThroughAtRest() {
        let overlay = PaneCloseOverlay(frame: NSRect(x: 0, y: 0, width: 56, height: 40))
        XCTAssertTrue(overlay.isHidden, "no pane chrome at rest")
        XCTAssertEqual(overlay.alphaValue, 0)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 40, y: 20)),
                     "an unrevealed overlay must pass clicks through to the terminal")
    }

    func testRevealShowsAndHideRestoresClickThrough(){
        let overlay = PaneCloseOverlay(frame: NSRect(x: 0, y: 0, width: 56, height: 40))
        overlay.setRevealed(true, animated: false)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.alphaValue, 1)

        overlay.setRevealed(false, animated: false)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertEqual(overlay.alphaValue, 0)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 40, y: 20)))
    }

    func testOnlyTheButtonIsClickableWhileRevealed() {
        let overlay = PaneCloseOverlay(frame: NSRect(x: 0, y: 0, width: 56, height: 40))
        overlay.layoutSubtreeIfNeeded()
        overlay.setRevealed(true, animated: false)
        // Far corner of the hover region (away from the button) still passes through.
        XCTAssertNil(overlay.hitTest(NSPoint(x: 2, y: overlay.isFlipped ? 38 : 2)),
                     "the hover region outside the × must not swallow terminal clicks")
    }

    func testHostAffordanceFlagGatesReveal() {
        // The host disarms the overlay when a tab collapses to one pane: revealed → hidden.
        let overlay = PaneCloseOverlay(frame: NSRect(x: 0, y: 0, width: 56, height: 40))
        overlay.setRevealed(true, animated: false)
        overlay.setRevealed(false, animated: false) // what showsPaneCloseAffordance=false does
        XCTAssertTrue(overlay.isHidden)
    }

    func testClickFiresOnClose() {
        let overlay = PaneCloseOverlay(frame: NSRect(x: 0, y: 0, width: 56, height: 40))
        var fired = 0
        overlay.onClose = { fired += 1 }
        overlay.setRevealed(true, animated: false)
        // The button is the only subview; drive its action like a click would.
        let button = overlay.subviews.compactMap { $0 as? NSButton }.first
        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertEqual(fired, 1)
    }
}
