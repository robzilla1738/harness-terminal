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
    /// Left offset (pixels) from the cell pen origin to the glyph's left edge.
    public let bearingX: Int
    /// Offset (pixels) from the baseline up to the glyph's top edge.
    public let bearingY: Int
    public let coverage: [UInt8]
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
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init(fontFamily: String, size: CGFloat, scale: CGFloat = 2.0) {
        self.scale = scale
        self.pointSize = size
        // CTFontCreateWithName substitutes a system font if the name is unknown, so this
        // never fails — a deliberately forgiving path for user-supplied font names.
        let base = CTFontCreateWithName(fontFamily as CFString, size, nil)
        regular = base
        bold = Self.applyTraits(base, size: size, add: .traitBold)
        italic = Self.applyTraits(base, size: size, add: .traitItalic)
        boldItalic = Self.applyTraits(base, size: size, add: [.traitBold, .traitItalic])
    }

    private static func applyTraits(_ font: CTFont, size: CGFloat, add traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
    }

    private func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
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
        var chosenFont = font(bold: isBold, italic: isItalic)
        var glyph: CGGlyph
        if let g = glyphID(for: codepoint, in: chosenFont) {
            glyph = g
        } else {
            // Fall back to a font that has this scalar (CJK, emoji, symbols).
            let s = String(scalar)
            let fallback = CTFontCreateForString(chosenFont, s as CFString, CFRange(location: 0, length: s.utf16.count))
            guard let fg = glyphID(for: codepoint, in: fallback) else { return nil }
            chosenFont = fallback
            glyph = fg
        }

        // Glyph bounding box in points → pixels.
        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(chosenFont, .horizontal, &g, &bounds, 1)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let pxW = Int((bounds.width * scale).rounded(.up)) + 2  // +2px padding to avoid clipping AA edges
        let pxH = Int((bounds.height * scale).rounded(.up)) + 2
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
        ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(gray: 1, alpha: 1) // white ink on the zero-cleared (black) bitmap
        ctx.scaleBy(x: scale, y: scale)

        // Position so the glyph's bbox maps into the bitmap, with 1px (pre-scale) padding.
        let pad = 1.0 / scale
        var position = CGPoint(x: -bounds.minX + pad, y: -bounds.minY + pad)
        CTFontDrawGlyphs(chosenFont, &g, &position, 1, ctx)

        let coverage = readCoverage(ctx, width: pxW, height: pxH)
        return RasterizedGlyph(
            width: pxW,
            height: pxH,
            bearingX: Int((bounds.minX * scale).rounded()) - 1,
            bearingY: Int((bounds.maxY * scale).rounded()) + 1,
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
