import CoreGraphics
import CoreText
import Foundation

/// Monospace cell geometry in points (unscaled). The renderer multiplies by the display
/// scale for pixel sizes.
public struct CellMetrics: Equatable, Sendable {
    /// Advance width of a monospace cell.
    public let width: CGFloat
    /// Line height (ascent + descent + leading), rounded up.
    public let height: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(width: CGFloat, height: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        self.width = width
        self.height = height
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }
}

/// A rasterized glyph: an 8-bit alpha coverage bitmap plus placement metrics, ready to be
/// packed into the GPU glyph atlas. Coverage is row-major, `width * height` bytes, with
/// row 0 at the top of the image.
public struct RasterizedGlyph: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Left offset (pixels) from the cell pen origin to the bitmap's left edge.
    public let bearingX: Int
    /// Pixels from the baseline up to the bitmap's top edge; the renderer places the bitmap top
    /// at `baseline − bearingY`. The baseline is pixel-snapped at rasterization so every glyph
    /// shares the exact same baseline (no per-glyph rounding jitter).
    public let bearingY: Int
    public let coverage: [UInt8]
}

struct ShapedRunCacheStats: Equatable {
    var entries: Int
    var hits: Int
    var misses: Int
    var evictions: Int
}

/// Identifies a CoreText-shaped text run. The cache is intentionally scoped to one
/// `GlyphRasterizer`, which is owned by one surface renderer and used synchronously by encode.
struct ShapedRunKey: Hashable {
    var text: String
    var bold: Bool
    var italic: Bool
    var fontPSName: String
    var fontSize: Float
    var scale: Float
}

/// Rasterizes glyphs with CoreText/CoreGraphics into alpha-coverage bitmaps and reports
/// monospace cell metrics. CPU-only (no Metal), so it is unit-testable headlessly; the
/// Metal renderer uploads the coverage into a texture atlas.
///
/// Handles bold/italic via synthesized symbolic traits and missing glyphs via CoreText
/// font fallback (`CTFontCreateForString`), so CJK/emoji still render.
public final class GlyphRasterizer {
    /// Pixels-per-point (e.g. 2.0 on Retina). All returned glyph sizes are in pixels.
    public let scale: CGFloat
    private let pointSize: CGFloat
    private let regular: CTFont
    private let bold: CTFont
    private let italic: CTFont
    private let boldItalic: CTFont
    private let regularPSName: String
    private let boldPSName: String
    private let italicPSName: String
    private let boldItalicPSName: String
    /// Bundled "Symbols Nerd Font Mono" (PostScript name `SymbolsNFM`), auto-activated by the app
    /// via Info.plist `ATSApplicationFontsPath`. A guaranteed coverage font for Nerd Font /
    /// Powerline icon codepoints (PUA) the primary font lacks, so they never fall through to a
    /// CoreText LastResort "missing glyph" box (issue #37). `nil` for non-app consumers (the CLI
    /// compositor / headless tests) where the font isn't activated — they keep the existing
    /// `CTFontCreateForString` path unchanged.
    private let symbolFont: CTFont?
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private let shapedRunCacheLimit: Int
    // Stores non-Sendable CTFont-bearing shaped glyphs; this rasterizer is single-surface,
    // single-threaded renderer state, so the cache deliberately remains internal and unlocked.
    private var shapedRunCache: [ShapedRunKey: [ShapedGlyph]] = [:]
    private var shapedRunCacheOrder: [ShapedRunKey] = []
    private var shapedRunCacheOrderStart = 0
    private var shapedRunCacheHits = 0
    private var shapedRunCacheMisses = 0
    private var shapedRunCacheEvictions = 0

    var shapedRunStats: ShapedRunCacheStats {
        ShapedRunCacheStats(
            entries: shapedRunCache.count,
            hits: shapedRunCacheHits,
            misses: shapedRunCacheMisses,
            evictions: shapedRunCacheEvictions
        )
    }

    public init(fontFamily: String, size: CGFloat, scale: CGFloat = 2.0, shapedRunCacheLimit: Int = 3_000) {
        self.scale = scale
        self.pointSize = size
        self.shapedRunCacheLimit = max(1, shapedRunCacheLimit)
        // Init only creates the four CTFont objects (regular/bold/italic/bold-italic) — it
        // does NOT rasterize any glyphs. Rasterization is on demand per codepoint via
        // `rasterize(...)`, so startup never pays to pre-rasterize ASCII or any warm-up set.
        // Keep it that way: no eager glyph loop here.
        // Resolve the family to a real face, detecting `CTFontCreateWithName`'s silent
        // substitution (it would otherwise return a glyph-less system font for an unmatched
        // family — the root of the Nerd Font tofu bug, #37). Never fails — falls back to the
        // substitute, which the symbol font then covers for icons.
        let base = Self.resolvePrimaryFont(family: fontFamily, size: size)
        regular = base
        bold = Self.applyTraits(base, size: size, add: .traitBold)
        italic = Self.applyTraits(base, size: size, add: .traitItalic)
        boldItalic = Self.applyTraits(base, size: size, add: [.traitBold, .traitItalic])
        regularPSName = CTFontCopyPostScriptName(regular) as String
        boldPSName = CTFontCopyPostScriptName(bold) as String
        italicPSName = CTFontCopyPostScriptName(italic) as String
        boldItalicPSName = CTFontCopyPostScriptName(boldItalic) as String
        symbolFont = Self.resolveSymbolFallback(size: size)
    }

    private static func applyTraits(_ font: CTFont, size: CGFloat, add traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
    }

    /// Resolve the user's font family to a real `CTFont`, working around `CTFontCreateWithName`'s
    /// silent substitution. It resolves PostScript names first and only loosely matches family /
    /// display names; when it can't match, it returns a system font with no Nerd glyphs (the root
    /// of #37). If the resolved face's family/PostScript name doesn't match what was requested,
    /// retry via an explicit family-name descriptor before accepting the substitute (which the
    /// bundled symbol font then covers for icon codepoints).
    private static func resolvePrimaryFont(family: String, size: CGFloat) -> CTFont {
        let byName = CTFontCreateWithName(family as CFString, size, nil)
        if fontNameMatches(byName, requested: family) { return byName }
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute as String: family] as CFDictionary
        )
        let byFamily = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return fontNameMatches(byFamily, requested: family) ? byFamily : byName
    }

    /// Resolve the bundled "Symbols Nerd Font Mono" by name, verifying it actually activated
    /// (PostScript name `SymbolsNFM`) rather than silently substituting. `nil` when the font isn't
    /// available to this process (headless tests / the CLI compositor).
    private static func resolveSymbolFallback(size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName("Symbols Nerd Font Mono" as CFString, size, nil)
        return (CTFontCopyPostScriptName(font) as String) == "SymbolsNFM" ? font : nil
    }

    /// Whether a resolved font's family or PostScript name matches the requested family, ignoring
    /// case / spaces / hyphens / underscores. The common case (`CTFontCreateWithName` already
    /// resolved correctly) matches on the family name and returns immediately, so this never
    /// changes behavior for a correctly-resolved font.
    private static func fontNameMatches(_ font: CTFont, requested: String) -> Bool {
        let want = normalizedFontName(requested)
        guard !want.isEmpty else { return true }
        return normalizedFontName(CTFontCopyFamilyName(font) as String) == want
            || normalizedFontName(CTFontCopyPostScriptName(font) as String) == want
    }

    private static func normalizedFontName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private static func isLastResort(_ font: CTFont) -> Bool {
        (CTFontCopyPostScriptName(font) as String).contains("LastResort")
    }

    /// Nerd Font / Powerline icon ranges: the BMP Private Use Area (U+E000–U+F8FF — covers
    /// Powerline U+E0A0–E0D4, Devicons, Font Awesome, Seti, Octicons, Weather, …) and the
    /// supplementary PUA-A plane (U+F0000–U+FFFFD, used by newer Material Design icons). The
    /// renderer routes these to the bundled symbol fallback and never CoreText-shapes them
    /// (shaping is where the LastResort tofu originated), mirroring how box-drawing is handled.
    static func isNerdFontCodepoint(_ codepoint: UInt32) -> Bool {
        (0xE000 ... 0xF8FF).contains(codepoint) || (0xF0000 ... 0xFFFFD).contains(codepoint)
    }

    private func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }

    private func fontAndPostScriptName(bold isBold: Bool, italic isItalic: Bool) -> (CTFont, String) {
        switch (isBold, isItalic) {
        case (false, false): return (regular, regularPSName)
        case (true, false): return (bold, boldPSName)
        case (false, true): return (italic, italicPSName)
        case (true, true): return (boldItalic, boldItalicPSName)
        }
    }

    /// Monospace cell metrics (points). Width is the advance of a representative glyph
    /// ("M"); height is ascent + descent + leading.
    public func metrics() -> CellMetrics {
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        var glyph = glyphID(for: "M".unicodeScalars.first!.value, in: regular) ?? 0
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let width = advance.width > 0 ? advance.width : pointSize * 0.6
        return CellMetrics(
            width: width,
            height: (ascent + descent + leading).rounded(.up),
            ascent: ascent,
            descent: descent,
            leading: leading
        )
    }

    /// Rasterize a single scalar. Returns nil for empty/whitespace glyphs (no ink) — the
    /// caller draws only the background for those.
    public func rasterize(codepoint: UInt32, bold isBold: Bool = false, italic isItalic: Bool = false) -> RasterizedGlyph? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        // Box-drawing characters are rendered procedurally (cell-sized sprite) so they tile
        // seamlessly across cells regardless of the font.
        if BoxDrawing.supported(codepoint) { return rasterizeBox(codepoint) }
        var chosenFont = font(bold: isBold, italic: isItalic)
        let glyph: CGGlyph
        if let g = glyphID(for: codepoint, in: chosenFont) {
            glyph = g
        } else if Self.isNerdFontCodepoint(codepoint), let sym = symbolFont,
                  let g = glyphID(for: codepoint, in: sym) {
            // Nerd Font / Powerline icon the primary font lacks → draw it from the bundled symbol
            // font instead of letting CoreText hand back a LastResort "missing glyph" box (#37).
            chosenFont = sym
            glyph = g
        } else {
            // Fall back to a font that has this scalar (CJK, emoji, symbols).
            let s = String(scalar)
            let fallback = CTFontCreateForString(chosenFont, s as CFString, CFRange(location: 0, length: s.utf16.count))
            // For a Nerd icon with no real coverage anywhere, render nothing rather than the
            // LastResort tofu box; non-icon codepoints keep their existing fallback behavior.
            guard let fg = glyphID(for: codepoint, in: fallback),
                  !(Self.isNerdFontCodepoint(codepoint) && Self.isLastResort(fallback))
            else { return nil }
            chosenFont = fallback
            glyph = fg
        }
        return render(glyph: glyph, font: chosenFont)
    }

    /// Rasterize a specific glyph id in a specific font — used by the shaping (ligature)
    /// path, where CoreText already resolved glyph ids + fonts for a run.
    public func rasterize(glyph: CGGlyph, font: CTFont) -> RasterizedGlyph? {
        guard glyph != 0 else { return nil }
        return render(glyph: glyph, font: font)
    }

    /// One shaped glyph from `shape(_:)`: a glyph id in a resolved font, plus the UTF-16
    /// index of the source character (so the renderer can place it on the right cell).
    /// Not `Sendable` — `CTFont` isn't; shaped glyphs are consumed synchronously per frame.
    public struct ShapedGlyph {
        public let glyph: CGGlyph
        public let font: CTFont
        public let utf16Index: Int
    }

    /// Shape a string with CoreText so contextual ligatures (e.g. `=>`, `!=`, `->` in
    /// programming fonts) collapse into their ligature glyphs. Returns the run's glyphs in
    /// visual order with the source UTF-16 index of each, so a ligature spanning N cells is
    /// placed on its first cell and grid alignment is preserved.
    public func shape(_ text: String, bold isBold: Bool, italic isItalic: Bool) -> [ShapedGlyph] {
        guard !text.isEmpty else { return [] }
        let (base, fontPSName) = fontAndPostScriptName(bold: isBold, italic: isItalic)
        let key = ShapedRunKey(
            text: text,
            bold: isBold,
            italic: isItalic,
            fontPSName: fontPSName,
            fontSize: Float(pointSize),
            scale: Float(scale)
        )
        if let cached = shapedRunCache[key] {
            shapedRunCacheHits += 1
            return cached
        }

        shapedRunCacheMisses += 1
        let shaped = shapeUncached(text, font: base)
        insertShapedRun(shaped, for: key)
        return shaped
    }

    private func insertShapedRun(_ shaped: [ShapedGlyph], for key: ShapedRunKey) {
        if shapedRunCache.count >= shapedRunCacheLimit,
           shapedRunCacheOrderStart < shapedRunCacheOrder.count {
            let evicted = shapedRunCacheOrder[shapedRunCacheOrderStart]
            shapedRunCache.removeValue(forKey: evicted)
            shapedRunCacheOrderStart += 1
            shapedRunCacheEvictions += 1
            compactShapedRunCacheOrderIfNeeded()
        }
        shapedRunCache[key] = shaped
        shapedRunCacheOrder.append(key)
    }

    private func compactShapedRunCacheOrderIfNeeded() {
        guard shapedRunCacheOrderStart > 64,
              shapedRunCacheOrderStart * 2 >= shapedRunCacheOrder.count
        else { return }
        shapedRunCacheOrder.removeFirst(shapedRunCacheOrderStart)
        shapedRunCacheOrderStart = 0
    }

    private func shapeUncached(_ text: String, font base: CTFont) -> [ShapedGlyph] {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [fontKey: base])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        var out: [ShapedGlyph] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            // CoreText can hand back a run with no `CTFont` attribute (some emoji / ZWJ /
            // substituted runs). Skip such a run rather than force-casting — a force-cast here
            // crashes the GUI on attacker/content-controlled output. The cell glyph path covers
            // the codepoint as a fallback.
            guard let fontAttr = attrs[kCTFontAttributeName as String],
                  CFGetTypeID(fontAttr as CFTypeRef) == CTFontGetTypeID() else { continue }
            let runFont = fontAttr as! CTFont // safe: type-checked above
            for i in 0 ..< count {
                out.append(ShapedGlyph(glyph: glyphs[i], font: runFont, utf16Index: indices[i]))
            }
        }
        return out
    }

    /// Procedurally rasterize a box-drawing character to a cell-sized coverage bitmap so it
    /// tiles seamlessly across cells (font glyphs vary and can leave gaps). Returns nil if the
    /// codepoint isn't one we draw — the caller then falls back to the font glyph.
    private func rasterizeBox(_ codepoint: UInt32) -> RasterizedGlyph? {
        let m = metrics()
        let w = max(1, Int((m.width * scale).rounded()))
        let h = max(1, Int((m.height * scale).rounded()))
        let ascentPx = Int((m.ascent * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: grayColorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        // Flip to top-left origin / y-down so BoxDrawing's geometry matches the cell layout.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        guard BoxDrawing.draw(in: ctx, codepoint: codepoint, width: w, height: h) else { return nil }
        let coverage = readCoverage(ctx, width: w, height: h)
        // bearingX 0 + bearingY = ascent places the cell-sized sprite at the cell's top-left
        // (the renderer draws it at originY + ascentPixels − bearingY = originY).
        return RasterizedGlyph(width: w, height: h, bearingX: 0, bearingY: ascentPx, coverage: coverage)
    }

    /// Render a resolved glyph id in a font into an alpha-coverage bitmap. Returns nil when
    /// the glyph has no ink.
    private func render(glyph: CGGlyph, font: CTFont) -> RasterizedGlyph? {
        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bounds, 1)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Work in whole device pixels and snap the glyph's pen origin (baseline + left edge) to
        // the pixel grid, so the baseline lands on the SAME integer row for every glyph. Drawing
        // at a fractional position while rounding the bearing independently (the old path) left a
        // sub-pixel residual per glyph — a wavy / "squiggly" baseline across a line of text.
        let pad = 1
        let leftPx = Int(floor(bounds.minX * scale))   // pen → ink left  (may be negative)
        let rightPx = Int(ceil(bounds.maxX * scale))   // pen → ink right
        let topPx = Int(ceil(bounds.maxY * scale))     // baseline → ink top (rows above baseline)
        let botPx = Int(floor(bounds.minY * scale))    // baseline → ink bottom (≤ 0 with descenders)
        let pxW = (rightPx - leftPx) + 2 * pad
        let pxH = (topPx - botPx) + 2 * pad
        guard pxW > 0, pxH > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0, // let CoreGraphics choose alignment
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // Harness owns text weight through the explicit glyph gamma setting. CoreGraphics font
        // smoothing inflates grayscale coverage before Metal blends it, making regular text look
        // artificially bold even when the user selected native rendering.
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(gray: 1, alpha: 1) // white ink on the zero-cleared (black) bitmap
        ctx.scaleBy(x: scale, y: scale)

        // Pen origin at integer device pixels (CG is y-up from the bitmap bottom), so the baseline
        // is pixel-aligned. `position` is in points (pre-scale), hence the /scale.
        var position = CGPoint(x: CGFloat(pad - leftPx) / scale, y: CGFloat(pad - botPx) / scale)
        CTFontDrawGlyphs(font, &g, &position, 1, ctx)

        let coverage = readCoverage(ctx, width: pxW, height: pxH)
        // bearingX = bitmap-left relative to the pen; bearingY = rows from the bitmap top down to
        // the baseline. The renderer places the bitmap top at (baseline − bearingY), so with the
        // baseline at integer row `topPx + pad`, every glyph renders on the exact same baseline.
        return RasterizedGlyph(
            width: pxW,
            height: pxH,
            bearingX: leftPx - pad,
            bearingY: topPx + pad,
            coverage: coverage
        )
    }

    private func glyphID(for codepoint: UInt32, in font: CTFont) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        guard ok, let first = glyphs.first, first != 0 else { return nil }
        return first
    }

    /// Copy the grayscale context's pixels into a tightly-packed `width*height` buffer,
    /// honoring the context's (possibly padded) bytesPerRow.
    private func readCoverage(_ ctx: CGContext, width: Int, height: Int) -> [UInt8] {
        guard let base = ctx.data else { return [UInt8](repeating: 0, count: width * height) }
        let bytesPerRow = ctx.bytesPerRow
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            let rowStart = y * bytesPerRow
            for x in 0 ..< width {
                out[y * width + x] = src[rowStart + x]
            }
        }
        return out
    }
}
