import CoreGraphics
import CoreText
import XCTest
@testable import HarnessTerminalRenderer

final class GlyphRasterizerTests: XCTestCase {
    private struct ShapedGlyphSignature: Equatable {
        var glyph: CGGlyph
        var utf16Index: Int
        var fontName: String
        var fontSize: CGFloat
    }

    // Menlo ships with every macOS, so these tests are environment-stable.
    private let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
    private let screenshotMetricStrings = [
        "hello",
        "Sisyphus - Ultraworker · GPT-5.5 · low",
        "Greeting and context setup",
        "iiii WWWW ||||",
    ]

    func testMetricsArePositiveAndMonospace() {
        let m = rasterizer.metrics()
        XCTAssertGreaterThan(m.width, 0)
        XCTAssertGreaterThan(m.height, 0)
        XCTAssertGreaterThan(m.ascent, 0)
        XCTAssertGreaterThan(m.descent, 0)
        // Line height should be at least ascent + descent.
        XCTAssertGreaterThanOrEqual(m.height, (m.ascent + m.descent).rounded(.up) - 1)
    }

    func testUnavailableConfiguredFontReportsFallbackStatus() {
        let missingFamily = "Harness Missing Font \(UUID().uuidString)"
        let resolved = TerminalFontResolver.resolve(fontFamily: missingFamily, size: 14)
        let missingRasterizer = GlyphRasterizer(fontFamily: missingFamily, size: 14, scale: 2)

        XCTAssertTrue(resolved.fallbackUsed)
        XCTAssertEqual(resolved.requestedFamily, missingFamily)
        XCTAssertNotEqual(resolved.effectiveFamily, missingFamily)
        XCTAssertNotNil(resolved.fallbackFamily)
        XCTAssertEqual(missingRasterizer.fontResolution, resolved)
    }

    func testCompactUnavailableNerdFontDoesNotResolveToHelvetica() {
        let resolved = TerminalFontResolver.resolve(fontFamily: "JetBrainsMonoNerdFont", size: 14)

        XCTAssertTrue(resolved.fallbackUsed)
        XCTAssertNotEqual(resolved.effectiveFamily, "Helvetica")
        XCTAssertNotEqual(resolved.effectivePostScriptName, "Helvetica")
        XCTAssertNotEqual(resolved.effectiveFamily, "JetBrainsMonoNerdFont")
    }

    func testRasterizerCanUsePreResolvedFontIdentity() {
        let resolved = TerminalFontResolver.resolve(fontFamily: "Menlo", size: 14)
        let rasterizer = GlyphRasterizer(resolvedFont: resolved, scale: 2)

        XCTAssertEqual(rasterizer.fontResolution, resolved)
    }

    func testDefaultFontResolutionMatchesRasterizerConstruction() {
        let resolved = TerminalFontResolver.resolve(
            fontFamily: TerminalFontResolver.defaultFontFamily,
            size: 16
        )
        let defaultRasterizer = GlyphRasterizer(
            fontFamily: TerminalFontResolver.defaultFontFamily,
            size: 16,
            scale: 2
        )

        XCTAssertEqual(defaultRasterizer.fontResolution, resolved)
        XCTAssertFalse(resolved.effectiveFamily.isEmpty)
        XCTAssertFalse(resolved.effectivePostScriptName.isEmpty)
    }

    func testScreenshotLikeStringsDoNotExceedMonospaceCellBudget() {
        let resolved = TerminalFontResolver.resolve(
            fontFamily: TerminalFontResolver.defaultFontFamily,
            size: 16
        )
        let metricRasterizer = GlyphRasterizer(
            fontFamily: TerminalFontResolver.defaultFontFamily,
            size: 16,
            scale: 2
        )
        let metrics = metricRasterizer.metrics()
        let font = CTFontCreateWithName(resolved.effectivePostScriptName as CFString, 16, nil)
        var evidence: [String] = [
            "requested=\(resolved.requestedFamily)",
            "effective=\(resolved.effectiveFamily)",
            "postScript=\(resolved.effectivePostScriptName)",
            "fallbackUsed=\(resolved.fallbackUsed)",
            "cellWidth=\(metrics.width)",
        ]

        for text in screenshotMetricStrings {
            let width = typographicWidth(text, font: font)
            let cellBudget = CGFloat(text.count) * metrics.width
            evidence.append("\(text) | glyphWidth=\(width) | cellBudget=\(cellBudget)")
            XCTAssertLessThanOrEqual(
                width,
                cellBudget + 0.5,
                "\(text) should fit inside its monospace cell budget without extra spacing"
            )
        }
        emitEvidence(evidence.joined(separator: "\n"))
    }

    func testEmptyFamilyFallsBackToMonospaceMenlo() {
        // An empty (or whitespace-only) family must resolve like an unknown family — to Menlo —
        // not silently accept CoreText's proportional default whose advances break the grid.
        XCTAssertEqual(GlyphRasterizer(fontFamily: "", size: 14, scale: 2).fontResolution.effectiveFamily, "Menlo")
        XCTAssertEqual(GlyphRasterizer(fontFamily: "   ", size: 14, scale: 2).fontResolution.effectiveFamily, "Menlo")
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

    func testNativeRasterizationUsesUnsmoothedCoreGraphicsCoverage() {
        let scalar = UnicodeScalar("A").value
        guard let glyph = rasterizer.rasterize(codepoint: scalar) else {
            return XCTFail("expected a glyph for 'A'")
        }

        let actualCoverage = glyph.coverage.reduce(0) { $0 + Int($1) }
        let unsmoothedCoverage = referenceCoverageSum(codepoint: scalar, smoothFonts: false)

        XCTAssertEqual(actualCoverage, unsmoothedCoverage)
    }

    func test3270NerdFontCrispRasterizationUsesSyntheticThickeningOnly() throws {
        let resolved = TerminalFontResolver.resolve(fontFamily: "3270 Nerd Font", size: 16)
        try XCTSkipIf(resolved.effectiveFamily != "3270 Nerd Font", "3270 Nerd Font is not installed")
        let native = GlyphRasterizer(fontFamily: "3270 Nerd Font", size: 16, scale: 2)
        let crisp = GlyphRasterizer(fontFamily: "3270 Nerd Font", size: 16, scale: 2, fontThicken: true)
        let scalar = UnicodeScalar("W").value
        let nativeGlyph = try XCTUnwrap(native.rasterize(codepoint: scalar))
        let crispGlyph = try XCTUnwrap(crisp.rasterize(codepoint: scalar))

        let nativeCoverage = coverageSum(nativeGlyph)
        let crispCoverage = coverageSum(crispGlyph)
        let unsmoothedCoverage = referenceCoverageSum(
            codepoint: scalar,
            fontName: "3270 Nerd Font",
            size: 16,
            smoothFonts: false
        )
        let smoothedCoverage = referenceCoverageSum(
            codepoint: scalar,
            fontName: "3270 Nerd Font",
            size: 16,
            smoothFonts: true
        )

        XCTAssertEqual(nativeCoverage, unsmoothedCoverage)
        XCTAssertGreaterThan(crispCoverage, nativeCoverage)
        XCTAssertLessThan(crispCoverage, smoothedCoverage)
    }

    func test3270NerdFontThickeningStaysNoHeavierThanBold() throws {
        let resolved = TerminalFontResolver.resolve(fontFamily: "3270 Nerd Font", size: 13)
        try XCTSkipIf(resolved.effectiveFamily != "3270 Nerd Font", "3270 Nerd Font is not installed")
        let normal = GlyphRasterizer(fontFamily: "3270 Nerd Font", size: 13, scale: 2)
        let thickened = GlyphRasterizer(fontFamily: "3270 Nerd Font", size: 13, scale: 2, fontThicken: true, fontThickenStrength: 255)
        let scalar = UInt32(UnicodeScalar("W").value)

        let normalGlyph = try XCTUnwrap(normal.rasterize(codepoint: scalar))
        let thickenedGlyph = try XCTUnwrap(thickened.rasterize(codepoint: scalar))
        let normalCoverage = coverageSum(normalGlyph)
        let thickenedCoverage = coverageSum(thickenedGlyph)

        XCTAssertGreaterThan(thickenedCoverage, normalCoverage)
        XCTAssertLessThanOrEqual(thickenedCoverage, normalCoverage + normalCoverage / 10)
    }

    func testFontThickenIncreasesGlyphCoverageWithoutChangingMetricsOrBoxDrawing() throws {
        let normal = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let thickened = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2, fontThicken: true, fontThickenStrength: 255)
        let lightest = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2, fontThicken: true, fontThickenStrength: 0)

        XCTAssertEqual(thickened.metrics(), normal.metrics())
        XCTAssertNil(thickened.rasterize(codepoint: UInt32(UnicodeScalar(" ").value)))

        let scalar = UInt32(UnicodeScalar("W").value)
        let normalGlyph = try XCTUnwrap(normal.rasterize(codepoint: scalar))
        let thickenedGlyph = try XCTUnwrap(thickened.rasterize(codepoint: scalar))
        let lightestGlyph = try XCTUnwrap(lightest.rasterize(codepoint: scalar))
        let boldGlyph = try XCTUnwrap(normal.rasterize(codepoint: scalar, bold: true))
        let normalCoverage = coverageSum(normalGlyph)
        let lightestCoverage = coverageSum(lightestGlyph)
        let thickenedCoverage = coverageSum(thickenedGlyph)
        let boldCoverage = coverageSum(boldGlyph)
        XCTAssertEqual(thickenedGlyph.width, normalGlyph.width)
        XCTAssertEqual(thickenedGlyph.height, normalGlyph.height)
        XCTAssertGreaterThan(lightestCoverage, normalCoverage)
        XCTAssertGreaterThan(thickenedCoverage, lightestCoverage)
        XCTAssertLessThanOrEqual(thickenedCoverage, boldCoverage)

        let box = UInt32(UnicodeScalar("─").value)
        XCTAssertEqual(thickened.rasterize(codepoint: box), normal.rasterize(codepoint: box))
    }

    func testFontThickenAppliesToComposedClusters() throws {
        // Multi-scalar grapheme clusters (Thai base + vowel + tone) go through the CTLineDraw
        // composition path, not the single-glyph path — crisp-mode thickening must cover both or
        // composed text renders visibly thinner than its neighbors.
        let normal = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let thickened = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2, fontThicken: true, fontThickenStrength: 255)
        let cluster = "ที่"
        XCTAssertGreaterThan(cluster.unicodeScalars.count, 1, "must exercise the composed-cluster path")

        let normalGlyph = try XCTUnwrap(normal.rasterize(cluster: cluster))
        let thickenedGlyph = try XCTUnwrap(thickened.rasterize(cluster: cluster))

        XCTAssertEqual(thickenedGlyph.width, normalGlyph.width)
        XCTAssertEqual(thickenedGlyph.height, normalGlyph.height)
        XCTAssertGreaterThan(coverageSum(thickenedGlyph), coverageSum(normalGlyph))

        // Thicken OFF stays byte-identical through the cluster path.
        let off = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2, fontThicken: false)
        XCTAssertEqual(off.rasterize(cluster: cluster), normalGlyph)
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

    func testShapedRunCacheHitsOnRepeat() {
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)

        _ = rasterizer.shape("office => != ->", bold: false, italic: false)
        XCTAssertEqual(rasterizer.shapedRunStats.entries, 1)
        XCTAssertEqual(rasterizer.shapedRunStats.misses, 1)
        XCTAssertEqual(rasterizer.shapedRunStats.hits, 0)

        _ = rasterizer.shape("office => != ->", bold: false, italic: false)
        XCTAssertEqual(rasterizer.shapedRunStats.entries, 1)
        XCTAssertEqual(rasterizer.shapedRunStats.misses, 1)
        XCTAssertEqual(rasterizer.shapedRunStats.hits, 1)
    }

    func testShapedRunCacheKeysBoldAndItalicSeparately() {
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)

        _ = rasterizer.shape("status => ready", bold: false, italic: false)
        _ = rasterizer.shape("status => ready", bold: true, italic: false)
        _ = rasterizer.shape("status => ready", bold: false, italic: true)

        XCTAssertEqual(rasterizer.shapedRunStats.entries, 3)
        XCTAssertEqual(rasterizer.shapedRunStats.misses, 3)
        XCTAssertEqual(rasterizer.shapedRunStats.hits, 0)
    }

    func testShapedRunCacheIsScopedByFontSize() {
        let small = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let large = GlyphRasterizer(fontFamily: "Menlo", size: 18, scale: 2)

        let smallFirst = small.shape("abc =>", bold: false, italic: false)
        _ = small.shape("abc =>", bold: false, italic: false)
        let largeFirst = large.shape("abc =>", bold: false, italic: false)

        XCTAssertEqual(small.shapedRunStats.misses, 1)
        XCTAssertEqual(small.shapedRunStats.hits, 1)
        XCTAssertEqual(large.shapedRunStats.misses, 1)
        XCTAssertEqual(large.shapedRunStats.hits, 0)
        XCTAssertEqual(signature(smallFirst).map(\.utf16Index), signature(largeFirst).map(\.utf16Index))
        XCTAssertNotEqual(signature(smallFirst).map(\.fontSize), signature(largeFirst).map(\.fontSize))
    }

    func testCachedAndUncachedShapeResultsMatch() {
        let cached = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let uncached = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)

        let text = "office -> != <="
        let uncachedResult = uncached.shape(text, bold: false, italic: false)
        let first = cached.shape(text, bold: false, italic: false)
        let second = cached.shape(text, bold: false, italic: false)

        XCTAssertEqual(signature(first), signature(uncachedResult))
        XCTAssertEqual(signature(second), signature(uncachedResult))
        XCTAssertEqual(cached.shapedRunStats.misses, 1)
        XCTAssertEqual(cached.shapedRunStats.hits, 1)
    }

    func testShapedRunCacheDoesNotExceedCap() {
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2, shapedRunCacheLimit: 8)

        for i in 0 ..< 12 {
            _ = rasterizer.shape("run-\(i)", bold: false, italic: false)
        }

        XCTAssertEqual(rasterizer.shapedRunStats.entries, 8)
        XCTAssertEqual(rasterizer.shapedRunStats.misses, 12)
        XCTAssertEqual(rasterizer.shapedRunStats.evictions, 4)
    }

    private func signature(_ shaped: [GlyphRasterizer.ShapedGlyph]) -> [ShapedGlyphSignature] {
        shaped.map {
            ShapedGlyphSignature(
                glyph: $0.glyph,
                utf16Index: $0.utf16Index,
                fontName: CTFontCopyPostScriptName($0.font) as String,
                fontSize: CTFontGetSize($0.font)
            )
        }
    }

    private func typographicWidth(_ text: String, font: CTFont) -> CGFloat {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [fontKey: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func emitEvidence(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func coverageSum(_ glyph: RasterizedGlyph) -> Int {
        glyph.coverage.reduce(0) { $0 + Int($1) }
    }

    private func referenceCoverageSum(
        codepoint: UInt32,
        fontName: String = "Menlo",
        size: CGFloat = 14,
        smoothFonts: Bool
    ) -> Int {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        guard let scalar = Unicode.Scalar(codepoint) else { return 0 }
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count),
              let glyph = glyphs.first, glyph != 0
        else { return 0 }

        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bounds, 1)

        let scale: CGFloat = 2
        let pad = 1
        let leftPx = Int(floor(bounds.minX * scale))
        let rightPx = Int(ceil(bounds.maxX * scale))
        let topPx = Int(ceil(bounds.maxY * scale))
        let botPx = Int(floor(bounds.minY * scale))
        let width = (rightPx - leftPx) + 2 * pad
        let height = (topPx - botPx) + 2 * pad
        guard width > 0, height > 0 else { return 0 }

        var coverage = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &coverage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(smoothFonts)
        context.setFillColor(gray: 1, alpha: 1)
        context.scaleBy(x: scale, y: scale)

        var position = CGPoint(x: CGFloat(pad - leftPx) / scale, y: CGFloat(pad - botPx) / scale)
        CTFontDrawGlyphs(font, &g, &position, 1, context)
        return coverage.reduce(0) { $0 + Int($1) }
    }
}
