import CoreGraphics
import CoreText
import XCTest
@testable import HarnessTerminalRenderer

/// Regression coverage for #37 — Nerd Font / Powerline glyphs (Private Use Area codepoints) must
/// render from the bundled "Symbols Nerd Font Mono" fallback even when the primary font isn't a
/// Nerd Font, instead of a CoreText LastResort "missing glyph" box (tofu).
final class NerdFontFallbackTests: XCTestCase {
    /// Register the bundled symbol font process-wide. The app activates it via Info.plist's
    /// `ATSApplicationFontsPath`, which doesn't apply to the headless test runner, so we register
    /// it from the repo resource directly. Runs once per process; "already registered" is fine.
    private static let symbolFontAvailable: Bool = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HarnessTerminalRendererTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("Apps/Harness/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var errorRef: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef) { return true }
        // kCTFontManagerErrorAlreadyRegistered (105) means a prior test run registered it — OK.
        if let err = errorRef?.takeRetainedValue(), CFErrorGetCode(err) == 105 { return true }
        return false
    }()

    func testIsNerdFontCodepointCoversPUARanges() {
        XCTAssertTrue(GlyphRasterizer.isNerdFontCodepoint(0xE0B0))   // Powerline right separator
        XCTAssertTrue(GlyphRasterizer.isNerdFontCodepoint(0xE000))   // BMP PUA start
        XCTAssertTrue(GlyphRasterizer.isNerdFontCodepoint(0xF8FF))   // BMP PUA end
        XCTAssertTrue(GlyphRasterizer.isNerdFontCodepoint(0xF0001))  // PUA-A plane (Material icons)
        XCTAssertFalse(GlyphRasterizer.isNerdFontCodepoint(UInt32(UnicodeScalar("A").value)))
        XCTAssertFalse(GlyphRasterizer.isNerdFontCodepoint(0x4E16))  // CJK
        XCTAssertFalse(GlyphRasterizer.isNerdFontCodepoint(0x2500))  // box-drawing
    }

    func testPowerlineGlyphRendersFromSymbolFallbackWithNonNerdPrimary() throws {
        try XCTSkipUnless(Self.symbolFontAvailable, "bundled Symbols Nerd Font Mono not available")
        // Menlo ships with every macOS and has no Powerline glyphs — exactly the #37 setup
        // (a non-Nerd primary font). U+E0B0 must still render, sourced from the symbol fallback.
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        guard let glyph = rasterizer.rasterize(codepoint: 0xE0B0) else {
            return XCTFail("expected the bundled symbol font to cover U+E0B0 (Powerline)")
        }
        XCTAssertGreaterThan(glyph.width, 0)
        XCTAssertGreaterThan(glyph.height, 0)
        XCTAssertEqual(glyph.coverage.count, glyph.width * glyph.height)
        XCTAssertTrue(glyph.coverage.contains { $0 > 0 }, "Powerline glyph must have ink, not be blank or tofu")
    }
}
