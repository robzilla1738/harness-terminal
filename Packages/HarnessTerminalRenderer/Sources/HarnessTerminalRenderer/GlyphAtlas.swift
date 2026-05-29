import Metal
import simd

/// Identifies a rasterized glyph variant in the atlas cache.
struct GlyphKey: Hashable {
    let codepoint: UInt32
    let bold: Bool
    let italic: Bool
}

/// A packed glyph's location in the atlas (normalized UV) plus its pixel placement.
struct AtlasEntry {
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let pixelWidth: Int
    let pixelHeight: Int
    let bearingX: Int
    let bearingY: Int
}

/// A single-texture glyph atlas (R8Unorm coverage) with a simple shelf packer. Glyphs are
/// rasterized and uploaded on demand and cached by `GlyphKey`. A cached `nil` means the
/// glyph has no ink (e.g. space) so the renderer skips it.
final class GlyphAtlas {
    let texture: MTLTexture
    let size: Int

    private let rasterizer: GlyphRasterizer
    private var cache: [GlyphKey: AtlasEntry?] = [:]

    // Shelf packer cursor.
    private var penX = 0
    private var penY = 0
    private var shelfHeight = 0

    init?(device: MTLDevice, rasterizer: GlyphRasterizer, size: Int = 1024) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        // Apple Silicon (unified memory) requires .shared for CPU-writable textures;
        // discrete GPUs use .managed. `replace(region:)` works for both.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.size = size
        self.rasterizer = rasterizer
    }

    /// Atlas entry for a glyph variant, rasterizing + packing on first use. Returns nil if
    /// the glyph has no ink or the atlas is full.
    func entry(for key: GlyphKey) -> AtlasEntry? {
        if let cached = cache[key] { return cached }
        let entry = pack(key)
        cache[key] = entry
        return entry
    }

    private func pack(_ key: GlyphKey) -> AtlasEntry? {
        guard let glyph = rasterizer.rasterize(codepoint: key.codepoint, bold: key.bold, italic: key.italic),
              glyph.width > 0, glyph.height > 0
        else { return nil }

        // Advance to a new shelf if this glyph won't fit on the current row.
        if penX + glyph.width > size {
            penX = 0
            penY += shelfHeight + 1
            shelfHeight = 0
        }
        guard penY + glyph.height <= size else { return nil } // atlas exhausted

        let originX = penX
        let originY = penY

        glyph.coverage.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(originX, originY, glyph.width, glyph.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: glyph.width
            )
        }

        penX += glyph.width + 1
        shelfHeight = max(shelfHeight, glyph.height)

        let inv = Float(size)
        return AtlasEntry(
            uvOrigin: SIMD2(Float(originX) / inv, Float(originY) / inv),
            uvSize: SIMD2(Float(glyph.width) / inv, Float(glyph.height) / inv),
            pixelWidth: glyph.width,
            pixelHeight: glyph.height,
            bearingX: glyph.bearingX,
            bearingY: glyph.bearingY
        )
    }
}
