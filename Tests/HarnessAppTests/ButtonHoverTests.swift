import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class ButtonHoverTests: XCTestCase {
    func testIconButtonClearsStaleHoverWhenTrackingIsRebuilt() throws {
        let button = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.style = .glyph
        try assertClearsHover(button)
    }

    func testPillButtonClearsStaleHoverWhenTrackingIsRebuilt() throws {
        let button = HarnessPillButton(title: "Cancel", kind: .secondary)
        button.frame = NSRect(x: 0, y: 0, width: 90, height: 30)
        try assertClearsHover(button)
    }

    private func assertClearsHover(_ button: NSButton) throws {
        let resting = try XCTUnwrap(button.layer?.backgroundColor)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        button.mouseEntered(with: event)
        XCTAssertNotEqual(button.layer?.backgroundColor, resting)
        // Simulate a control removed/hidden by its action without a mouseExited event.
        button.updateTrackingAreas()
        XCTAssertEqual(button.layer?.backgroundColor, resting)
        XCTAssertTrue(button.trackingAreas.contains { $0.options.contains(.enabledDuringMouseDrag) })
    }
}
