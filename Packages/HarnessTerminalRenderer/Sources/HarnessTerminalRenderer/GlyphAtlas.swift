import CoreGraphics
import CoreText
import Metal
import simd

public struct GlyphAtlasStats: Equatable, Sendable {
    public var entries: Int
    public var shapedEntries: Int
    public var hits: Int
    public var misses: Int
    /// Atlas EPOCH counter: bumps whenever previously-issued UVs may no longer be valid — a
    /// full repack (cache-cap overflow) or a page eviction. The renderer keys its row-instance
    /// reuse on this, so any bump forces re-encoding from cells (which re-resolves entries
    /// against the current atlas). Page evictions also count separately below.
    public var resets: Int
    public var pages: Int
    public var shapedRunEntries: Int
    public var shapedRunCacheHits: Int
    public var shapedRunCacheMisses: Int
    public var shapedRunCacheEvictions: Int
    /// LRU page evictions at `maxPages` (each also bumps `resets`). A high rate relative to
    /// frames signals the working set exceeds the atlas budget (raise `atlasMaxPages`).
    public var pageEvictions: Int

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
        shapedRunCacheEvictions: Int = 0,
        pageEvictions: Int = 0
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
        self.pageEvictions = pageEvictions
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
    /// The high bit selects color storage, matching the GPU instance format.
    let encodedPageIndex: UInt32
    var pageIndex: Int { Int(encodedPageIndex & 0x7FFF_FFFF) }
    var isColor: Bool { encodedPageIndex & 0x8000_0000 != 0 }
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let pixelWidth: Int
    let pixelHeight: Int
    let bearingX: Int
    let bearingY: Int
}

/// R8 coverage pages plus lazily allocated RGBA color pages, each with bounded LRU storage.
/// Glyphs are rasterized and uploaded on demand and cached by `GlyphKey`. A cached `nil`
/// means the glyph has no ink (e.g. space) so the renderer skips it.
final class GlyphAtlas {
    /// Grows (by re-creating and copying) as pages fill: a pane that only ever shows ASCII
    /// holds one 1 MiB page, not all of them.
    var texture: MTLTexture { coveragePages.texture }
    var colorTexture: MTLTexture? { colorPages?.texture }
    private let coveragePages: GlyphAtlasPages
    private var colorPages: GlyphAtlasPages?
    private let device: MTLDevice
    let size: Int
    let maxPages: Int

    private let rasterizer: GlyphRasterizer
    private var cache: [GlyphKey: AtlasEntry?] = [:]
    private var shapedCache: [ShapedGlyphKey: AtlasEntry?] = [:]
    private var clusterCache: [ClusterGlyphKey: AtlasEntry?] = [:]
    /// Side index for U+0000...U+007F. Four planes (plain, bold, italic, bold+italic) of 128
    /// slots. `asciiOccupied` distinguishes "not cached" from a cached no-ink glyph. A full
    /// frame's encode is dominated by the dictionary probe; ASCII terminal text hits this table.
    private var asciiOccupied = [Bool](repeating: false, count: 512)
    private var asciiEntry = [AtlasEntry?](repeating: nil, count: 512)
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
    private var pageEvictions = 0
    var stats: GlyphAtlasStats {
        let shapedRunStats = rasterizer.shapedRunStats
        return GlyphAtlasStats(
            entries: cache.count,
            shapedEntries: shapedCache.count,
            hits: hits,
            misses: misses,
            resets: resets,
            pages: coveragePages.pagesUsed + (colorPages?.pagesUsed ?? 0),
            shapedRunEntries: shapedRunStats.entries,
            shapedRunCacheHits: shapedRunStats.hits,
            shapedRunCacheMisses: shapedRunStats.misses,
            shapedRunCacheEvictions: shapedRunStats.evictions,
            pageEvictions: pageEvictions
        )
    }

    // Startup contract: the atlas is created EMPTY and glyphs are rasterized purely on
    // demand (`entry(for:)` → `rasterizer.rasterize` → `place`), so launch never pays to
    // pre-rasterize a glyph set. Only one 1024×1024 page is allocated up front; the first
    // visible characters rasterize as they're drawn. Do not add a startup prewarm/preload
    // here — eager rasterization is exactly the work we keep off the first-paint path.
    init?(device: MTLDevice, rasterizer: GlyphRasterizer, size: Int = 1024, maxPages: Int = 4) {
        guard let pages = GlyphAtlasPages(device: device, size: size, maxPages: maxPages, isColor: false) else { return nil }
        self.coveragePages = pages
        self.device = device
        self.size = size
        self.maxPages = max(1, maxPages)
        self.rasterizer = rasterizer
    }

    /// Atlas entry for a glyph variant, rasterizing + packing on first use. Returns nil if
    /// the glyph has no ink or the atlas is full.
    func entry(for key: GlyphKey) -> AtlasEntry? {
        if let index = asciiIndex(key), asciiOccupied[index] {
            hits += 1
            let found = asciiEntry[index]
            touchPage(of: found)
            return found
        }
        if let cached = cache[key] {
            hits += 1
            touchPage(of: cached)
            return cached
        }
        misses += 1
        let entry = rasterizer.rasterize(codepoint: key.codepoint, bold: key.bold, italic: key.italic)
            .flatMap(place)
        cache[key] = entry
        if let index = asciiIndex(key) {
            asciiOccupied[index] = true
            asciiEntry[index] = entry
        }
        capCachesIfNeeded()
        return entry
    }

    /// Plane layout: plain=0, bold=1, italic=2, bold+italic=3, each 128 codepoints.
    private func asciiIndex(_ key: GlyphKey) -> Int? {
        guard key.codepoint < 128 else { return nil }
        let plane = (key.bold ? 1 : 0) | (key.italic ? 2 : 0)
        return plane * 128 + Int(key.codepoint)
    }

    private func clearASCIICache() {
        for index in asciiOccupied.indices {
            asciiOccupied[index] = false
            asciiEntry[index] = nil
        }
    }

    private func dropASCIIEntries(onPage victim: Int) {
        for index in asciiEntry.indices {
            guard asciiEntry[index]?.pageIndex == victim else { continue }
            asciiOccupied[index] = false
            asciiEntry[index] = nil
        }
    }

    /// Atlas entry for a grapheme cluster (base + combining marks), composed by CoreText into one
    /// bitmap so the marks are positioned contextually. Single-scalar clusters fall through to the
    /// per-glyph rasterizer, so ASCII/CJK behavior and cache cost are unchanged.
    func entry(forCluster cluster: String, bold: Bool, italic: Bool) -> AtlasEntry? {
        let key = ClusterGlyphKey(cluster: cluster, bold: bold, italic: italic)
        if let cached = clusterCache[key] {
            hits += 1
            touchPage(of: cached)
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
            touchPage(of: cached)
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

    /// Record a cache hit as a use of the entry's page for the LRU clock. Cached no-ink
    /// entries (nil) live on no page and never count as a use.
    @inline(__always)
    private func touchPage(of entry: AtlasEntry?) {
        guard let entry else { return }
        if entry.isColor { colorPages?.touch(entry.pageIndex) }
        else { coveragePages.touch(entry.pageIndex) }
    }

    /// Shape a run for ligatures (delegates to the rasterizer's CoreText shaper).
    func shape(_ text: String, bold: Bool, italic: Bool) -> [GlyphRasterizer.ShapedGlyph] {
        rasterizer.shape(text, bold: bold, italic: italic)
    }

    private func place(_ glyph: RasterizedGlyph) -> AtlasEntry? {
        let pages: GlyphAtlasPages
        if glyph.rgba != nil {
            if colorPages == nil {
                colorPages = GlyphAtlasPages(device: device, size: min(size, 512), maxPages: maxPages, isColor: true)
            }
            guard let colorPages else { return nil }
            pages = colorPages
        } else { pages = coveragePages }
        guard let packed = pages.pack(glyph) else { return nil }
        if let victim = packed.evicted {
            resets += 1
            pageEvictions += 1
            // The two atlases have separate page namespaces. Evicting emoji must not discard ASCII.
            func survives(_ entry: AtlasEntry?) -> Bool {
                entry?.isColor != pages.isColor || entry?.pageIndex != victim
            }
            cache = cache.filter { survives($0.value) }
            shapedCache = shapedCache.filter { survives($0.value) }
            clusterCache = clusterCache.filter { survives($0.value) }
            if !pages.isColor { dropASCIIEntries(onPage: victim) }
        }
        return packed.entry
    }

    private func resetPacker() {
        resets += 1
        coveragePages.reset()
        colorPages?.reset()
        cache.removeAll(keepingCapacity: true)
        shapedCache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
        clearASCIICache()
    }
}
