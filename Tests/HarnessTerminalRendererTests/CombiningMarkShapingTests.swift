import CoreText
import XCTest
@testable import HarnessTerminalRenderer

/// The CoreText shaping path must compose a base + combining marks into glyphs. This is the path
/// `emitLigatedGlyphs` feeds; here we exercise the shaper directly with a composed cluster.
final class CombiningMarkShapingTests: XCTestCase {
    func testThaiClusterShapesToGlyphs() {
        // Thonburi ships with every macOS and covers Thai; shape "ที่" (base + vowel + tone).
        let rasterizer = GlyphRasterizer(fontFamily: "Thonburi", size: 14, scale: 2)
        let glyphs = rasterizer.shape("ที่", bold: false, italic: false)
        XCTAssertFalse(glyphs.isEmpty, "Thai cluster must produce shaped glyphs")
        for g in glyphs { XCTAssertGreaterThanOrEqual(g.utf16Index, 0) }
    }

    func testLatinDiacriticShapesToGlyphs() {
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let glyphs = rasterizer.shape("e\u{0301}", bold: false, italic: false)
        XCTAssertFalse(glyphs.isEmpty, "Latin base + combining diacritic must produce shaped glyphs")
        for g in glyphs { XCTAssertGreaterThanOrEqual(g.utf16Index, 0) }
    }
}
