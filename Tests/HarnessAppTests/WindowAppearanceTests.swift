import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class WindowAppearanceTests: XCTestCase {
    private func makePanel() -> QuickTerminalPanel {
        _ = NSApplication.shared
        return QuickTerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testQuickTerminalCanTransitionBetweenOpaqueAndTranslucent() {
        let panel = makePanel()
        defer { panel.close() }

        // Reuse the same panel, as the controller does across settings changes and toggles.
        for opacity: Float in [1, 0.8, 1, 0.5] {
            WindowAppearance.applyTransparency(opacity: opacity, blur: 20, opaqueBackground: .red, to: panel)
            let opaque = opacity == 1
            XCTAssertEqual(panel.isOpaque, opaque)
            XCTAssertEqual(panel.backgroundColor, opaque ? .red : .clear)
            XCTAssertEqual(panel.hasShadow, opaque)
        }
    }

    func testOpacityThresholdMatchesMainWindow() {
        let panel = makePanel()
        defer { panel.close() }

        for (opacity, opaque): (Float, Bool) in [(0.998, false), (0.999, true), (2, true), (-1, false)] {
            WindowAppearance.applyTransparency(opacity: opacity, blur: 20, opaqueBackground: .blue, to: panel)
            XCTAssertEqual(panel.isOpaque, opaque, "opacity: \(opacity)")
            XCTAssertEqual(panel.backgroundColor, opaque ? .blue : .clear)
        }
    }

    func testOpaquePanelUpdatesItsBackgroundColor() {
        let panel = makePanel()
        defer { panel.close() }

        for color in [NSColor.red, .blue] {
            WindowAppearance.applyTransparency(opacity: 1, blur: 20, opaqueBackground: color, to: panel)
            XCTAssertEqual(panel.backgroundColor, color)
        }
    }
}
