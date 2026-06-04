import CoreGraphics
import CoreText
import Metal
import simd

public struct GlyphAtlasStats: Equatable, Sendable {
    public var entries: Int
    public var shapedEntries: Int
    public var hits: Int
    public var misses: Int
    public var resets: Int
    public var pages: Int
    public var shapedRunEntries: Int
    public var shapedRunCacheHits: Int
    public var shapedRunCacheMisses: Int
    public var shapedRunCacheEvictions: Int

    public init(
        entries: Int = 0,
        shapedEntries: Int = 0,
        hits: Int = 0,
        misses: Int = 0,
        resets: Int = 0,
        pages: Int = 1,
        shapedRunEntries: Int = 0,
        shapedRunCacheHits: Int = 0,
        shapedRunCacheMisses: Int = 0,
        shapedRunCacheEvictions: Int = 0
    ) {
        self.entries = entries
        self.shapedEntries = shapedEntries
        self.hits = hits
        self.misses = misses
        self.resets = resets
        self.pages = pages
        self.shapedRunEntries = shapedRunEntries
        self.shapedRunCacheHits = shapedRunCacheHits
        self.shapedRunCacheMisses = shapedRunCacheMisses
        self.shapedRunCacheEvictions = shapedRunCacheEvictions
    }
}

/// Identifies a rasterized glyph variant in the atlas cache.
struct GlyphKey: Hashable {
    let codepoint: UInt32
    let bold: Bool
    let italic: Bool
}

/// Identifies a rasterized grapheme CLUSTER (base + combining marks) in the atlas cache. Used for
/// cells carrying combining marks (e.g. Thai base + vowel + tone), which are composed by CoreText
/// into a single bitmap so the marks are positioned contextually.
struct ClusterGlyphKey: Hashable {
    let cluster: String
    let bold: Bool
    let italic: Bool
}

/// Identifies a shaped glyph (ligature path): a glyph id within a specific font.
struct ShapedGlyphKey: Hashable {
    let glyph: UInt16
    let fontName: String
}

/// A packed glyph's location in the atlas (normalized UV) plus its pixel placement.
struct AtlasEntry {
    let pageIndex: Int
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let pixelWidth: Int
    let pixelHeight: Int
    let bearingX: Int
    let bearingY: Int
}

/// A texture-array glyph atlas (R8Unorm coverage) with a simple shelf packer per page.
/// Glyphs are rasterized and uploaded on demand and cached by `GlyphKey`. A cached `nil`
/// means the glyph has no ink (e.g. space) so the renderer skips it.
final class GlyphAtlas {
    let texture: MTLTexture
    let size: Int
    let maxPages: Int

    private let rasterizer: GlyphRasterizer
    private var cache: [GlyphKey: AtlasEntry?] = [:]
    private var shapedCache: [ShapedGlyphKey: AtlasEntry?] = [:]
    private var clusterCache: [ClusterGlyphKey: AtlasEntry?] = [:]
    /// Hard ceiling on cached glyph entries (rasterized + shaped). The texture itself bounds *inked*
    /// glyphs — a full atlas triggers `resetPacker` — but a `nil` (no-ink: space, zero-width
    /// combining mark) entry is cached WITHOUT consuming texture space, so a stream of many distinct
    /// blank codepoints could grow the dictionaries without ever filling the atlas. When the combined
    /// count crosses this, fall back to the same full repack the atlas-full path uses (keeps the
    /// caches and the texture in lockstep — the invariant `resetPacker` documents). Generous enough
    /// that no real terminal working set reaches it.
    private let maxCacheEntries = 16384
    private var hits = 0
    private var misses = 0
    private var resets = 0
    private var pagesUsed = 1

    var stats: GlyphAtlasStats {
        let shapedRunStats = rasterizer.shapedRunStats
        return GlyphAtlasStats(
            entries: cache.count,
            shapedEntries: shapedCache.count,
            hits: hits,
            misses: misses,
            resets: resets,
            pages: pagesUsed,
            shapedRunEntries: shapedRunStats.entries,
            shapedRunCacheHits: shapedRunStats.hits,
            shapedRunCacheMisses: shapedRunStats.misses,
            shapedRunCacheEvictions: shapedRunStats.evictions
        )
    }

    // Shelf packer cursor.
    private var pageIndex = 0
    private var penX = 0
    private var penY = 0
    private var shelfHeight = 0

    // Startup contract: the atlas is created EMPTY and glyphs are rasterized purely on
    // demand (`entry(for:)` → `rasterizer.rasterize` → `place`), so launch never pays to
    // pre-rasterize a glyph set. Only the 1024×1024 texture is allocated up front; the first
    // visible characters rasterize as they're drawn. Do not add a startup prewarm/preload
    // here — eager rasterization is exactly the work we keep off the first-paint path.
    init?(device: MTLDevice, rasterizer: GlyphRasterizer, size: Int = 1024, maxPages: Int = 4) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = max(1, maxPages)
        descriptor.usage = [.shaderRead]
        // Apple Silicon (unified memory) requires .shared for CPU-writable textures;
        // discrete GPUs use .managed. `replace(region:)` works for both.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.size = size
        self.maxPages = max(1, maxPages)
        self.rasterizer = rasterizer
    }

    /// Atlas entry for a glyph variant, rasterizing + packing on first use. Returns nil if
    /// the glyph has no ink or the atlas is full.
    func entry(for key: GlyphKey) -> AtlasEntry? {
        if let cached = cache[key] {
            hits += 1
            return cached
        }
        misses += 1
        let entry = rasterizer.rasterize(codepoint: key.codepoint, bold: key.bold, italic: key.italic)
            .flatMap(place)
        cache[key] = entry
        capCachesIfNeeded()
        return entry
    }

    /// Atlas entry for a grapheme cluster (base + combining marks), composed by CoreText into one
    /// bitmap so the marks are positioned contextually. Single-scalar clusters fall through to the
    /// per-glyph rasterizer, so ASCII/CJK behavior and cache cost are unchanged.
    func entry(forCluster cluster: String, bold: Bool, italic: Bool) -> AtlasEntry? {
        let key = ClusterGlyphKey(cluster: cluster, bold: bold, italic: italic)
        if let cached = clusterCache[key] {
            hits += 1
            return cached
        }
        misses += 1
        let entry = rasterizer.rasterize(cluster: cluster, bold: bold, italic: italic).flatMap(place)
        clusterCache[key] = entry
        capCachesIfNeeded()
        return entry
    }

    /// Atlas entry for a shaped glyph id (ligature path), keyed by glyph id + font.
    func entry(forShaped glyph: CGGlyph, font: CTFont) -> AtlasEntry? {
        let key = ShapedGlyphKey(glyph: glyph, fontName: CTFontCopyPostScriptName(font) as String)
        if let cached = shapedCache[key] {
            hits += 1
            return cached
        }
        misses += 1
        let entry = rasterizer.rasterize(glyph: glyph, font: font).flatMap(place)
        shapedCache[key] = entry
        capCachesIfNeeded()
        return entry
    }

    /// Bound the cache dictionaries: when the combined entry count crosses `maxCacheEntries`, repack
    /// from scratch (the atlas-full self-heal path). The just-returned entry may show stale UVs for
    /// at most one frame, then heals on re-rasterization — exactly the `resetPacker` contract.
    private func capCachesIfNeeded() {
        if cache.count + shapedCache.count + clusterCache.count > maxCacheEntries { resetPacker() }
    }

    /// Shape a run for ligatures (delegates to the rasterizer's CoreText shaper).
    func shape(_ text: String, bold: Bool, italic: Bool) -> [GlyphRasterizer.ShapedGlyph] {
        rasterizer.shape(text, bold: bold, italic: italic)
    }

    /// Pack a rasterized glyph into the shelf and upload it. Returns nil only when the glyph has
    /// no ink, or (pathologically) is larger than one atlas page. Normal growth advances to a
    /// fresh page instead of resetting. At `maxPages`, the atlas keeps the old self-healing full
    /// reset fallback; LRU per-page eviction is a later refinement.
    private func place(_ glyph: RasterizedGlyph) -> AtlasEntry? {
        guard glyph.width > 0, glyph.height > 0, glyph.width <= size, glyph.height <= size else {
            return nil
        }
        if let entry = pack(glyph) { return entry }
        resetPacker()
        return pack(glyph) // should succeed for any glyph that fits one empty page
    }

    /// Drop every cached entry and rewind the shelf packer so the texture can be repacked from
    /// scratch. Both caches index into `texture`, so they must be cleared together with the pen.
    /// Cached glyphs re-rasterize on next access; at worst one frame shows stale UVs, then heals.
    private func resetPacker() {
        resets += 1
        pageIndex = 0
        pagesUsed = 1
        penX = 0
        penY = 0
        shelfHeight = 0
        cache.removeAll(keepingCapacity: true)
        shapedCache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
    }

    /// Shelf-pack one inked glyph, uploading its coverage. Returns nil when the atlas is full.
    private func pack(_ glyph: RasterizedGlyph) -> AtlasEntry? {
        guard glyph.width <= size, glyph.height <= size else { return nil }
        // Advance to a new shelf if this glyph won't fit on the current row.
        if penX + glyph.width > size {
            penX = 0
            penY += shelfHeight + 1
            shelfHeight = 0
        }
        if penY + glyph.height > size {
            guard advancePage() else { return nil }
        }

        let originX = penX
        let originY = penY

        glyph.coverage.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(originX, originY, glyph.width, glyph.height),
                mipmapLevel: 0,
                slice: pageIndex,
                withBytes: raw.baseAddress!,
                bytesPerRow: glyph.width,
                bytesPerImage: glyph.width * glyph.height
            )
        }

        penX += glyph.width + 1
        shelfHeight = max(shelfHeight, glyph.height)

        let inv = Float(size)
        return AtlasEntry(
            pageIndex: pageIndex,
            uvOrigin: SIMD2(Float(originX) / inv, Float(originY) / inv),
            uvSize: SIMD2(Float(glyph.width) / inv, Float(glyph.height) / inv),
            pixelWidth: glyph.width,
            pixelHeight: glyph.height,
            bearingX: glyph.bearingX,
            bearingY: glyph.bearingY
        )
    }

    private func advancePage() -> Bool {
        guard pageIndex + 1 < maxPages else { return false }
        pageIndex += 1
        pagesUsed = max(pagesUsed, pageIndex + 1)
        penX = 0
        penY = 0
        shelfHeight = 0
        return true
    }
}
