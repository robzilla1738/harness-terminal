import XCTest
@testable import HarnessTerminalRenderer

final class GlyphRasterizerTests: XCTestCase {
    // Menlo ships with every macOS, so these tests are environment-stable.
    private let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)

    func testMetricsArePositiveAndMonospace() {
        let m = rasterizer.metrics()
        XCTAssertGreaterThan(m.width, 0)
        XCTAssertGreaterThan(m.height, 0)
        XCTAssertGreaterThan(m.ascent, 0)
        XCTAssertGreaterThan(m.descent, 0)
        // Line height should be at least ascent + descent.
        XCTAssertGreaterThanOrEqual(m.height, (m.ascent + m.descent).rounded(.up) - 1)
    }

    func testRasterizesLetterWithInk() {
        guard let glyph = rasterizer.rasterize(codepoint: UInt32(UnicodeScalar("A").value)) else {
            return XCTFail("expected a glyph for 'A'")
        }
        XCTAssertGreaterThan(glyph.width, 0)
        XCTAssertGreaterThan(glyph.height, 0)
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height)
        XCTAssertTrue(glyph.coverage.contains { $0 > 0 }, "glyph should have non-zero coverage")
        // 'A' sits above the baseline.
        XCTAssertGreaterThan(glyph.bearingY, 0)
    }

    func testSpaceHasNoInk() {
        XCTAssertNil(rasterizer.rasterize(codepoint: UInt32(UnicodeScalar(" ").value)))
    }

    func testBoldVariantRasterizes() {
        let normal = rasterizer.rasterize(codepoint: UInt32(UnicodeScalar("W").value))
        let bold = rasterizer.rasterize(codepoint: UInt32(UnicodeScalar("W").value), bold: true)
        XCTAssertNotNil(normal)
        XCTAssertNotNil(bold)
    }

    func testFallbackRendersCJK() {
        // Menlo lacks CJK; this exercises the CTFontCreateForString fallback path.
        let glyph = rasterizer.rasterize(codepoint: 0x4E16) // 世
        XCTAssertNotNil(glyph)
        XCTAssertTrue(glyph?.coverage.contains { $0 > 0 } ?? false)
    }

    func testInvalidScalarReturnsNil() {
        XCTAssertNil(rasterizer.rasterize(codepoint: 0xD800)) // lone surrogate
    }

    // MARK: Shaping (ligature path)

    func testShapeEmptyIsEmpty() {
        XCTAssertTrue(rasterizer.shape("", bold: false, italic: false).isEmpty)
    }

    func testShapePlainTextMapsOneGlyphPerCharacterInOrder() {
        // No ligatures in Menlo: "ab" shapes to 2 glyphs whose source indices are 0 and 1,
        // so each lands on its own cell (grid alignment preserved).
        let shaped = rasterizer.shape("ab", bold: false, italic: false)
        XCTAssertEqual(shaped.count, 2)
        XCTAssertEqual(shaped.map(\.utf16Index), [0, 1])
        for sg in shaped {
            XCTAssertNotNil(rasterizer.rasterize(glyph: sg.glyph, font: sg.font))
        }
    }
}
