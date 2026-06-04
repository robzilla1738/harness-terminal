import XCTest
@testable import HarnessCore

final class NotchLayoutMetricsTests: XCTestCase {
    func testNonNotchScreenUsesCenteredFallbackPill() {
        let metrics = NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: 0,
            minY: 0,
            width: 1440,
            height: 900
        ))

        XCTAssertFalse(metrics.hasPhysicalNotch)
        XCTAssertEqual(metrics.closedWidth, NotchLayoutMetrics.fallbackClosedWidth)
        XCTAssertEqual(metrics.closedHeight, NotchLayoutMetrics.fallbackClosedHeight)
        XCTAssertEqual(metrics.openWidth, NotchLayoutMetrics.preferredOpenWidth)
        XCTAssertEqual(metrics.panelFrame.x + metrics.panelFrame.width / 2, 720, accuracy: 0.001)
        XCTAssertEqual(metrics.panelFrame.y + metrics.panelFrame.height, 900, accuracy: 0.001)
    }

    func testNotchScreenDerivesClosedWidthFromAuxiliaryAreas() {
        let metrics = NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: 0,
            minY: 0,
            width: 1512,
            height: 982,
            safeAreaTop: 37,
            auxiliaryTopLeftMaxX: 650,
            auxiliaryTopRightMinX: 860
        ))

        XCTAssertTrue(metrics.hasPhysicalNotch)
        XCTAssertEqual(metrics.closedWidth, 210)
        XCTAssertEqual(metrics.closedHeight, 37)
    }

    func testPeekSizeStretchesFromClosedShape() {
        let metrics = NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: 0, minY: 0, width: 1512, height: 982,
            safeAreaTop: 32,
            auxiliaryTopLeftMaxX: 656,
            auxiliaryTopRightMinX: 856
        ))

        // Peek reads as the notch stretching: wider than closed, far narrower than open,
        // and just tall enough for one row under the hardware lip.
        XCTAssertEqual(metrics.peekWidth, metrics.closedWidth + 144)
        XCTAssertEqual(metrics.peekHeight, metrics.closedHeight + 26)
        XCTAssertLessThan(metrics.peekWidth, metrics.openWidth)
        XCTAssertLessThan(metrics.peekHeight, metrics.openHeight)
        // The panel frame must already be large enough to contain the peek.
        XCTAssertLessThan(metrics.peekWidth, metrics.panelFrame.width)
        XCTAssertLessThan(metrics.peekHeight, metrics.panelFrame.height)
    }

    func testNarrowDisplayClampsOpenWidthAndKeepsTopAnchored() {
        let metrics = NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: 100,
            minY: 50,
            width: 390,
            height: 700
        ))

        XCTAssertLessThanOrEqual(metrics.openWidth, 358)
        XCTAssertEqual(metrics.panelFrame.x + metrics.panelFrame.width / 2, 295, accuracy: 0.001)
        XCTAssertEqual(metrics.panelFrame.y + metrics.panelFrame.height, 750, accuracy: 0.001)
    }
}
