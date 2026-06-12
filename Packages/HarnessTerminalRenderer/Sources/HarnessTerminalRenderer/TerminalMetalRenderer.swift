import Foundation  // DispatchSemaphore
import HarnessTerminalEngine
import Metal
import QuartzCore
import simd

public struct TerminalRenderStats: Equatable, Sendable {
    public var cells: Int
    public var bgInstances: Int
    public var bgSpans: Int
    public var bgCells: Int
    public var glyphInstances: Int
    public var decoInstances: Int
    public var imageInstances: Int
    public var atlasPages: Int
    public var encodedRows: Int
    public var reusedRows: Int
    public var instanceUploadBytes: Int
    public var frameBuildNanos: UInt64
    public var encodeNanos: UInt64
    /// CPU instance build inside `encode` (`buildFrameInstances`): row encode + flatten. Included
    /// in `encodeNanos`; split out so a slow encode can be attributed to instance building vs the
    /// GPU upload vs the in-flight semaphore (the remaining `encodeNanos` residue is pass setup).
    public var buildInstancesNanos: UInt64
    /// GPU instance upload inside `encode` (`bindableInstanceBuffers`): the ring-slot memcpy or
    /// stable-cache bind. Included in `encodeNanos`; see `buildInstancesNanos`.
    public var uploadNanos: UInt64
    /// Time spent blocked on the in-flight semaphore inside `encode` — the GPU back-pressure
    /// (vsync) stall on the calling thread. Included in `encodeNanos`; split out so profiling can
    /// tell "GPU behind" from "encode is slow".
    public var semaphoreWaitNanos: UInt64
    /// Transaction-synchronized presents only: time from `commit()` to `waitUntilScheduled()`
    /// returning (the bounded main-thread wait of the glitchless-resize path). 0 for async presents.
    public var presentScheduleNanos: UInt64
    /// True iff this encode left the row-instance cache holding exactly the encoded frame's rows —
    /// the surface's repaint-coherence signal. False for the cache-bypassing paths (nil damage,
    /// shape guards) AND for a mid-encode atlas reset that wiped the cache after reuse: those
    /// present correct pixels but leave the cache empty, so an empty-damage repaint must not
    /// assume reuse. Only the renderer can tell these apart from a normal full encode.
    public var rowCacheCoherent: Bool

    public init(
        cells: Int = 0,
        bgInstances: Int = 0,
        bgSpans: Int = 0,
        bgCells: Int = 0,
        glyphInstances: Int = 0,
        decoInstances: Int = 0,
        imageInstances: Int = 0,
        atlasPages: Int = 1,
        encodedRows: Int = 0,
        reusedRows: Int = 0,
        instanceUploadBytes: Int = 0,
        frameBuildNanos: UInt64 = 0,
        encodeNanos: UInt64 = 0,
        buildInstancesNanos: UInt64 = 0,
        uploadNanos: UInt64 = 0,
        semaphoreWaitNanos: UInt64 = 0,
        presentScheduleNanos: UInt64 = 0,
        rowCacheCoherent: Bool = false
    ) {
        self.cells = cells
        self.bgInstances = bgInstances
        self.bgSpans = bgSpans
        self.bgCells = bgCells
        self.glyphInstances = glyphInstances
        self.decoInstances = decoInstances
        self.imageInstances = imageInstances
        self.atlasPages = atlasPages
        self.encodedRows = encodedRows
        self.reusedRows = reusedRows
        self.instanceUploadBytes = instanceUploadBytes
        self.frameBuildNanos = frameBuildNanos
        self.encodeNanos = encodeNanos
        self.buildInstancesNanos = buildInstancesNanos
        self.uploadNanos = uploadNanos
        self.semaphoreWaitNanos = semaphoreWaitNanos
        self.presentScheduleNanos = presentScheduleNanos
        self.rowCacheCoherent = rowCacheCoherent
    }
}

/// Renders a `TerminalFrame` with Metal: a background pass (the target is cleared to the canvas
/// color, then only cells that need a non-canvas fill emit a quad — see `RenderCell.drawBackground`),
/// then a texture-sampled glyph pass, then the cursor. Pixel sizes derive from the font's cell
/// metrics × display scale. Designed to draw into either an offscreen texture (tests) or a
/// `CAMetalLayer` drawable (the live view, added next).
public final class TerminalMetalRenderer {
    public let device: MTLDevice
    public let cellPixelWidth: Int
    public let cellPixelHeight: Int
    public private(set) var stats = TerminalRenderStats()
    public var glyphAtlasStats: GlyphAtlasStats { atlas.stats }
    /// SGR blink phase, driven by the host's blink timer: `true` hides blinking cells'
    /// glyphs + decorations (backgrounds stay). A flip re-encodes exactly the rows whose
    /// cached instances contain blink cells — see `buildFrameInstances`.
    public var textBlinkHidden = false

    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let decoPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let imageCache: ImageTextureCache
    private let ascentPixels: Int
    /// The render-target pixel format both pipelines are built for.
    public static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    /// CAMetalLayer compositing expects premultiplied color when alpha is below 1.
    /// Store translucent clears that way so the terminal canvas composites like the
    /// AppKit chrome tint beside it; opaque clears remain byte-for-byte identical.
    private static func premultipliedClearColor(_ color: RenderColor) -> MTLClearColor {
        let alpha = Double(color.alpha)
        return MTLClearColor(
            red: Double(color.red) * alpha,
            green: Double(color.green) * alpha,
            blue: Double(color.blue) * alpha,
            alpha: alpha
        )
    }

    /// Depth of the instance-buffer ring and the cap on frames the GPU may have in flight. Matched to
    /// the surface layer's `maximumDrawableCount` (2 — double-buffered for low keystroke-echo latency):
    /// with only 2 drawables the CPU can never get more than 2 frames ahead anyway, so a deeper ring
    /// just wastes a buffer and lets the semaphore advertise headroom that `nextDrawable()` won't grant.
    /// Keep these two in lockstep.
    private static let maxFramesInFlight = 2
    /// Reusable, growable instance buffers (one ring each) replacing per-frame `makeBuffer`.
    private let bgInstanceBuffer: DynamicInstanceBuffer
    private let glyphInstanceBuffer: DynamicInstanceBuffer
    private let decoInstanceBuffer: DynamicInstanceBuffer
    /// CPU-side row cache for encoded Metal instances. The drawable is still fully redrawn
    /// every frame; this cache only avoids regenerating clean rows from `RenderCell`s.
    private var rowInstanceCache = RowInstanceCache()
    /// Persistent flat instance storage — the upload source. The grid region [0, gridCount) is
    /// `concat(rowInstanceCache.rowInstances)` laid out per `rowSeg`; `encode` appends the
    /// per-frame cursor/gutter extras after it (truncated at the next build). On a steady-state
    /// frame only the dirty rows' segments are rewritten in place (equal-count) or spliced
    /// (count change shifts the tail once) — clean rows' bytes are never copied.
    private var flatBg: [BgInstance] = []
    private var flatGlyph: [GlyphInstance] = []
    private var flatDeco: [DecoInstance] = []
    private var rowSeg: [RowSegment] = []
    /// Count of extras `encode` appended to `flatBg` for the LAST frame (cursor + prompt
    /// gutter), removed before the next build mutates the grid region.
    private var flatBgExtras = 0
    /// True iff the flats' grid region is exactly `concat(rowInstanceCache.rowInstances)` per
    /// `rowSeg` — the precondition for the in-place splice path. False after any reset/bypass;
    /// re-established by a full rebuild over the cache.
    private var flatsCoherent = false
    /// Running per-frame stat totals for the flats' grid region (mirrors what summing every
    /// row's `bgSpans`/`bgCells` would yield), adjusted on splice instead of recomputed.
    private var flatBgSpans = 0
    private var flatBgCells = 0
    /// Immutable instance buffers for an unchanged frame. When damage is empty and the overlay
    /// key still matches, the renderer can bind these without another CPU memcpy.
    private var uploadedInstanceCache: UploadedInstanceBuffers?
    /// Caps in-flight frames at `maxFramesInFlight` so we never reuse a ring slot the GPU is
    /// still reading. Signaled from each command buffer's completion handler.
    private let inFlightSemaphore = DispatchSemaphore(value: TerminalMetalRenderer.maxFramesInFlight)
    /// Index of the ring slot the current frame writes into; advanced once per `encode`.
    private var frameSlot = 0

    public convenience init?(
        device: MTLDevice,
        fontFamily: String,
        fontSize: CGFloat,
        scale: CGFloat,
        atlasSize: Int = 1024,
        atlasMaxPages: Int = 4,
        fontThicken: Bool = false,
        fontThickenStrength: Int = 255
    ) {
        self.init(
            device: device,
            resolvedFont: TerminalFontResolver.resolve(fontFamily: fontFamily, size: fontSize),
            scale: scale,
            atlasSize: atlasSize,
            atlasMaxPages: atlasMaxPages,
            fontThicken: fontThicken,
            fontThickenStrength: fontThickenStrength
        )
    }

    public init?(
        device: MTLDevice,
        resolvedFont: ResolvedTerminalFont,
        scale: CGFloat,
        atlasSize: Int = 1024,
        atlasMaxPages: Int = 4,
        fontThicken: Bool = false,
        fontThickenStrength: Int = 255
    ) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let rasterizer = GlyphRasterizer(
            resolvedFont: resolvedFont,
            scale: scale,
            fontThicken: fontThicken,
            fontThickenStrength: fontThickenStrength
        )
        guard let atlas = GlyphAtlas(
            device: device,
            rasterizer: rasterizer,
            size: atlasSize,
            maxPages: atlasMaxPages
        ) else { return nil }

        let metrics = rasterizer.metrics()
        self.cellPixelWidth = max(1, Int((metrics.width * scale).rounded()))
        self.cellPixelHeight = max(1, Int((metrics.height * scale).rounded()))
        self.ascentPixels = Int((metrics.ascent * scale).rounded())

        do {
            let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
            bgPipeline = try Self.makePipeline(
                device: device, library: library,
                vertex: "bg_vertex", fragment: "bg_fragment", blending: false
            )
            glyphPipeline = try Self.makePipeline(
                device: device, library: library,
                vertex: "glyph_vertex", fragment: "glyph_fragment", blending: true
            )
            decoPipeline = try Self.makePipeline(
                device: device, library: library,
                vertex: "deco_vertex", fragment: "deco_fragment", blending: true
            )
            imagePipeline = try Self.makePipeline(
                device: device, library: library,
                vertex: "image_vertex", fragment: "image_fragment", blending: true
            )
        } catch {
            return nil
        }
        self.imageCache = ImageTextureCache(device: device)
        self.bgInstanceBuffer = DynamicInstanceBuffer(device: device, ringSize: Self.maxFramesInFlight, label: "bg-instances")
        self.glyphInstanceBuffer = DynamicInstanceBuffer(device: device, ringSize: Self.maxFramesInFlight, label: "glyph-instances")
        self.decoInstanceBuffer = DynamicInstanceBuffer(device: device, ringSize: Self.maxFramesInFlight, label: "deco-instances")

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }

        self.device = device
        self.commandQueue = queue
        self.atlas = atlas
        self.sampler = sampler
    }

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary,
        vertex: String, fragment: String, blending: Bool
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        // colorAttachments[0] is always present for a configured pipeline.
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        if blending {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Pixel dimensions of the surface needed to draw a frame of the given grid size.
    public func surfacePixelSize(columns: Int, rows: Int) -> (width: Int, height: Int) {
        (max(1, columns) * cellPixelWidth, max(1, rows) * cellPixelHeight)
    }

    /// Render `frame` into `target`, clearing to `clearColor` first. Synchronous: the
    /// command buffer is committed and waited on (suitable for offscreen capture).
    /// `origin` is the device-pixel offset of the grid's top-left (for window padding).
    ///
    /// Contract: `clearColor` must be the canvas/default background that the frame was built
    /// against (the color the `FrameBuilder`'s resolver uses for default-background cells, at
    /// the same alpha). The builder marks those cells `drawBackground == false` and the renderer
    /// skips their quads, so they show through to `clearColor`; a mismatch would mis-color every
    /// default cell. `HarnessTerminalSurfaceView` satisfies this by sourcing both from one value.
    @discardableResult
    public func render(
        _ frame: TerminalFrame,
        to target: MTLTexture,
        clearColor: RenderColor,
        origin: (x: Int, y: Int) = (0, 0),
        gamma: Float = 1,
        ligatures: Bool = false,
        damage: TerminalDamage? = nil,
        scrollShift: Int = 0,
        scrollFractionPx: Float = 0,
        smoothScrollClipRows: Int? = nil,
        frameBuildNanos: UInt64 = 0
    ) -> Bool {
        guard let commandBuffer = encode(
            frame, target: target, clearColor: clearColor, origin: origin,
            gamma: gamma, ligatures: ligatures, damage: damage, scrollShift: scrollShift,
            scrollFractionPx: scrollFractionPx, smoothScrollClipRows: smoothScrollClipRows,
            frameBuildNanos: frameBuildNanos
        ) else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    /// Render `frame` into a layer drawable and present it. Used by the live view.
    /// `origin` is the device-pixel offset of the grid's top-left (for window padding).
    /// `gamma` remaps glyph coverage only: 1 = native, < 1 = heavier/crisper, > 1 = softer.
    /// `ligatures` enables CoreText run shaping (programming-font ligatures).
    /// `clearColor` carries the same default-background contract as `render(_:to:clearColor:…)`.
    ///
    /// `synchronizedWithTransaction` must mirror the layer's `presentsWithTransaction` (the live
    /// view sets it during a live window resize): the drawable then has to join the *current*
    /// Core Animation transaction — the one carrying the window's new frame — so the present is
    /// commit → `waitUntilScheduled()` → `drawable.present()` instead of the async
    /// `commandBuffer.present(drawable)`. That latches the terminal content to the window edge
    /// with zero lag (Hume's glitchless-resize technique; Ghostty does the same). The wait is
    /// bounded by GPU *scheduling*, not completion — typically well under a millisecond — and is
    /// paid only while the layer is in transaction mode; the async path is byte-identical to
    /// before, preserving present-on-echo latency.
    /// `scrollFractionPx` / `smoothScrollClipRows`: pixel-smooth scrolling. The fraction is a
    /// whole-device-pixel upward translate applied as a vertex-stage uniform — instances (and the
    /// row-instance / uploaded-instance caches keyed on them) are untouched, so a pure-fraction
    /// scroll tick re-encodes nothing. `smoothScrollClipRows` scissors the draw to the first N
    /// rows' box so content slides out of a fixed window (and the frame's display-only peek row —
    /// built one row below the viewport to fill the translate's gap — stays hidden at fraction 0).
    @discardableResult
    public func present(
        _ frame: TerminalFrame,
        to drawable: CAMetalDrawable,
        clearColor: RenderColor,
        origin: (x: Int, y: Int) = (0, 0),
        gamma: Float = 1,
        ligatures: Bool = false,
        damage: TerminalDamage? = nil,
        scrollShift: Int = 0,
        scrollFractionPx: Float = 0,
        smoothScrollClipRows: Int? = nil,
        frameBuildNanos: UInt64 = 0,
        synchronizedWithTransaction: Bool = false
    ) -> Bool {
        guard let commandBuffer = encode(
            frame, target: drawable.texture, clearColor: clearColor, origin: origin,
            gamma: gamma, ligatures: ligatures, damage: damage, scrollShift: scrollShift,
            scrollFractionPx: scrollFractionPx, smoothScrollClipRows: smoothScrollClipRows,
            frameBuildNanos: frameBuildNanos
        ) else { return false }
        if synchronizedWithTransaction {
            let scheduleStart = DispatchTime.now().uptimeNanoseconds
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
            stats.presentScheduleNanos = DispatchTime.now().uptimeNanoseconds &- scheduleStart
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        return true
    }

    /// Build the instance buffers and encode the background, glyph, and decoration passes
    /// into a fresh command buffer. Caller decides whether to wait (offscreen) or present.
    /// `scrollShift` (viewport rows; see `buildFrameInstances`) rotates the row-instance cache
    /// for a pure scrollback scroll so kept rows skip re-encoding.
    func encode(
        _ frame: TerminalFrame,
        target: MTLTexture,
        clearColor: RenderColor,
        origin: (x: Int, y: Int),
        gamma: Float,
        ligatures: Bool,
        damage: TerminalDamage? = nil,
        scrollShift: Int = 0,
        scrollFractionPx: Float = 0,
        smoothScrollClipRows: Int? = nil,
        frameBuildNanos: UInt64 = 0
    ) -> MTLCommandBuffer? {
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        var frameStats = TerminalRenderStats(
            cells: frame.cells.count,
            atlasPages: atlas.stats.pages,
            frameBuildNanos: frameBuildNanos
        )
        let viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        let ox = Float(origin.x)
        let oy = Float(origin.y)
        let cellW = Float(cellPixelWidth)
        let cellH = Float(cellPixelHeight)
        // Decoration geometry (px): line thickness, underline baseline offset, etc. Snap to
        // whole device pixels so solid underline/strike/overline render as sharp 1–2px lines
        // instead of being AA-smeared across a half-pixel (the fuzzy-underline artifact).
        let thickness = max(1, (Float(cellPixelHeight) / 16).rounded())
        let underlineY = min(cellH - thickness, Float(ascentPixels) + max(1, cellH * 0.08)).rounded()
        let strikeY = (Float(ascentPixels) * 0.65).rounded()
        let overlineY = thickness

        let buildInstancesStart = DispatchTime.now().uptimeNanoseconds
        let encoded = buildFrameInstances(
            frame,
            origin: origin,
            cellSize: SIMD2(cellW, cellH),
            ligatures: ligatures,
            damage: damage,
            scrollShift: scrollShift,
            thickness: thickness,
            underlineY: underlineY,
            strikeY: strikeY,
            overlineY: overlineY
        )
        frameStats.buildInstancesNanos = DispatchTime.now().uptimeNanoseconds &- buildInstancesStart
        // The cursor + prompt-gutter quads are appended after the grid region of the persistent
        // flat bg array below (the build already truncated the previous frame's extras). They
        // change almost every frame (cursor blink/move), so the bg dirty spans must always cover
        // this trailing segment; `bgGridCount` marks where it starts. Gated on a valid frame
        // shape so an invalid (transient) frame truly draws nothing — the build just cleared the
        // flats, and a stray cursor quad over the cleared canvas would outlive the guard's intent.
        let frameShapeIsValid = frame.columns > 0 && frame.rows > 0
            && frame.cells.count == frame.columns * frame.rows
        let bgGridCount = flatBg.count

        // OSC 133 prompt gutter: a thin vertical stripe in the left margin marking shell-prompt
        // rows (green/red/neutral, resolved in the FrameBuilder). Appended after the cell
        // backgrounds so it paints over them; it sits in the window padding (flush to the grid's
        // left edge, falling back to column 0's bearing when there's no padding), where no glyph
        // draws — so it never collides with text. No-op without shell-integration marks.
        if frameShapeIsValid, !frame.promptGutter.isEmpty {
            let gutterW = max(2, (cellW * 0.14).rounded())
            let gx = max(0, ox - gutterW)
            for (row, color) in frame.promptGutter where row >= 0 && row < frame.rows {
                flatBg.append(BgInstance(
                    origin: SIMD2(gx, oy + Float(row) * cellH),
                    size: SIMD2(gutterW, cellH),
                    color: vector(color)
                ))
            }
        }

        // Cursor: block fills the cell (glyphs still draw on top); bar is a thin left edge;
        // underline is a thin bottom edge. When unfocused (`hollow`), the cursor becomes a 1px box
        // outline regardless of style — the standard macOS/Ghostty "inactive window" cursor — so
        // the glyph shows through. Full alpha (the bg pipeline doesn't blend). Respects the origin.
        if frameShapeIsValid, frame.cursor.visible {
            let cellX = ox + Float(frame.cursor.column * cellPixelWidth)
            let cellY = oy + Float(frame.cursor.row * cellPixelHeight)
            let cellW = Float(cellPixelWidth)
            let cellH = Float(cellPixelHeight)
            let color = vector(frame.cursor.color)
            if frame.cursor.hollow {
                let t = max(1, round(cellH / 16)) // stroke thickness (matches the underline idiom)
                // Four edge rects forming the outline (corners double-draw harmlessly).
                let edges: [(SIMD2<Float>, SIMD2<Float>)] = [
                    (SIMD2(cellX, cellY), SIMD2(cellW, t)),                 // top
                    (SIMD2(cellX, cellY + cellH - t), SIMD2(cellW, t)),     // bottom
                    (SIMD2(cellX, cellY), SIMD2(t, cellH)),                 // left
                    (SIMD2(cellX + cellW - t, cellY), SIMD2(t, cellH)),     // right
                ]
                for (cursorOrigin, cursorSize) in edges {
                    flatBg.append(BgInstance(origin: cursorOrigin, size: cursorSize, color: color))
                }
            } else {
                let cursorOrigin: SIMD2<Float>
                let cursorSize: SIMD2<Float>
                switch frame.cursor.style {
                case .block:
                    cursorOrigin = SIMD2(cellX, cellY)
                    cursorSize = SIMD2(cellW, cellH)
                case .bar:
                    let w = max(1, round(Float(cellPixelWidth) / 12))
                    cursorOrigin = SIMD2(cellX, cellY)
                    cursorSize = SIMD2(w, cellH)
                case .underline:
                    let h = max(1, round(Float(cellPixelHeight) / 16))
                    cursorOrigin = SIMD2(cellX, cellY + cellH - h)
                    cursorSize = SIMD2(cellW, h)
                }
                flatBg.append(BgInstance(origin: cursorOrigin, size: cursorSize, color: color))
            }
        }
        // Record the extras so the next build truncates them before touching the grid region,
        // and fold their span into the bg dirty list. When the grid list is nil (whole-array
        // upload) leave it nil; an empty grid list (no grid bg row changed — e.g. only the
        // cursor moved) becomes an extras-only upload, not the whole stream.
        flatBgExtras = flatBg.count - bgGridCount
        var bgDirty = encoded.bgDirty
        if flatBgExtras > 0, bgDirty != nil {
            bgDirty?.append(bgGridCount ..< flatBg.count)
        }

        frameStats.bgInstances = flatBg.count
        frameStats.bgSpans = encoded.bgSpans
        frameStats.bgCells = encoded.bgCells
        frameStats.glyphInstances = flatGlyph.count
        frameStats.decoInstances = flatDeco.count
        frameStats.encodedRows = encoded.encodedRows
        frameStats.reusedRows = encoded.reusedRows
        frameStats.rowCacheCoherent = encoded.cachePopulated

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.premultipliedClearColor(clearColor)

        // Reserve an in-flight slot before touching the instance-buffer ring, then advance to
        // the next slot so this frame writes a buffer no longer read by the GPU. The semaphore
        // blocks here if `maxFramesInFlight` frames are already queued — timed into the stats so
        // profiling can attribute a slow present to GPU back-pressure rather than encode cost.
        let semaphoreStart = DispatchTime.now().uptimeNanoseconds
        inFlightSemaphore.wait()
        frameStats.semaphoreWaitNanos = DispatchTime.now().uptimeNanoseconds &- semaphoreStart
        frameSlot = (frameSlot + 1) % Self.maxFramesInFlight

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlightSemaphore.signal()  // Nothing was committed; release the reserved slot.
            return nil
        }
        // Release the slot once the GPU finishes this frame. Capture the semaphore (not `self`)
        // so the retained handler can't form a reference cycle with the renderer.
        commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in inFlightSemaphore.signal() }

        // Smooth-scroll clip: rows slide out of the fixed grid box instead of bleeding into the
        // window padding, and the peek row (one row below the viewport) stays hidden until the
        // translate reveals it. Scissor only constrains draws — the clear above already painted
        // the padding — and is skipped entirely on the non-scrolling path (byte-identical).
        if let clipRows = smoothScrollClipRows, clipRows > 0 {
            let top = max(0, origin.y)
            let bottom = min(target.height, origin.y + clipRows * cellPixelHeight)
            if bottom > top {
                renderEncoder.setScissorRect(MTLScissorRect(
                    x: 0, y: top, width: target.width, height: bottom - top
                ))
            }
        }

        var vp = viewport
        var scrollPx = scrollFractionPx
        let uploadStart = DispatchTime.now().uptimeNanoseconds
        let instanceBuffers = bindableInstanceBuffers(
            backgrounds: flatBg,
            glyphs: flatGlyph,
            decorations: flatDeco,
            frame: frame,
            origin: origin,
            ligatures: ligatures,
            damage: damage,
            encoded: encoded,
            bgDirty: bgDirty,
            glyphDirty: encoded.glyphDirty,
            decoDirty: encoded.decoDirty,
            slot: frameSlot
        )
        frameStats.uploadNanos = DispatchTime.now().uptimeNanoseconds &- uploadStart
        frameStats.instanceUploadBytes = instanceBuffers.uploadBytes

        // Background pass. Empty instance arrays bind nothing, so a directly-constructed empty
        // frame never hits a zero-length buffer.
        if let buffer = instanceBuffers.backgrounds {
            renderEncoder.setRenderPipelineState(bgPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.setVertexBytes(&scrollPx, length: MemoryLayout<Float>.stride, index: 2)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceBuffers.backgroundCount)
        }

        // Images with z < 0 draw below text (Kitty negative z-index).
        frameStats.imageInstances += drawImages(
            frame.images, zBand: .belowText, encoder: renderEncoder,
            viewport: &vp, ox: ox, oy: oy
        )

        // Glyph pass (with the gamma-correct coverage uniform).
        if let buffer = instanceBuffers.glyphs {
            var glyphGamma = max(0.1, gamma)
            renderEncoder.setRenderPipelineState(glyphPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.setVertexBytes(&scrollPx, length: MemoryLayout<Float>.stride, index: 2)
            renderEncoder.setFragmentTexture(atlas.texture, index: 0)
            renderEncoder.setFragmentSamplerState(sampler, index: 0)
            renderEncoder.setFragmentBytes(&glyphGamma, length: MemoryLayout<Float>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceBuffers.glyphCount)
        }

        // Decoration pass (underline family / strikethrough / overline) — over the glyphs.
        if let buffer = instanceBuffers.decorations {
            renderEncoder.setRenderPipelineState(decoPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.setVertexBytes(&scrollPx, length: MemoryLayout<Float>.stride, index: 2)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceBuffers.decorationCount)
        }

        // Images with z >= 0 (the default) draw above text.
        frameStats.imageInstances += drawImages(
            frame.images, zBand: .aboveText, encoder: renderEncoder,
            viewport: &vp, ox: ox, oy: oy
        )

        renderEncoder.endEncoding()
        frameStats.atlasPages = atlas.stats.pages
        frameStats.encodeNanos = DispatchTime.now().uptimeNanoseconds &- encodeStart
        stats = frameStats
        return commandBuffer
    }

    private func bindableInstanceBuffers(
        backgrounds: [BgInstance],
        glyphs: [GlyphInstance],
        decorations: [DecoInstance],
        frame: TerminalFrame,
        origin: (x: Int, y: Int),
        ligatures: Bool,
        damage: TerminalDamage?,
        encoded: EncodedFrameInstances,
        bgDirty: [Range<Int>]?,
        glyphDirty: [Range<Int>]?,
        decoDirty: [Range<Int>]?,
        slot: Int
    ) -> UploadedInstanceBuffers {
        let key = instanceUploadCacheKey(frame: frame, origin: origin, ligatures: ligatures)
        let frameShapeIsValid = frame.columns > 0
            && frame.rows > 0
            && frame.cells.count == frame.columns * frame.rows
        // Images do NOT gate the stable cache: image quads draw per frame from `frame.images`
        // (textures keyed by their never-reused ids in ImageTextureCache), entirely outside the
        // cell instance buffers — a moved/changed image renders at its new placement while the
        // unchanged cell buffers re-bind zero-copy.
        let stableFrame = damage != nil
            && damage?.full == false
            && encoded.encodedRows == 0
            && encoded.reusedRows == frame.rows
            && frameShapeIsValid

        // INVARIANT (load-bearing for the ring): the immutable path below bypasses
        // `uploadIncremental`, so the ring slots' pending lists do NOT learn about this frame.
        // That is correct ONLY because a stable frame (encodedRows == 0) can mutate nothing but
        // flatBg's extras tail [bgGridCount, flatBg.count) — grid mutation requires
        // encodedRows > 0, which fails `stableFrame` — and every ring-upload frame
        // unconditionally re-covers the full current extras tail (the bgDirty append at the
        // cursor/gutter site). flatGlyph/flatDeco have no per-frame extras and are never
        // mutated on a stable frame. Any future path that mutates a flat array while
        // encodedRows == 0 OUTSIDE that always-re-covered tail must route through
        // `uploadIncremental` (or bump encodedRows) or it silently corrupts whichever ring
        // slot was skipped during the stable run.
        if stableFrame, let cached = uploadedInstanceCache, cached.key == key {
            return UploadedInstanceBuffers(
                key: key,
                backgrounds: cached.backgrounds,
                backgroundCount: cached.backgroundCount,
                glyphs: cached.glyphs,
                glyphCount: cached.glyphCount,
                decorations: cached.decorations,
                decorationCount: cached.decorationCount,
                uploadBytes: 0
            )
        }

        if stableFrame, let cached = makeUploadedInstanceCache(
            key: key, backgrounds: backgrounds, glyphs: glyphs, decorations: decorations
        ) {
            uploadedInstanceCache = cached
            return cached
        }

        // Incremental upload: copy only the spans that changed since this ring slot was last
        // written. nil means "whole array" (scroll, full damage, images, cache-bypass) and
        // reproduces the old whole-array upload exactly.
        uploadedInstanceCache = nil
        let bg = bgInstanceBuffer.uploadIncremental(backgrounds, dirty: bgDirty, slot: slot)
        let glyph = glyphInstanceBuffer.uploadIncremental(glyphs, dirty: glyphDirty, slot: slot)
        let deco = decoInstanceBuffer.uploadIncremental(decorations, dirty: decoDirty, slot: slot)
        return UploadedInstanceBuffers(
            key: key,
            backgrounds: bg?.buffer,
            backgroundCount: backgrounds.count,
            glyphs: glyph?.buffer,
            glyphCount: glyphs.count,
            decorations: deco?.buffer,
            decorationCount: decorations.count,
            uploadBytes: (bg?.bytesWritten ?? 0) + (glyph?.bytesWritten ?? 0) + (deco?.bytesWritten ?? 0)
        )
    }

    private func makeUploadedInstanceCache(
        key: InstanceUploadCacheKey,
        backgrounds: [BgInstance],
        glyphs: [GlyphInstance],
        decorations: [DecoInstance]
    ) -> UploadedInstanceBuffers? {
        let bg = makeImmutableInstanceBuffer(backgrounds, label: "bg-instances.stable")
        let glyph = makeImmutableInstanceBuffer(glyphs, label: "glyph-instances.stable")
        let deco = makeImmutableInstanceBuffer(decorations, label: "deco-instances.stable")
        if (!backgrounds.isEmpty && bg == nil)
            || (!glyphs.isEmpty && glyph == nil)
            || (!decorations.isEmpty && deco == nil) {
            return nil
        }

        return UploadedInstanceBuffers(
            key: key,
            backgrounds: bg,
            backgroundCount: backgrounds.count,
            glyphs: glyph,
            glyphCount: glyphs.count,
            decorations: deco,
            decorationCount: decorations.count,
            uploadBytes: backgrounds.count * MemoryLayout<BgInstance>.stride
                + glyphs.count * MemoryLayout<GlyphInstance>.stride
                + decorations.count * MemoryLayout<DecoInstance>.stride
        )
    }

    private func makeImmutableInstanceBuffer<T>(_ instances: [T], label: String) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        let bytes = instances.count * MemoryLayout<T>.stride
        return instances.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress,
                  let buffer = device.makeBuffer(bytes: baseAddress, length: bytes, options: .storageModeShared)
            else { return nil }
            buffer.label = label
            return buffer
        }
    }

    /// Memoized sorted form of the last-seen prompt gutter: the map + sort ran on EVERY encode
    /// (it feeds the upload cache key), but the gutter itself changes only when a prompt line
    /// appears/scrolls — so rebuild the sorted array only when the dictionary differs. The key
    /// stays value-identical to the unmemoized form (the stable-frame cache equality depends
    /// on it).
    private var promptGutterKeyCache: (gutter: [Int: RenderColor], keys: [PromptGutterUploadKey])?

    private func instanceUploadCacheKey(
        frame: TerminalFrame,
        origin: (x: Int, y: Int),
        ligatures: Bool
    ) -> InstanceUploadCacheKey {
        let gutter: [PromptGutterUploadKey]
        if frame.promptGutter.isEmpty {
            gutter = []
        } else if let cached = promptGutterKeyCache, cached.gutter == frame.promptGutter {
            gutter = cached.keys
        } else {
            gutter = frame.promptGutter
                .map { PromptGutterUploadKey(row: $0.key, color: $0.value) }
                .sorted { $0.row < $1.row }
            promptGutterKeyCache = (frame.promptGutter, gutter)
        }
        return InstanceUploadCacheKey(
            columns: frame.columns,
            rows: frame.rows,
            originX: origin.x,
            originY: origin.y,
            ligatures: ligatures,
            cursor: frame.cursor,
            promptGutter: gutter
        )
    }

    /// `scrollShift` (viewport rows, same convention as `FrameBuilder.buildShifted`): non-zero
    /// signals that this frame is the previous frame's content shifted by that many rows — a pure
    /// scrollback scroll. The cached row instances rotate to their new slots (rewriting the baked
    /// absolute Y) so kept rows skip re-encoding entirely (glyph shaping + atlas lookups); only
    /// the newly-exposed rows — which the caller puts in `damage.rows` — are encoded fresh.
    private func buildFrameInstances(
        _ frame: TerminalFrame,
        origin: (x: Int, y: Int),
        cellSize: SIMD2<Float>,
        ligatures: Bool,
        damage: TerminalDamage?,
        scrollShift: Int = 0,
        thickness: Float,
        underlineY: Float,
        strikeY: Float,
        overlineY: Float
    ) -> EncodedFrameInstances {
        // Drop the previous frame's cursor/gutter extras before touching the grid region —
        // every later mutation assumes the flats end at the last row segment.
        if flatBgExtras > 0 {
            flatBg.removeLast(flatBgExtras)
            flatBgExtras = 0
        }

        guard frame.columns > 0,
              frame.rows > 0,
              frame.cells.count == frame.columns * frame.rows
        else {
            resetRowInstanceCache()
            clearFlats() // an invalid frame draws nothing — stale flats must not upload
            return EncodedFrameInstances()
        }

        // Inline images do not bypass the row cache: they draw as separate textured quads AFTER
        // the cell passes (`drawImages`), so image presence is irrelevant to the cell encode —
        // an image-bearing pane keeps incremental row reuse while typing/resizing.
        guard let damage else {
            resetRowInstanceCache()
            return buildFrameInstancesWithoutCache(
                frame, origin: origin, cellSize: cellSize, ligatures: ligatures,
                thickness: thickness, underlineY: underlineY, strikeY: strikeY,
                overlineY: overlineY
            )
        }

        // Per-build memo: only a salvage pass in THIS build may populate it.
        salvageRowKeys = nil
        let cursorKey = CursorCacheKey(
            row: frame.cursor.row,
            column: frame.cursor.column,
            visible: frame.cursor.visible,
            style: frame.cursor.style,
            textColor: frame.cursor.textColor,
            hollow: frame.cursor.hollow
        )
        let cacheMatches = rowInstanceCache.columns == frame.columns
            && rowInstanceCache.rows == frame.rows
            && rowInstanceCache.originX == origin.x
            && rowInstanceCache.originY == origin.y
            && rowInstanceCache.ligatures == ligatures
            && rowInstanceCache.atlasResets == atlas.stats.resets
            && rowInstanceCache.rowInstances.count == frame.rows

        // Scroll-delta rotation: rotate kept rows to their new slots before the dirty-row pass so
        // they hit the reuse branch below. Exposed slots become nil (and arrive in damage.rows),
        // so they encode fresh either way. Gated on an otherwise-valid cache; a mismatch falls
        // through to the full reset exactly as a non-shifted frame would.
        if scrollShift != 0, cacheMatches, !damage.full {
            rotateRowInstanceCache(by: scrollShift, cellHeight: cellSize.y)
        }

        var dirtyRows = clampedRows(damage.rows, rowCount: frame.rows)
        if damage.full || !cacheMatches {
            // Content-keyed salvage: before discarding the cache, keep rows whose rendered
            // content provably didn't change (geometry-compatible cache + matching row content
            // key). The width-drag boundary tick is the payoff: a column-count change fails
            // `cacheMatches` and arrives as full damage, but a reflow typically rewraps only a
            // suffix — the unchanged top band re-binds instead of re-encoding. nil = not
            // compatible or under the hit-rate floor → the plain full reset, exactly as before.
            let salvaged = salvageRowInstances(
                frame, origin: origin, ligatures: ligatures, cursorKey: cursorKey
            )
            rowInstanceCache = RowInstanceCache(
                columns: frame.columns,
                rows: frame.rows,
                originX: origin.x,
                originY: origin.y,
                ligatures: ligatures,
                atlasResets: atlas.stats.resets,
                cellPixelWidth: cellPixelWidth,
                cellPixelHeight: cellPixelHeight,
                rowInstances: salvaged ?? Array(repeating: nil, count: frame.rows),
                previousCursor: nil,
                textBlinkHidden: textBlinkHidden
            )
            if let salvaged {
                dirtyRows = IndexSet()
                for row in 0 ..< frame.rows where salvaged[row] == nil {
                    dirtyRows.insert(row)
                }
            } else {
                dirtyRows = IndexSet(integersIn: 0 ..< frame.rows)
            }
        }

        if rowInstanceCache.previousCursor != cursorKey {
            if let previous = rowInstanceCache.previousCursor, previous.invertsGlyph {
                insert(row: previous.row, into: &dirtyRows, rowCount: frame.rows)
            }
            if cursorKey.invertsGlyph {
                insert(row: cursorKey.row, into: &dirtyRows, rowCount: frame.rows)
            }
        }

        // SGR blink phase flip: cached rows containing blink cells were encoded under the
        // other phase — re-encode exactly those rows. Everything else is untouched, so a
        // blink tick costs O(blink rows), the same shape as a cursor-row re-encode.
        if rowInstanceCache.textBlinkHidden != textBlinkHidden {
            for row in 0 ..< frame.rows where rowInstanceCache.rowInstances.indices.contains(row)
                && rowInstanceCache.rowInstances[row]?.hasBlink == true {
                insert(row: row, into: &dirtyRows, rowCount: frame.rows)
            }
            rowInstanceCache.textBlinkHidden = textBlinkHidden
        }

        let atlasResetsBefore = atlas.stats.resets
        var encoded = EncodedFrameInstances()

        // In-place splice (the steady-state path): the flats already hold every cached row at
        // `rowSeg` offsets, so only the dirty rows' segments are rewritten — clean rows' bytes
        // are never touched or copied. Requires a coherent layout (`flatsCoherent` — any reset,
        // bypass, or geometry change forces the full rebuild below, which re-establishes it),
        // an unchanged grid shape, and no scroll (a rotate rewrites every row's baked Y). Above
        // half the rows dirty, one linear rebuild is cheaper than per-row tail shifts.
        let spliceEligible = cacheMatches && !damage.full && scrollShift == 0 && flatsCoherent
            && rowSeg.count == frame.rows && dirtyRows.count * 2 <= frame.rows
        if spliceEligible {
            var bgSpansDirty: [Range<Int>] = []
            var glSpansDirty: [Range<Int>] = []
            var deSpansDirty: [Range<Int>] = []
            var bgShifted = Int.max, glShifted = Int.max, deShifted = Int.max
            for row in dirtyRows.sorted() {
                var fresh = encodeRowInstances(
                    row, frame: frame, origin: origin, cellSize: cellSize, ligatures: ligatures,
                    cursorKey: cursorKey, thickness: thickness, underlineY: underlineY,
                    strikeY: strikeY, overlineY: overlineY
                )
                fresh.contentKey = (cursorKey.invertsGlyph && cursorKey.row == row)
                    ? 0
                    : (salvageRowKeys?[row]
                        ?? Self.rowContentKey(frame, row: row, blinkHidden: textBlinkHidden))
                let old = rowSeg[row]
                let oldStats = rowInstanceCache.rowInstances[row]
                flatBgSpans += fresh.bgSpans - (oldStats?.bgSpans ?? 0)
                flatBgCells += fresh.bgCells - (oldStats?.bgCells ?? 0)
                // Splice each stream: equal counts overwrite in place (no tail shift); a count
                // change shifts the tail once and rebases every later segment by the delta.
                let bgDelta = fresh.backgrounds.count - old.bg.count
                let glDelta = fresh.glyphs.count - old.glyph.count
                let deDelta = fresh.decorations.count - old.deco.count
                flatBg.replaceSubrange(old.bg, with: fresh.backgrounds)
                flatGlyph.replaceSubrange(old.glyph, with: fresh.glyphs)
                flatDeco.replaceSubrange(old.deco, with: fresh.decorations)
                rowSeg[row] = RowSegment(
                    bg: old.bg.lowerBound ..< old.bg.lowerBound + fresh.backgrounds.count,
                    glyph: old.glyph.lowerBound ..< old.glyph.lowerBound + fresh.glyphs.count,
                    deco: old.deco.lowerBound ..< old.deco.lowerBound + fresh.decorations.count
                )
                if bgDelta != 0 || glDelta != 0 || deDelta != 0 {
                    for j in (row + 1) ..< frame.rows {
                        let s = rowSeg[j]
                        rowSeg[j] = RowSegment(
                            bg: (s.bg.lowerBound + bgDelta) ..< (s.bg.upperBound + bgDelta),
                            glyph: (s.glyph.lowerBound + glDelta) ..< (s.glyph.upperBound + glDelta),
                            deco: (s.deco.lowerBound + deDelta) ..< (s.deco.upperBound + deDelta)
                        )
                    }
                }
                if !rowSeg[row].bg.isEmpty { bgSpansDirty.append(rowSeg[row].bg) }
                if !rowSeg[row].glyph.isEmpty { glSpansDirty.append(rowSeg[row].glyph) }
                if !rowSeg[row].deco.isEmpty { deSpansDirty.append(rowSeg[row].deco) }
                if bgDelta != 0 { bgShifted = min(bgShifted, rowSeg[row].bg.lowerBound) }
                if glDelta != 0 { glShifted = min(glShifted, rowSeg[row].glyph.lowerBound) }
                if deDelta != 0 { deShifted = min(deShifted, rowSeg[row].deco.lowerBound) }
                rowInstanceCache.rowInstances[row] = fresh
                encoded.encodedRows += 1
            }
            encoded.reusedRows = frame.rows - encoded.encodedRows
            // A count change moved every later byte in that stream — those bytes must upload
            // too, so the moved suffix joins the dirty list (count-preserving scattered damage
            // keeps its separate row-sized spans; this is the win over the single-union range).
            // Spans are appended non-empty above, so no filter pass (and its intermediate
            // arrays) is needed before the merge.
            if bgShifted != Int.max, bgShifted < flatBg.count { bgSpansDirty.append(bgShifted ..< flatBg.count) }
            if glShifted != Int.max, glShifted < flatGlyph.count { glSpansDirty.append(glShifted ..< flatGlyph.count) }
            if deShifted != Int.max, deShifted < flatDeco.count { deSpansDirty.append(deShifted ..< flatDeco.count) }
            encoded.bgDirty = DynamicInstanceBuffer.merge([], adding: bgSpansDirty)
            encoded.glyphDirty = DynamicInstanceBuffer.merge([], adding: glSpansDirty)
            encoded.decoDirty = DynamicInstanceBuffer.merge([], adding: deSpansDirty)
        } else {
            // Full rebuild: clear the flats and lay every row back down (cached rows are still
            // REUSED — only their flat-array copy is redone, not their encode). This is the
            // boundary-crossing / scroll / post-reset shape; it re-establishes `flatsCoherent`.
            clearFlats()
            var bgLo = Int.max, bgHi = 0, bgShift = Int.max
            var glLo = Int.max, glHi = 0, glShift = Int.max
            var deLo = Int.max, deHi = 0, deShift = Int.max
            flatBg.reserveCapacity(frame.cells.count + 1)
            flatGlyph.reserveCapacity(frame.cells.count)
            flatDeco.reserveCapacity(frame.cells.count / 8)
            rowSeg.reserveCapacity(frame.rows)
            for row in 0 ..< frame.rows {
                let previous = rowInstanceCache.rowInstances[row]
                let rowInstances: EncodedRowInstances
                if dirtyRows.contains(row) || previous == nil {
                    var fresh = encodeRowInstances(
                        row, frame: frame, origin: origin, cellSize: cellSize, ligatures: ligatures,
                        cursorKey: cursorKey, thickness: thickness, underlineY: underlineY,
                        strikeY: strikeY, overlineY: overlineY
                    )
                    // Stamp the content key so a later column-count change can salvage this row.
                    // Skipped for a glyph-inverting cursor row: its instances bake the cursor-text
                    // color, so they are NOT a pure function of the row content alone. A salvage
                    // pass in this build already hashed the row — reuse its key instead of
                    // re-walking the columns.
                    fresh.contentKey = (cursorKey.invertsGlyph && cursorKey.row == row)
                        ? 0
                        : (salvageRowKeys?[row]
                            ?? Self.rowContentKey(frame, row: row, blinkHidden: textBlinkHidden))
                    rowInstances = fresh
                    rowInstanceCache.rowInstances[row] = rowInstances
                    encoded.encodedRows += 1
                    let bgN = rowInstances.backgrounds.count
                    let glN = rowInstances.glyphs.count
                    let deN = rowInstances.decorations.count
                    bgLo = min(bgLo, flatBg.count); bgHi = max(bgHi, flatBg.count + bgN)
                    glLo = min(glLo, flatGlyph.count); glHi = max(glHi, flatGlyph.count + glN)
                    deLo = min(deLo, flatDeco.count); deHi = max(deHi, flatDeco.count + deN)
                    if (previous?.backgrounds.count ?? -1) != bgN { bgShift = min(bgShift, flatBg.count) }
                    if (previous?.glyphs.count ?? -1) != glN { glShift = min(glShift, flatGlyph.count) }
                    if (previous?.decorations.count ?? -1) != deN { deShift = min(deShift, flatDeco.count) }
                } else {
                    rowInstances = previous!
                    encoded.reusedRows += 1
                }
                appendRowToFlats(rowInstances)
            }
            flatsCoherent = true
            // A row whose instance count changed shifts every later row's bytes, so extend that
            // stream's dirty span to the end. A pure scroll rotates every kept row's baked Y, so
            // its bytes all changed without being in `dirtyRows` — leave the spans nil (whole
            // upload; the rewritten Ys genuinely all moved).
            if scrollShift == 0 {
                if bgShift != Int.max { bgHi = flatBg.count }
                if glShift != Int.max { glHi = flatGlyph.count }
                if deShift != Int.max { deHi = flatDeco.count }
                encoded.bgDirty = bgHi > bgLo ? [bgLo ..< bgHi] : []
                encoded.glyphDirty = glHi > glLo ? [glLo ..< glHi] : []
                encoded.decoDirty = deHi > deLo ? [deLo ..< deHi] : []
            }
        }
        encoded.bgSpans = flatBgSpans
        encoded.bgCells = flatBgCells
        rowInstanceCache.previousCursor = cursorKey
        encoded.cachePopulated = true // every row now lives in the cache (encoded or reused)

        if atlas.stats.resets != atlasResetsBefore {
            let reusedRows = encoded.reusedRows
            resetRowInstanceCache()
            encoded.cachePopulated = false // the reset wiped it; a repaint must not assume reuse
            // If a reset happened after reusing rows, cached glyph UVs may reference the old
            // atlas contents. Redo this frame from cells so the already-present stale-frame
            // fallback never becomes a persistent cache bug.
            if reusedRows > 0 {
                return buildFrameInstancesWithoutCache(
                    frame, origin: origin, cellSize: cellSize, ligatures: ligatures,
                    thickness: thickness, underlineY: underlineY, strikeY: strikeY,
                    overlineY: overlineY
                )
            }
        }

        return encoded
    }

    private func buildFrameInstancesWithoutCache(
        _ frame: TerminalFrame,
        origin: (x: Int, y: Int),
        cellSize: SIMD2<Float>,
        ligatures: Bool,
        thickness: Float,
        underlineY: Float,
        strikeY: Float,
        overlineY: Float
    ) -> EncodedFrameInstances {
        var encoded = EncodedFrameInstances()
        clearFlats()
        flatBg.reserveCapacity(frame.cells.count + 1)
        flatGlyph.reserveCapacity(frame.cells.count)
        flatDeco.reserveCapacity(frame.cells.count / 8)
        for row in 0 ..< frame.rows {
            let rowInstances = encodeRowInstances(
                row,
                frame: frame,
                origin: origin,
                cellSize: cellSize,
                ligatures: ligatures,
                cursorKey: CursorCacheKey(
                    row: frame.cursor.row,
                    column: frame.cursor.column,
                    visible: frame.cursor.visible,
                    style: frame.cursor.style,
                    textColor: frame.cursor.textColor,
                    hollow: frame.cursor.hollow
                ),
                thickness: thickness,
                underlineY: underlineY,
                strikeY: strikeY,
                overlineY: overlineY
            )
            encoded.encodedRows += 1
            appendRowToFlats(rowInstances)
        }
        encoded.bgSpans = flatBgSpans
        encoded.bgCells = flatBgCells
        // The bypass leaves the row cache empty (`resetRowInstanceCache` ran before this), so
        // the flats hold THIS frame but cannot be spliced against next frame: stay incoherent.
        flatsCoherent = false
        return encoded
    }

    /// Append one row's instances to the persistent flats, recording its segment and stat
    /// contributions. The full-rebuild and bypass paths lay frames down exclusively through
    /// this, so `rowSeg` always exactly tiles the grid region.
    private func appendRowToFlats(_ row: EncodedRowInstances) {
        let seg = RowSegment(
            bg: flatBg.count ..< flatBg.count + row.backgrounds.count,
            glyph: flatGlyph.count ..< flatGlyph.count + row.glyphs.count,
            deco: flatDeco.count ..< flatDeco.count + row.decorations.count
        )
        flatBg.append(contentsOf: row.backgrounds)
        flatGlyph.append(contentsOf: row.glyphs)
        flatDeco.append(contentsOf: row.decorations)
        rowSeg.append(seg)
        flatBgSpans += row.bgSpans
        flatBgCells += row.bgCells
    }

    /// Empty the persistent flats (capacity kept — steady state never re-allocates) and reset
    /// the segment table and stat totals. Callers re-establish `flatsCoherent` themselves after
    /// laying a frame back down over the cache.
    private func clearFlats() {
        flatBg.removeAll(keepingCapacity: true)
        flatGlyph.removeAll(keepingCapacity: true)
        flatDeco.removeAll(keepingCapacity: true)
        rowSeg.removeAll(keepingCapacity: true)
        flatBgExtras = 0
        flatBgSpans = 0
        flatBgCells = 0
        flatsCoherent = false
    }

    @inline(__always)
    private static func mixContentKey(_ h: inout UInt64, _ v: UInt64) {
        h = (h ^ v) &* 0x0000_0100_0000_01B3 // FNV-64 prime, word-at-a-time mix
    }

    /// Content key for one viewport row: a 64-bit hash over EVERY `RenderCell` field that can
    /// affect the row's emitted instances. Two rows with equal keys (and equal geometry: origin,
    /// cell pixel metrics, ligatures, atlas epoch, row index) encode to byte-identical
    /// instances, so a cached row can be reused across a `frame.columns` change — instance X/Y
    /// bake per-cell `column`/`row` × cell pixels, never the total column count.
    ///
    /// Trailing cells that emit nothing (no glyph or combining mark, no background quad, no
    /// block element, no decoration) are excluded — the *significant prefix* — so a width change
    /// that only adds/removes trailing blank canvas hashes identically. Safe under ligatures
    /// too: `emitLigatedGlyphs`' run scan breaks on any non-glyph cell, so trailing
    /// insignificant cells can never start, extend, or restyle a run (and a `spacerTail` is
    /// transparent to runs — its wide BASE is the significant cell). A row that actually
    /// re-wraps gains/loses significant cells and hashes differently, as it must.
    ///
    /// MUST cover every field `encodeRowInstances`/`emit*Glyphs`/`appendDecorations` read from a
    /// cell — a missed field is a silent wrong-pixel cache. Pinned per-field by
    /// `MetalRendererTests.testContentKeyCoversEveryRenderedField`.
    static func rowContentKey(_ frame: TerminalFrame, row: Int, blinkHidden: Bool = false) -> UInt64 {
        let start = row * frame.columns
        var end = start + frame.columns
        while end > start {
            let c = frame.cells[end - 1]
            let significant = c.drawBackground || c.hasGlyph || c.combining0 != 0
                || c.underline != .none || c.strikethrough || c.overline
                || Self.isBlockElement(c.codepoint)
            if significant { break }
            end -= 1
        }
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-64 offset basis
        var rowHasBlink = false
        for i in start ..< end {
            let c = frame.cells[i]
            if c.blink { rowHasBlink = true }
            mixContentKey(&h, UInt64(c.codepoint) | (UInt64(c.combining0) << 32))
            mixContentKey(&h, UInt64(c.combining1))
            mixContentKey(&h, UInt64(c.foreground.red.bitPattern) | (UInt64(c.foreground.green.bitPattern) << 32))
            mixContentKey(&h, UInt64(c.foreground.blue.bitPattern) | (UInt64(c.foreground.alpha.bitPattern) << 32))
            mixContentKey(&h, UInt64(c.background.red.bitPattern) | (UInt64(c.background.green.bitPattern) << 32))
            mixContentKey(&h, UInt64(c.background.blue.bitPattern) | (UInt64(c.background.alpha.bitPattern) << 32))
            mixContentKey(&h, UInt64(c.underlineColor.red.bitPattern) | (UInt64(c.underlineColor.green.bitPattern) << 32))
            mixContentKey(&h, UInt64(c.underlineColor.blue.bitPattern) | (UInt64(c.underlineColor.alpha.bitPattern) << 32))
            let underlineBits: UInt64
            switch c.underline {
            case .none: underlineBits = 0
            case .single: underlineBits = 1
            case .double: underlineBits = 2
            case .curly: underlineBits = 3
            case .dotted: underlineBits = 4
            case .dashed: underlineBits = 5
            }
            let widthBits: UInt64
            switch c.width {
            case .normal: widthBits = 0
            case .wide: widthBits = 1
            case .spacerTail: widthBits = 2
            }
            mixContentKey(&h, underlineBits
                | (widthBits << 3)
                | (c.bold ? 1 << 6 : 0)
                | (c.italic ? 1 << 7 : 0)
                | (c.strikethrough ? 1 << 8 : 0)
                | (c.overline ? 1 << 9 : 0)
                | (c.drawBackground ? 1 << 10 : 0)
                | (c.blink ? 1 << 11 : 0))
        }
        mixContentKey(&h, UInt64(end - start)) // significant length, so prefixes can't alias
        // Fold the blink PHASE into rows that contain blink cells (and only those): the same
        // content encoded under the other phase produces different instances, so it must not
        // salvage/re-bind across a phase flip. Blink-free rows stay phase-independent.
        if rowHasBlink, blinkHidden { mixContentKey(&h, 0xB11_4B17) }
        return h
    }

    /// Content-keyed salvage across a geometry change the row cache would otherwise discard
    /// wholesale (a column-count change, or full damage with a compatible cache): keep cached
    /// rows whose content key matches the new frame's same-index row. Returns nil when the old
    /// cache isn't geometry-compatible (everything except `columns` must match — origin, rows,
    /// ligatures, atlas epoch, cell metrics) or when fewer than half the rows match (a near-total
    /// change isn't worth the bookkeeping — fall back to the plain full reset).
    /// Row content keys computed for the CURRENT frame by `salvageRowInstances`, so the encode
    /// pass that follows in the same build stamps salvage-missed rows without re-hashing them
    /// (the key is O(columns) per row). Reset at the top of every build; entries exist only for
    /// rows whose key salvage actually computed against this frame.
    private var salvageRowKeys: [UInt64?]?

    private func salvageRowInstances(
        _ frame: TerminalFrame, origin: (x: Int, y: Int), ligatures: Bool, cursorKey: CursorCacheKey
    ) -> [EncodedRowInstances?]? {
        let cache = rowInstanceCache
        guard cache.rows == frame.rows,
              cache.originX == origin.x, cache.originY == origin.y,
              cache.ligatures == ligatures,
              cache.atlasResets == atlas.stats.resets,
              cache.cellPixelWidth == cellPixelWidth,
              cache.cellPixelHeight == cellPixelHeight,
              cache.rowInstances.count == frame.rows
        else { return nil }
        var salvaged: [EncodedRowInstances?] = Array(repeating: nil, count: frame.rows)
        var frameKeys: [UInt64?] = Array(repeating: nil, count: frame.rows)
        var hits = 0
        for row in 0 ..< frame.rows {
            // Cursor-affected rows never salvage: cached instances baked the OLD cursor's glyph
            // inversion; the new cursor row must re-encode under the new key. (Mirrors the
            // cursor-row dirtying on the incremental path.)
            if let previous = cache.previousCursor, previous.invertsGlyph, previous.row == row { continue }
            if cursorKey.invertsGlyph, cursorKey.row == row { continue }
            guard let cached = cache.rowInstances[row], cached.contentKey != 0 else { continue }
            let frameKey = Self.rowContentKey(frame, row: row, blinkHidden: textBlinkHidden)
            frameKeys[row] = frameKey
            guard cached.contentKey == frameKey else { continue }
            salvaged[row] = cached
            hits += 1
        }
        // The keys were hashed against THIS frame, so the encode pass can reuse them whether or
        // not salvage clears the hit-rate floor (missed rows re-encode + stamp either way).
        salvageRowKeys = frameKeys
        guard hits * 2 >= frame.rows else { return nil }
        return salvaged
    }

    private func encodeRowInstances(
        _ row: Int,
        frame: TerminalFrame,
        origin: (x: Int, y: Int),
        cellSize: SIMD2<Float>,
        ligatures: Bool,
        cursorKey: CursorCacheKey,
        thickness: Float,
        underlineY: Float,
        strikeY: Float,
        overlineY: Float
    ) -> EncodedRowInstances {
        let ox = Float(origin.x)
        let oy = Float(origin.y)
        let cellW = cellSize.x
        let cellH = cellSize.y
        var encoded = EncodedRowInstances()
        encoded.backgrounds.reserveCapacity(frame.columns)
        encoded.glyphs.reserveCapacity(frame.columns)
        var pendingBgSpan: PendingBgSpan?

        func flushPendingBgSpan() {
            guard let span = pendingBgSpan else { return }
            encoded.backgrounds.append(span.instance)
            encoded.bgSpans += 1
            pendingBgSpan = nil
        }

        func appendCellBackground(_ cell: RenderCell, originX: Float, originY: Float) {
            encoded.bgCells += 1
            if var span = pendingBgSpan,
               span.row == cell.row,
               span.endColumn + 1 == cell.column,
               span.color == cell.background {
                span.endColumn = cell.column
                span.instance.size.x += cellW
                pendingBgSpan = span
                return
            }

            flushPendingBgSpan()
            pendingBgSpan = PendingBgSpan(
                row: cell.row,
                endColumn: cell.column,
                color: cell.background,
                instance: BgInstance(
                    origin: SIMD2(originX, originY),
                    size: SIMD2(cellW, cellH),
                    color: vector(cell.background)
                )
            )
        }

        let start = row * frame.columns
        let end = start + frame.columns
        for cell in frame.cells[start ..< end] {
            if cell.blink { encoded.hasBlink = true }
            let originX = ox + Float(cell.column * cellPixelWidth)
            let originY = oy + Float(cell.row * cellPixelHeight)
            let blockRects = Self.blockElementRects(cell.codepoint)
            // Block elements remain procedural and painter-ordered after the cell background.
            if let rects = blockRects {
                flushPendingBgSpan()
                if cell.drawBackground {
                    encoded.bgCells += 1
                    encoded.backgrounds.append(BgInstance(
                        origin: SIMD2(originX, originY),
                        size: SIMD2(cellW, cellH),
                        color: vector(cell.background)
                    ))
                    encoded.bgSpans += 1
                }

                let fill = vector(cell.foreground)
                for r in rects {
                    let x0 = originX + (r.0 * cellW).rounded()
                    let y0 = originY + (r.1 * cellH).rounded()
                    let x1 = originX + ((r.0 + r.2) * cellW).rounded()
                    let y1 = originY + ((r.1 + r.3) * cellH).rounded()
                    encoded.backgrounds.append(BgInstance(
                        origin: SIMD2(x0, y0), size: SIMD2(x1 - x0, y1 - y0), color: fill
                    ))
                }
            } else if cell.drawBackground {
                appendCellBackground(cell, originX: originX, originY: originY)
            }

            // A blinking cell's decorations follow its glyph through the phase (the
            // background quad above stays).
            if !(cell.blink && textBlinkHidden) {
                appendDecorations(cell, originX: originX, originY: originY,
                                  cellSize: cellSize,
                                  thickness: thickness, underlineY: underlineY,
                                  strikeY: strikeY, overlineY: overlineY,
                                  into: &encoded.decorations)
            }
        }
        flushPendingBgSpan()

        let cursorCell = cursorKey.invertsGlyph ? (row: cursorKey.row, column: cursorKey.column) : nil
        if ligatures {
            emitLigatedGlyphs(row: row, frame: frame, ox: ox, oy: oy, cursorCell: cursorCell,
                              cursorTextColor: cursorKey.textColor, into: &encoded.glyphs)
        } else {
            emitPerCellGlyphs(row: row, frame: frame, ox: ox, oy: oy, cursorCell: cursorCell,
                              cursorTextColor: cursorKey.textColor, into: &encoded.glyphs)
        }

        return encoded
    }

    private func resetRowInstanceCache() {
        rowInstanceCache = RowInstanceCache()
        uploadedInstanceCache = nil
        // Mark the flats stale relative to the (now empty) cache, but do NOT clear them: the
        // mid-encode atlas-reset branch resets the cache while the flats still hold the frame
        // `encode` is about to draw and upload. The next build's full-rebuild path clears them.
        flatsCoherent = false
    }

    /// Drop the row-reuse + stable-upload caches so the next frame re-encodes everything. The
    /// live view calls this when a present FAILS: the caller's frame bookkeeping has already
    /// advanced (its next build may report empty damage), but the cache either never saw the
    /// dropped frame's rows (nil drawable — the drop happens before `encode`) or holds rows the
    /// screen never showed (`encode` mutated it, then the command buffer failed). Both leave the
    /// cache disagreeing with the next frame's damage about what's on the glass; resetting makes
    /// the retry re-encode from the (always-correct) frame content.
    public func invalidateRowReuseCache() {
        resetRowInstanceCache()
    }

    /// Move every cached row's instances to their post-scroll slot and rewrite the baked absolute
    /// Y (instance origins are device-pixel positions frozen at encode time; decoration `params`
    /// stay cell-relative, so only `origin.y` moves). Rows shifted out of the viewport drop;
    /// exposed slots become nil so the caller encodes them fresh.
    /// The cached cursor key SHIFTS with the content — its row indexes the band it was encoded
    /// into, so after rotation the standard `previousCursor != cursorKey` pass still dirties the
    /// right slot (e.g. live→scrolled hides a block cursor: the old cursor row carries an
    /// inverted glyph and must re-encode at its shifted position, not its old index).
    /// The stable-upload cache holds pre-shift Y too; the exposed-row encodes force a real upload
    /// this frame (`encodedRows > 0` fails `stableFrame`), but it must also be dropped so a later
    /// stable frame can't revive the stale buffers through a still-matching key.
    private func rotateRowInstanceCache(by shift: Int, cellHeight: Float) {
        uploadedInstanceCache = nil
        let rows = rowInstanceCache.rowInstances.count
        guard abs(shift) < rows else {
            rowInstanceCache.rowInstances = Array(repeating: nil, count: rows)
            rowInstanceCache.previousCursor = nil
            return
        }
        var rotated: [EncodedRowInstances?] = Array(repeating: nil, count: rows)
        let dy = Float(shift) * cellHeight
        for sourceRow in 0 ..< rows {
            let destRow = sourceRow + shift
            guard destRow >= 0, destRow < rows,
                  var instances = rowInstanceCache.rowInstances[sourceRow] else { continue }
            for i in instances.backgrounds.indices { instances.backgrounds[i].origin.y += dy }
            for i in instances.glyphs.indices { instances.glyphs[i].origin.y += dy }
            for i in instances.decorations.indices { instances.decorations[i].origin.y += dy }
            rotated[destRow] = instances
        }
        rowInstanceCache.rowInstances = rotated
        if var previous = rowInstanceCache.previousCursor {
            previous.row += shift
            rowInstanceCache.previousCursor =
                (previous.row >= 0 && previous.row < rows) ? previous : nil
        }
    }

    private func clampedRows(_ rows: IndexSet, rowCount: Int) -> IndexSet {
        guard rowCount > 0 else { return [] }
        var clamped = IndexSet()
        for row in rows where row >= 0 && row < rowCount {
            clamped.insert(row)
        }
        return clamped
    }

    private func insert(row: Int, into rows: inout IndexSet, rowCount: Int) {
        guard row >= 0 && row < rowCount else { return }
        rows.insert(row)
    }

    /// Draw each inline image as a textured quad at its cell rect. One draw per image (each has
    /// its own texture); the GPU clips quads that extend past the viewport (images scrolling off).
    private enum ImageZBand {
        case belowText
        case aboveText

        func contains(_ image: FrameImage) -> Bool {
            switch self {
            case .belowText: return image.z < 0
            case .aboveText: return image.z >= 0
            }
        }
    }

    private func drawImages(
        _ images: [FrameImage],
        zBand: ImageZBand,
        encoder: MTLRenderCommandEncoder,
        viewport: inout SIMD2<Float>,
        ox: Float,
        oy: Float
    ) -> Int {
        guard !images.isEmpty else { return 0 }
        let cellW = Float(cellPixelWidth), cellH = Float(cellPixelHeight)
        var drawn = 0
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for img in images {
            guard zBand.contains(img) else { continue }
            guard let texture = imageCache.texture(
                id: img.id, rgba: img.image.rgba, width: img.image.pixelWidth, height: img.image.pixelHeight)
            else { continue }
            var inst = ImageInstance(
                origin: SIMD2(ox + Float(img.column) * cellW, oy + Float(img.row) * cellH),
                size: SIMD2(Float(img.columns) * cellW, Float(img.rows) * cellH))
            encoder.setVertexBytes(&inst, length: MemoryLayout<ImageInstance>.stride, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            drawn += 1
        }
        return drawn
    }

    /// Emit underline (any style) + strikethrough + overline decoration instances for a cell.
    private func appendDecorations(
        _ cell: RenderCell,
        originX: Float, originY: Float, cellSize: SIMD2<Float>,
        thickness: Float, underlineY: Float, strikeY: Float, overlineY: Float,
        into decorations: inout [DecoInstance]
    ) {
        let origin = SIMD2(originX, originY)
        if cell.underline != .none {
            let kind: DecoKind
            switch cell.underline {
            case .none: kind = .solid
            case .single: kind = .solid
            case .double: kind = .double
            case .curly: kind = .curly
            case .dotted: kind = .dotted
            case .dashed: kind = .dashed
            }
            decorations.append(DecoInstance(
                color: vector(cell.underlineColor),
                params: SIMD4(underlineY, thickness, max(1, thickness), max(2, cellSize.x * 0.5)),
                origin: origin, size: cellSize, kind: kind.rawValue
            ))
        }
        if cell.strikethrough {
            decorations.append(DecoInstance(
                color: vector(cell.foreground),
                params: SIMD4(strikeY, thickness, 0, 0),
                origin: origin, size: cellSize, kind: DecoKind.solid.rawValue
            ))
        }
        if cell.overline {
            decorations.append(DecoInstance(
                color: vector(cell.foreground),
                params: SIMD4(overlineY, thickness, 0, 0),
                origin: origin, size: cellSize, kind: DecoKind.solid.rawValue
            ))
        }
    }

    /// Test seam: emit a single row's glyphs (ligated path) for `frame` with the given inverting
    /// cursor cell and cursor text color, returning each instance's color. Lets a unit test assert
    /// per-glyph color (e.g. that a combining-mark cluster under the cursor gets the cursor color)
    /// without standing up a full render pass. Not part of the public API.
    func emittedGlyphColorsForTesting(
        row: Int, frame: TerminalFrame, cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor
    ) -> [SIMD4<Float>] {
        var glyphs: [GlyphInstance] = []
        emitLigatedGlyphs(row: row, frame: frame, ox: 0, oy: 0, cursorCell: cursorCell,
                          cursorTextColor: cursorTextColor, into: &glyphs)
        return glyphs.map { $0.color }
    }

    /// Fast path: one atlas glyph per cell (no shaping). Each glyph sits on its own cell;
    /// the cursor cell flips to the cursor-text color.
    private func emitPerCellGlyphs(
        row: Int, frame: TerminalFrame, ox: Float, oy: Float,
        cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor,
        into glyphs: inout [GlyphInstance]
    ) {
        let start = row * frame.columns
        let end = start + frame.columns
        for cell in frame.cells[start ..< end] {
            // Render when there's a base glyph OR a combining mark — a mark stacked on a space
            // (hasGlyph == false for 0x20) must still draw, matching what copy/search/capture see.
            guard cell.hasGlyph || cell.combining0 != 0, !Self.isBlockElement(cell.codepoint) else { continue }
            // SGR blink off-phase: the glyph disappears; the background quad stays.
            if cell.blink, textBlinkHidden { continue }
            // A cell carrying combining marks composes as one CoreText cluster bitmap; otherwise the
            // plain per-codepoint atlas entry (unchanged for ASCII/CJK).
            let entry = cell.combining0 != 0
                ? atlas.entry(forCluster: cell.cluster, bold: cell.bold, italic: cell.italic)
                : atlas.entry(for: GlyphKey(codepoint: cell.codepoint, bold: cell.bold, italic: cell.italic))
            guard let entry else { continue }
            let isCursor = cursorCell.map { $0.row == cell.row && $0.column == cell.column } ?? false
            let color = isCursor ? vector(cursorTextColor) : vector(cell.foreground)
            glyphs.append(glyphInstance(
                entry,
                originX: ox + Float(cell.column * cellPixelWidth),
                originY: oy + Float(cell.row * cellPixelHeight),
                color: color
            ))
        }
    }

    /// Ligature path: shape each maximal same-style/same-color run with CoreText, then place
    /// every shaped glyph on its *source* cell so the monospace grid stays aligned (a
    /// ligature spanning N cells lands on its first cell). The cursor cell is shaped alone.
    /// Scratch for `emitLigatedGlyphs`'s run accumulation, reused across runs/rows/frames
    /// (`removeAll(keepingCapacity:)` per run) — encoding is single-threaded per renderer, and
    /// a fresh String + Int array per run was a per-dirty-row-per-frame allocation pair.
    private var ligatureRunText = ""
    private var ligatureUTF16ToColumn: [Int] = []

    private func emitLigatedGlyphs(
        row: Int, frame: TerminalFrame, ox: Float, oy: Float,
        cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor,
        into glyphs: inout [GlyphInstance]
    ) {
        let cols = frame.columns
        var col = 0
        while col < cols {
            guard let cell = frame.cell(row: row, column: col), cell.hasGlyph || cell.combining0 != 0,
                  !Self.isBlockElement(cell.codepoint) else {
                col += 1
                continue
            }
            // SGR blink off-phase: the glyph disappears; the background quad stays.
            if cell.blink, textBlinkHidden {
                col += 1
                continue
            }
            if let cur = cursorCell, cur.row == row, cur.column == col {
                emitSingleGlyph(cell, row: row, col: col, ox: ox, oy: oy,
                                color: vector(cursorTextColor), into: &glyphs)
                col += 1
                continue
            }
            // Box-drawing chars use a procedural cell-sized sprite — never shape them into
            // a ligature run (that would render the font glyph and reintroduce seams).
            if BoxDrawing.supported(cell.codepoint) {
                emitSingleGlyph(cell, row: row, col: col, ox: ox, oy: oy,
                                color: vector(cell.foreground), into: &glyphs)
                col += 1
                continue
            }
            // Nerd Font / Powerline icons (PUA) must not be shaped: when the primary font lacks
            // them CoreText substitutes a LastResort "missing glyph" box (the tofu bug, #37).
            // Emit per-cell so they route through the rasterizer's bundled symbol-font fallback.
            if GlyphRasterizer.isNerdFontCodepoint(cell.codepoint) {
                emitSingleGlyph(cell, row: row, col: col, ox: ox, oy: oy,
                                color: vector(cell.foreground), into: &glyphs)
                col += 1
                continue
            }
            // A cell carrying combining marks (Thai vowel/tone, etc.) is composed by CoreText as a
            // single cluster bitmap with contextual mark positioning — never shaped into a ligature
            // run (the run path discards CoreText's per-glyph positions, which marks depend on).
            // Use the cursor text color when an inverting cursor sits on the cluster, for parity with
            // the single-glyph path (the leading cursor check above already covers the common case;
            // this keeps the branch self-consistent regardless of ordering). (#66 review nit)
            if cell.combining0 != 0 {
                let isCursor = cursorCell.map { $0.row == row && $0.column == col } ?? false
                let color = isCursor ? vector(cursorTextColor) : vector(cell.foreground)
                emitClusterGlyph(cell, row: row, col: col, ox: ox, oy: oy,
                                 color: color, into: &glyphs)
                col += 1
                continue
            }
            // Accumulate a run of contiguous, same-style, same-color glyph cells.
            ligatureRunText.removeAll(keepingCapacity: true)
            ligatureUTF16ToColumn.removeAll(keepingCapacity: true)
            let bold = cell.bold, italic = cell.italic, fg = cell.foreground
            var c = col
            while c < cols, let rc = frame.cell(row: row, column: c) {
                if rc.width == .spacerTail { c += 1; continue } // wide-char tail
                if !rc.hasGlyph { break }
                if Self.isBlockElement(rc.codepoint) { break } // drawn procedurally
                if BoxDrawing.supported(rc.codepoint) { break } // procedural box sprite
                if GlyphRasterizer.isNerdFontCodepoint(rc.codepoint) { break } // icon → per-cell symbol fallback
                if rc.combining0 != 0 { break } // composed separately as a CoreText cluster bitmap
                if let cur = cursorCell, cur.row == row, cur.column == c { break }
                if rc.bold != bold || rc.italic != italic || rc.foreground != fg { break }
                let scalar = Unicode.Scalar(rc.codepoint) ?? " "
                let before = ligatureRunText.utf16.count
                ligatureRunText.unicodeScalars.append(scalar)
                for _ in before ..< ligatureRunText.utf16.count { ligatureUTF16ToColumn.append(c) }
                c += 1
            }
            if ligatureUTF16ToColumn.isEmpty { col += 1; continue }
            let color = vector(fg)
            for shaped in atlas.shape(ligatureRunText, bold: bold, italic: italic) {
                guard let entry = atlas.entry(forShaped: shaped.glyph, font: shaped.font) else { continue }
                let idx = min(max(0, shaped.utf16Index), ligatureUTF16ToColumn.count - 1)
                let cellColumn = ligatureUTF16ToColumn[idx]
                glyphs.append(glyphInstance(
                    entry,
                    originX: ox + Float(cellColumn * cellPixelWidth),
                    originY: oy + Float(row * cellPixelHeight),
                    color: color
                ))
            }
            col = c
        }
    }

    private func emitSingleGlyph(
        _ cell: RenderCell, row: Int, col: Int, ox: Float, oy: Float,
        color: SIMD4<Float>, into glyphs: inout [GlyphInstance]
    ) {
        guard cell.hasGlyph || cell.combining0 != 0, !Self.isBlockElement(cell.codepoint) else { return }
        if cell.combining0 != 0 {
            emitClusterGlyph(cell, row: row, col: col, ox: ox, oy: oy, color: color, into: &glyphs)
            return
        }
        guard let entry = atlas.entry(for: GlyphKey(codepoint: cell.codepoint, bold: cell.bold, italic: cell.italic))
        else { return }
        glyphs.append(glyphInstance(
            entry,
            originX: ox + Float(col * cellPixelWidth),
            originY: oy + Float(row * cellPixelHeight),
            color: color
        ))
    }

    /// Place a base+combining cell as a single CoreText-composed cluster bitmap at the cell origin.
    /// The mark overhang (above the cap, slightly left) is carried by the entry's bearings and is
    /// drawn outside the cell box without clipping — the same as a tall single glyph.
    private func emitClusterGlyph(
        _ cell: RenderCell, row: Int, col: Int, ox: Float, oy: Float,
        color: SIMD4<Float>, into glyphs: inout [GlyphInstance]
    ) {
        guard let entry = atlas.entry(forCluster: cell.cluster, bold: cell.bold, italic: cell.italic)
        else { return }
        glyphs.append(glyphInstance(
            entry,
            originX: ox + Float(col * cellPixelWidth),
            originY: oy + Float(row * cellPixelHeight),
            color: color
        ))
    }

    private func glyphInstance(_ entry: AtlasEntry, originX: Float, originY: Float, color: SIMD4<Float>) -> GlyphInstance {
        let gx = originX + Float(entry.bearingX)
        let gy = originY + Float(ascentPixels - entry.bearingY)
        return GlyphInstance(
            origin: SIMD2(gx, gy),
            size: SIMD2(Float(entry.pixelWidth), Float(entry.pixelHeight)),
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            pageIndex: UInt32(entry.pageIndex),
            color: color
        )
    }

    private func vector(_ c: RenderColor) -> SIMD4<Float> {
        SIMD4(c.red, c.green, c.blue, c.alpha)
    }

    /// True for the block-element codepoints we render procedurally (U+2580–U+259F, excluding
    /// the shade blocks U+2591–2593, which keep their dithered font glyph). Used by the glyph
    /// emitters to skip these cells — they're filled in the background pass instead.
    static func isBlockElement(_ cp: UInt32) -> Bool {
        (0x2580 ... 0x259F).contains(cp) && !(0x2591 ... 0x2593).contains(cp)
    }

    /// Sub-cell rectangles (x, y, w, h as 0…1 fractions, y from the top) that fill a block
    /// element exactly, or nil for non-block codepoints. Drawing these as solid rects (instead
    /// of font glyphs) tiles seamlessly for block-art output.
    static func blockElementRects(_ cp: UInt32) -> [(Float, Float, Float, Float)]? {
        let e = Float(1) / 8
        switch cp {
        case 0x2588: return [(0, 0, 1, 1)]                                   // █ full
        case 0x2580: return [(0, 0, 1, 0.5)]                                 // ▀ upper half
        case 0x2584: return [(0, 0.5, 1, 0.5)]                               // ▄ lower half
        case 0x258C: return [(0, 0, 0.5, 1)]                                 // ▌ left half
        case 0x2590: return [(0.5, 0, 0.5, 1)]                               // ▐ right half
        case 0x2581: return [(0, 7 * e, 1, e)]                               // ▁ lower 1/8
        case 0x2582: return [(0, 6 * e, 1, 2 * e)]                           // ▂
        case 0x2583: return [(0, 5 * e, 1, 3 * e)]                           // ▃
        case 0x2585: return [(0, 3 * e, 1, 5 * e)]                           // ▅
        case 0x2586: return [(0, 2 * e, 1, 6 * e)]                           // ▆
        case 0x2587: return [(0, e, 1, 7 * e)]                               // ▇
        case 0x2589: return [(0, 0, 7 * e, 1)]                               // ▉ left 7/8
        case 0x258A: return [(0, 0, 6 * e, 1)]                               // ▊
        case 0x258B: return [(0, 0, 5 * e, 1)]                               // ▋
        case 0x258D: return [(0, 0, 3 * e, 1)]                               // ▍
        case 0x258E: return [(0, 0, 2 * e, 1)]                               // ▎
        case 0x258F: return [(0, 0, e, 1)]                                   // ▏ left 1/8
        case 0x2594: return [(0, 0, 1, e)]                                   // ▔ upper 1/8
        case 0x2595: return [(7 * e, 0, e, 1)]                               // ▕ right 1/8
        case 0x2596: return [(0, 0.5, 0.5, 0.5)]                             // ▖ LL
        case 0x2597: return [(0.5, 0.5, 0.5, 0.5)]                           // ▗ LR
        case 0x2598: return [(0, 0, 0.5, 0.5)]                               // ▘ UL
        case 0x2599: return [(0, 0, 0.5, 1), (0.5, 0.5, 0.5, 0.5)]           // ▙ UL+LL+LR
        case 0x259A: return [(0, 0, 0.5, 0.5), (0.5, 0.5, 0.5, 0.5)]         // ▚ UL+LR
        case 0x259B: return [(0, 0, 1, 0.5), (0, 0.5, 0.5, 0.5)]             // ▛ UL+UR+LL
        case 0x259C: return [(0, 0, 1, 0.5), (0.5, 0.5, 0.5, 0.5)]           // ▜ UL+UR+LR
        case 0x259D: return [(0.5, 0, 0.5, 0.5)]                             // ▝ UR
        case 0x259E: return [(0.5, 0, 0.5, 0.5), (0, 0.5, 0.5, 0.5)]         // ▞ UR+LL
        case 0x259F: return [(0.5, 0, 0.5, 0.5), (0, 0.5, 1, 0.5)]           // ▟ UR+LL+LR
        default: return nil
        }
    }
}
