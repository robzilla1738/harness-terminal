import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class VTPreviewTextTests: XCTestCase {
    func testSGRRunsBecomeAttributesAndResetsEndThem() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let text = VTPreviewText.attributed("plain \u{1b}[0;1;38;2;255;0;0mred\u{1b}[0m after", font: font, foreground: .gray)
        XCTAssertEqual(text.string, "plain red after")
        let red = text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor
        XCTAssertEqual(red?.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(text.attribute(.foregroundColor, at: 13, effectiveRange: nil) as? NSColor, .gray)
        let bold = (text.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold)
        XCTAssertEqual(bold, true)
    }

    func testTrailingBlankRowsAreDroppedEvenWhenStyled() {
        XCTAssertEqual(VTPreviewText.lastLines("a\nb\n\u{1b}[0m  \n", 5), ["a", "b"])
    }
}
