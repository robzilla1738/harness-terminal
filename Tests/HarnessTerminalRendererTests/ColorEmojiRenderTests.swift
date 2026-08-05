import CoreGraphics
import CoreText
import XCTest
@testable import HarnessTerminalRenderer

/// Color-font (emoji) rasterization. The regression these guard: a color glyph drawn into the
/// grayscale coverage context keeps its SHAPE but loses every channel, and the renderer then
/// tints the leftover mask with the cell foreground — so ❌ ✅ ⚠️ came out monochrome while
/// ordinary ANSI-colored text was fine.
final class ColorEmojiRenderTests: XCTestCase {
    // Menlo + Apple Color Emoji ship with every macOS, so these tests are environment-stable.
    private let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)

    private static let crossMark: UInt32 = 0x274C      // ❌ single scalar
    private static let checkMark: UInt32 = 0x2705      // ✅ single scalar

    func testEmojiRasterizesIntoTheColorPath() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(codepoint: Self.crossMark))

        XCTAssertTrue(glyph.isColor)
        // Color glyphs are RGBA, so the buffer is 4 bytes per pixel rather than 1.
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height * 4)
    }

    /// The core assertion: the bitmap actually carries color. A grayscale rasterization has
    /// r == g == b in every pixel, so finding one pixel where the channels differ is exactly
    /// the property the old path could not satisfy.
    func testEmojiBitmapCarriesColorChannels() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(codepoint: Self.crossMark))
        let px = stride(from: 0, to: glyph.coverage.count, by: 4)

        let hasChroma = px.contains { i in
            let r = glyph.coverage[i], g = glyph.coverage[i + 1], b = glyph.coverage[i + 2]
            return r != g || g != b
        }

        XCTAssertTrue(hasChroma, "emoji rasterized without chroma — the color path was skipped")
    }

    /// Premultiplied alpha invariant: no channel may exceed alpha. The shader divides by alpha to
    /// undo the premultiply, so a violation here would show up as blown-out color on screen.
    func testEmojiBitmapIsPremultiplied() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(codepoint: Self.checkMark))

        for i in stride(from: 0, to: glyph.coverage.count, by: 4) {
            let a = glyph.coverage[i + 3]
            XCTAssertLessThanOrEqual(glyph.coverage[i], a)
            XCTAssertLessThanOrEqual(glyph.coverage[i + 1], a)
            XCTAssertLessThanOrEqual(glyph.coverage[i + 2], a)
        }
    }

    /// A variation-selector sequence (U+26A0 U+FE0F) is a multi-scalar CLUSTER, so it takes the
    /// CTLine path rather than the single-glyph one — both need the color treatment.
    func testVariationSelectorEmojiClusterRasterizesAsColor() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(cluster: "\u{26A0}\u{FE0F}"))

        XCTAssertTrue(glyph.isColor)
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height * 4)
    }

    /// The monochrome hot path must be untouched: ordinary text stays 1-byte coverage so it keeps
    /// its texture footprint, its upload bandwidth, and its foreground tinting.
    func testAsciiGlyphStaysOnTheCoveragePath() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(codepoint: UInt32(UnicodeScalar("A").value)))

        XCTAssertFalse(glyph.isColor)
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height)
    }

    /// A Thai cluster is composed by CoreText from a non-color font, so the cluster path must not
    /// promote it to RGBA just because it went through CTLine.
    func testNonColorClusterStaysOnTheCoveragePath() throws {
        let glyph = try XCTUnwrap(rasterizer.rasterize(cluster: "\u{0E19}\u{0E49}"))

        XCTAssertFalse(glyph.isColor)
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height)
    }

    func testColorFontDetection() {
        let emoji = CTFontCreateWithName("AppleColorEmoji" as CFString, 14, nil)
        let menlo = CTFontCreateWithName("Menlo" as CFString, 14, nil)

        XCTAssertTrue(GlyphRasterizer.isColorFont(emoji))
        XCTAssertFalse(GlyphRasterizer.isColorFont(menlo))
    }
}
