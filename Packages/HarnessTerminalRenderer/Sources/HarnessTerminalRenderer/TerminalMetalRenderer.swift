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
        encodeNanos: UInt64 = 0
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
    }
}

/// GPU instance layouts — must match the structs in `MetalShaders.source`.
private struct BgInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct PendingBgSpan {
    var row: Int
    var endColumn: Int
    var color: RenderColor
    var instance: BgInstance
}

private struct EncodedRowInstances {
    var backgrounds: [BgInstance] = []
    var glyphs: [GlyphInstance] = []
    var decorations: [DecoInstance] = []
    var bgSpans = 0
    var bgCells = 0
}

private struct EncodedFrameInstances {
    var backgrounds: [BgInstance] = []
    var glyphs: [GlyphInstance] = []
    var decorations: [DecoInstance] = []
    var bgSpans = 0
    var bgCells = 0
    var encodedRows = 0
    var reusedRows = 0
}

private struct CursorCacheKey: Equatable {
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

private struct RowInstanceCache {
    var columns = 0
    var rows = 0
    var originX = 0
    var originY = 0
    var ligatures = false
    var atlasResets = 0
    var rowInstances: [EncodedRowInstances?] = []
    var previousCursor: CursorCacheKey?
}

private struct PromptGutterUploadKey: Equatable {
    var row: Int
    var color: RenderColor
}

private struct InstanceUploadCacheKey: Equatable {
    var columns: Int
    var rows: Int
    var originX: Int
    var originY: Int
    var ligatures: Bool
    var cursor: CursorRender
    var promptGutter: [PromptGutterUploadKey]
}

private struct UploadedInstanceBuffers {
    var key: InstanceUploadCacheKey
    var backgrounds: MTLBuffer?
    var backgroundCount: Int
    var glyphs: MTLBuffer?
    var glyphCount: Int
    var decorations: MTLBuffer?
    var decorationCount: Int
    var uploadBytes: Int
}

private struct GlyphInstance {
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
private struct DecoInstance {
    var color: SIMD4<Float>
    /// (centerY, thickness, amplitude, period) in px.
    var params: SIMD4<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var kind: UInt32
}

/// One inline-image quad (pixel origin + size); the texture is bound per draw.
private struct ImageInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

/// Line-decoration styles; raw values match the `kind` switch in `deco_fragment`.
private enum DecoKind: UInt32 {
    case solid = 0
    case double = 1
    case dotted = 2
    case dashed = 3
    case curly = 4
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
    /// Immutable instance buffers for an unchanged frame. When damage is empty and the overlay
    /// key still matches, the renderer can bind these without another CPU memcpy.
    private var uploadedInstanceCache: UploadedInstanceBuffers?
    /// Caps in-flight frames at `maxFramesInFlight` so we never reuse a ring slot the GPU is
    /// still reading. Signaled from each command buffer's completion handler.
    private let inFlightSemaphore = DispatchSemaphore(value: TerminalMetalRenderer.maxFramesInFlight)
    /// Index of the ring slot the current frame writes into; advanced once per `encode`.
    private var frameSlot = 0

    public init?(
        device: MTLDevice,
        fontFamily: String,
        fontSize: CGFloat,
        scale: CGFloat,
        atlasSize: Int = 1024,
        atlasMaxPages: Int = 4
    ) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let rasterizer = GlyphRasterizer(fontFamily: fontFamily, size: fontSize, scale: scale)
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
        frameBuildNanos: UInt64 = 0
    ) -> Bool {
        guard let commandBuffer = encode(
            frame, target: target, clearColor: clearColor, origin: origin,
            gamma: gamma, ligatures: ligatures, damage: damage,
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
    @discardableResult
    public func present(
        _ frame: TerminalFrame,
        to drawable: CAMetalDrawable,
        clearColor: RenderColor,
        origin: (x: Int, y: Int) = (0, 0),
        gamma: Float = 1,
        ligatures: Bool = false,
        damage: TerminalDamage? = nil,
        frameBuildNanos: UInt64 = 0
    ) -> Bool {
        guard let commandBuffer = encode(
            frame, target: drawable.texture, clearColor: clearColor, origin: origin,
            gamma: gamma, ligatures: ligatures, damage: damage,
            frameBuildNanos: frameBuildNanos
        ) else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    /// Build the instance buffers and encode the background, glyph, and decoration passes
    /// into a fresh command buffer. Caller decides whether to wait (offscreen) or present.
    func encode(
        _ frame: TerminalFrame,
        target: MTLTexture,
        clearColor: RenderColor,
        origin: (x: Int, y: Int),
        gamma: Float,
        ligatures: Bool,
        damage: TerminalDamage? = nil,
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

        let encoded = buildFrameInstances(
            frame,
            origin: origin,
            cellSize: SIMD2(cellW, cellH),
            ligatures: ligatures,
            damage: damage,
            thickness: thickness,
            underlineY: underlineY,
            strikeY: strikeY,
            overlineY: overlineY
        )
        var backgrounds = encoded.backgrounds
        let glyphs = encoded.glyphs
        let decorations = encoded.decorations

        // OSC 133 prompt gutter: a thin vertical stripe in the left margin marking shell-prompt
        // rows (green/red/neutral, resolved in the FrameBuilder). Appended after the cell
        // backgrounds so it paints over them; it sits in the window padding (flush to the grid's
        // left edge, falling back to column 0's bearing when there's no padding), where no glyph
        // draws — so it never collides with text. No-op without shell-integration marks.
        if !frame.promptGutter.isEmpty {
            let gutterW = max(2, (cellW * 0.14).rounded())
            let gx = max(0, ox - gutterW)
            for (row, color) in frame.promptGutter where row >= 0 && row < frame.rows {
                backgrounds.append(BgInstance(
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
        if frame.cursor.visible {
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
                    backgrounds.append(BgInstance(origin: cursorOrigin, size: cursorSize, color: color))
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
                backgrounds.append(BgInstance(origin: cursorOrigin, size: cursorSize, color: color))
            }
        }
        frameStats.bgInstances = backgrounds.count
        frameStats.bgSpans = encoded.bgSpans
        frameStats.bgCells = encoded.bgCells
        frameStats.glyphInstances = glyphs.count
        frameStats.decoInstances = decorations.count
        frameStats.encodedRows = encoded.encodedRows
        frameStats.reusedRows = encoded.reusedRows

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.premultipliedClearColor(clearColor)

        // Reserve an in-flight slot before touching the instance-buffer ring, then advance to
        // the next slot so this frame writes a buffer no longer read by the GPU. The semaphore
        // blocks here if `maxFramesInFlight` frames are already queued.
        inFlightSemaphore.wait()
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

        var vp = viewport
        let instanceBuffers = bindableInstanceBuffers(
            backgrounds: backgrounds,
            glyphs: glyphs,
            decorations: decorations,
            frame: frame,
            origin: origin,
            ligatures: ligatures,
            damage: damage,
            encoded: encoded,
            slot: frameSlot
        )
        frameStats.instanceUploadBytes = instanceBuffers.uploadBytes

        // Background pass. Empty instance arrays bind nothing, so a directly-constructed empty
        // frame never hits a zero-length buffer.
        if let buffer = instanceBuffers.backgrounds {
            renderEncoder.setRenderPipelineState(bgPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
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
        slot: Int
    ) -> UploadedInstanceBuffers {
        let uploadBytes =
            backgrounds.count * MemoryLayout<BgInstance>.stride
            + glyphs.count * MemoryLayout<GlyphInstance>.stride
            + decorations.count * MemoryLayout<DecoInstance>.stride
        let key = instanceUploadCacheKey(frame: frame, origin: origin, ligatures: ligatures)
        let frameShapeIsValid = frame.columns > 0
            && frame.rows > 0
            && frame.cells.count == frame.columns * frame.rows
        let stableFrame = damage != nil
            && damage?.full == false
            && encoded.encodedRows == 0
            && encoded.reusedRows == frame.rows
            && frameShapeIsValid
            && frame.images.isEmpty

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

        uploadedInstanceCache = nil
        return UploadedInstanceBuffers(
            key: key,
            backgrounds: bgInstanceBuffer.upload(backgrounds, slot: slot),
            backgroundCount: backgrounds.count,
            glyphs: glyphInstanceBuffer.upload(glyphs, slot: slot),
            glyphCount: glyphs.count,
            decorations: decoInstanceBuffer.upload(decorations, slot: slot),
            decorationCount: decorations.count,
            uploadBytes: uploadBytes
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

    private func instanceUploadCacheKey(
        frame: TerminalFrame,
        origin: (x: Int, y: Int),
        ligatures: Bool
    ) -> InstanceUploadCacheKey {
        let gutter = frame.promptGutter
            .map { PromptGutterUploadKey(row: $0.key, color: $0.value) }
            .sorted { $0.row < $1.row }
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

    private func buildFrameInstances(
        _ frame: TerminalFrame,
        origin: (x: Int, y: Int),
        cellSize: SIMD2<Float>,
        ligatures: Bool,
        damage: TerminalDamage?,
        thickness: Float,
        underlineY: Float,
        strikeY: Float,
        overlineY: Float
    ) -> EncodedFrameInstances {
        guard frame.columns > 0,
              frame.rows > 0,
              frame.cells.count == frame.columns * frame.rows
        else {
            resetRowInstanceCache()
            return EncodedFrameInstances()
        }

        guard let damage, frame.images.isEmpty else {
            resetRowInstanceCache()
            return buildFrameInstancesWithoutCache(
                frame, origin: origin, cellSize: cellSize, ligatures: ligatures,
                thickness: thickness, underlineY: underlineY, strikeY: strikeY,
                overlineY: overlineY
            )
        }

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

        var dirtyRows = clampedRows(damage.rows, rowCount: frame.rows)
        if damage.full || !cacheMatches {
            rowInstanceCache = RowInstanceCache(
                columns: frame.columns,
                rows: frame.rows,
                originX: origin.x,
                originY: origin.y,
                ligatures: ligatures,
                atlasResets: atlas.stats.resets,
                rowInstances: Array(repeating: nil, count: frame.rows),
                previousCursor: nil
            )
            dirtyRows = IndexSet(integersIn: 0 ..< frame.rows)
        }

        if rowInstanceCache.previousCursor != cursorKey {
            if let previous = rowInstanceCache.previousCursor, previous.invertsGlyph {
                insert(row: previous.row, into: &dirtyRows, rowCount: frame.rows)
            }
            if cursorKey.invertsGlyph {
                insert(row: cursorKey.row, into: &dirtyRows, rowCount: frame.rows)
            }
        }

        let atlasResetsBefore = atlas.stats.resets
        var encoded = EncodedFrameInstances()
        encoded.backgrounds.reserveCapacity(frame.cells.count + 1)
        encoded.glyphs.reserveCapacity(frame.cells.count)
        encoded.decorations.reserveCapacity(frame.cells.count / 8)

        for row in 0 ..< frame.rows {
            let rowInstances: EncodedRowInstances
            if dirtyRows.contains(row) || rowInstanceCache.rowInstances[row] == nil {
                rowInstances = encodeRowInstances(
                    row,
                    frame: frame,
                    origin: origin,
                    cellSize: cellSize,
                    ligatures: ligatures,
                    cursorKey: cursorKey,
                    thickness: thickness,
                    underlineY: underlineY,
                    strikeY: strikeY,
                    overlineY: overlineY
                )
                rowInstanceCache.rowInstances[row] = rowInstances
                encoded.encodedRows += 1
            } else {
                rowInstances = rowInstanceCache.rowInstances[row]!
                encoded.reusedRows += 1
            }
            append(rowInstances, into: &encoded)
        }
        rowInstanceCache.previousCursor = cursorKey

        if atlas.stats.resets != atlasResetsBefore {
            let reusedRows = encoded.reusedRows
            resetRowInstanceCache()
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
        encoded.backgrounds.reserveCapacity(frame.cells.count + 1)
        encoded.glyphs.reserveCapacity(frame.cells.count)
        encoded.decorations.reserveCapacity(frame.cells.count / 8)
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
            append(rowInstances, into: &encoded)
        }
        return encoded
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

            appendDecorations(cell, originX: originX, originY: originY,
                              cellSize: cellSize,
                              thickness: thickness, underlineY: underlineY,
                              strikeY: strikeY, overlineY: overlineY,
                              into: &encoded.decorations)
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

    private func append(_ row: EncodedRowInstances, into encoded: inout EncodedFrameInstances) {
        encoded.backgrounds.append(contentsOf: row.backgrounds)
        encoded.glyphs.append(contentsOf: row.glyphs)
        encoded.decorations.append(contentsOf: row.decorations)
        encoded.bgSpans += row.bgSpans
        encoded.bgCells += row.bgCells
    }

    private func resetRowInstanceCache() {
        rowInstanceCache = RowInstanceCache()
        uploadedInstanceCache = nil
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
            guard cell.hasGlyph, !Self.isBlockElement(cell.codepoint),
                  let entry = atlas.entry(for: GlyphKey(codepoint: cell.codepoint, bold: cell.bold, italic: cell.italic))
            else { continue }
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
    private func emitLigatedGlyphs(
        row: Int, frame: TerminalFrame, ox: Float, oy: Float,
        cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor,
        into glyphs: inout [GlyphInstance]
    ) {
        let cols = frame.columns
        var col = 0
        while col < cols {
            guard let cell = frame.cell(row: row, column: col), cell.hasGlyph,
                  !Self.isBlockElement(cell.codepoint) else {
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
            // Accumulate a run of contiguous, same-style, same-color glyph cells.
            var runText = ""
            var utf16ToColumn: [Int] = []
            let bold = cell.bold, italic = cell.italic, fg = cell.foreground
            var c = col
            while c < cols, let rc = frame.cell(row: row, column: c) {
                if rc.width == .spacerTail { c += 1; continue } // wide-char tail
                if !rc.hasGlyph { break }
                if Self.isBlockElement(rc.codepoint) { break } // drawn procedurally
                if BoxDrawing.supported(rc.codepoint) { break } // procedural box sprite
                if GlyphRasterizer.isNerdFontCodepoint(rc.codepoint) { break } // icon → per-cell symbol fallback
                if let cur = cursorCell, cur.row == row, cur.column == c { break }
                if rc.bold != bold || rc.italic != italic || rc.foreground != fg { break }
                let scalar = Unicode.Scalar(rc.codepoint) ?? " "
                let before = runText.utf16.count
                runText.unicodeScalars.append(scalar)
                for _ in before ..< runText.utf16.count { utf16ToColumn.append(c) }
                c += 1
            }
            if utf16ToColumn.isEmpty { col += 1; continue }
            let color = vector(fg)
            for shaped in atlas.shape(runText, bold: bold, italic: italic) {
                guard let entry = atlas.entry(forShaped: shaped.glyph, font: shaped.font) else { continue }
                let idx = min(max(0, shaped.utf16Index), utf16ToColumn.count - 1)
                let cellColumn = utf16ToColumn[idx]
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
        guard cell.hasGlyph, !Self.isBlockElement(cell.codepoint),
              let entry = atlas.entry(for: GlyphKey(codepoint: cell.codepoint, bold: cell.bold, italic: cell.italic))
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
