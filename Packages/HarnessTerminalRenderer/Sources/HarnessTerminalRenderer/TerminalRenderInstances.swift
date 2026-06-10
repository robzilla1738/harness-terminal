import Foundation
import Metal
import simd

/// The renderer's CPU-side instance/cache value types, mechanically extracted from
/// `TerminalMetalRenderer.swift` (PR-30): the GPU instance layouts (which must stay
/// byte-compatible with the structs in `MetalShaders.source` — see each type's layout
/// note), the per-row encode caches, and the upload-cache keys. Same definitions,
/// `private` relaxed to internal for the file split, zero logic change.

/// GPU instance layouts — must match the structs in `MetalShaders.source`.
struct BgInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

struct PendingBgSpan {
    var row: Int
    var endColumn: Int
    var color: RenderColor
    var instance: BgInstance
}

struct EncodedRowInstances {
    var backgrounds: [BgInstance] = []
    var glyphs: [GlyphInstance] = []
    var decorations: [DecoInstance] = []
    var bgSpans = 0
    var bgCells = 0
    /// `TerminalMetalRenderer.rowContentKey` of the row content these instances were encoded
    /// from (0 = not salvageable: a glyph-inverting cursor row, whose instances bake the
    /// cursor-text color and so are not a pure function of the row content).
    /// Lets a geometry-compatible cache survive a column-count change: a row whose content key
    /// matches re-binds its cached instances instead of re-encoding (the instance X/Y bake
    /// per-cell `column`/`row` × cell pixels, NOT `frame.columns`, so a same-index row with
    /// identical significant content is byte-identical across widths).
    var contentKey: UInt64 = 0
    /// Whether any cell in this row carries SGR blink — a phase flip re-encodes exactly the
    /// rows with this set (everything else is untouched).
    var hasBlink = false
}

/// Per-frame metadata for one `buildFrameInstances` pass. The instance data itself lives in the
/// renderer's PERSISTENT flat arrays (`flatBg`/`flatGlyph`/`flatDeco` + `rowSeg`), mutated in
/// place per dirty row — a clean row's bytes are never touched or copied, so a steady-state
/// frame costs O(damage), not O(grid) (the Ghostty `Contents` model).
struct EncodedFrameInstances {
    var bgSpans = 0
    var bgCells = 0
    var encodedRows = 0
    var reusedRows = 0
    /// Whether the row-instance cache holds exactly this frame's rows on exit — false for the
    /// cache-bypassing builds (nil damage, shape guards) and the mid-encode atlas-reset
    /// fallback. Feeds `TerminalRenderStats.rowCacheCoherent`.
    var cachePopulated = false
    /// Ordered half-open instance-index spans that changed this frame in each stream, used to
    /// upload only the changed bytes to the GPU. `nil` means "the whole array changed"
    /// (cache-bypass, scroll — every kept row's baked Y rewrites, full rebuild) — the safe
    /// default that reproduces the whole-array upload. An empty list means nothing in that
    /// stream changed. A count-changing row's spans extend to the stream end (its tail bytes
    /// genuinely moved); count-preserving scattered damage stays as separate row-sized spans.
    var bgDirty: [Range<Int>]?
    var glyphDirty: [Range<Int>]?
    var decoDirty: [Range<Int>]?
}

/// One row's half-open ranges within the renderer's persistent flat instance arrays — the
/// single source of truth for both the in-place splice and the upload dirty spans. Invariant:
/// segments are contiguous, ascending, and exactly cover each flat array's grid region
/// (extras appended by `encode` live past the last segment).
struct RowSegment {
    var bg: Range<Int>
    var glyph: Range<Int>
    var deco: Range<Int>
}

struct CursorCacheKey: Equatable {
    var row: Int
    var column: Int
    var visible: Bool
    var style: CursorStyle
    var textColor: RenderColor
    var hollow: Bool

    /// A solid block inverts the glyph under it for legibility; a hollow (unfocused) block does
    /// not — the cell shows through the outline. So a focus change flips this, which dirties the
    /// cursor row below (via `previousCursor != cursorKey`) and re-renders the glyph correctly.
    var invertsGlyph: Bool { visible && style == .block && !hollow }
}

struct RowInstanceCache {
    var columns = 0
    var rows = 0
    var originX = 0
    var originY = 0
    var ligatures = false
    var atlasResets = 0
    /// Cell metrics the cached instances were baked with — the content-keyed salvage across a
    /// column change must never reuse instances positioned for a different font geometry (a
    /// font change normally rebuilds the renderer, but this gate makes salvage self-contained).
    var cellPixelWidth = 0
    var cellPixelHeight = 0
    var rowInstances: [EncodedRowInstances?] = []
    var previousCursor: CursorCacheKey?
    /// The SGR blink phase the cached rows were encoded under; a mismatch with the
    /// renderer's current phase dirties exactly the `hasBlink` rows.
    var textBlinkHidden = false
}

struct PromptGutterUploadKey: Equatable {
    var row: Int
    var color: RenderColor
}

struct InstanceUploadCacheKey: Equatable {
    var columns: Int
    var rows: Int
    var originX: Int
    var originY: Int
    var ligatures: Bool
    var cursor: CursorRender
    var promptGutter: [PromptGutterUploadKey]
}

struct UploadedInstanceBuffers {
    var key: InstanceUploadCacheKey
    var backgrounds: MTLBuffer?
    var backgroundCount: Int
    var glyphs: MTLBuffer?
    var glyphCount: Int
    var decorations: MTLBuffer?
    var decorationCount: Int
    var uploadBytes: Int
}

struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    /// Must mirror Metal `GlyphInstance.pageIndex` (uint@32, padding to color@48).
    var pageIndex: UInt32
    var color: SIMD4<Float>
}

/// Procedural line decoration (underline family / strikethrough / overline). Field order +
/// alignment must match `DecoInstance` in `MetalShaders.source` (color@0, params@16,
/// origin@32, size@40, kind@48).
struct DecoInstance {
    var color: SIMD4<Float>
    /// (centerY, thickness, amplitude, period) in px.
    var params: SIMD4<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var kind: UInt32
}

/// One inline-image quad (pixel origin + size); the texture is bound per draw.
struct ImageInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

/// Line-decoration styles; raw values match the `kind` switch in `deco_fragment`.
enum DecoKind: UInt32 {
    case solid = 0
    case double = 1
    case dotted = 2
    case dashed = 3
    case curly = 4
}
