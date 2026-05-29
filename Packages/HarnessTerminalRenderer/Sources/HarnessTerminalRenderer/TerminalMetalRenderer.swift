import HarnessTerminalEngine
import Metal
import QuartzCore
import simd

/// GPU instance layouts — must match the structs in `MetalShaders.source`.
private struct BgInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
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

/// Line-decoration styles; raw values match the `kind` switch in `deco_fragment`.
private enum DecoKind: UInt32 {
    case solid = 0
    case double = 1
    case dotted = 2
    case dashed = 3
    case curly = 4
}

/// Renders a `TerminalFrame` with Metal: a solid background pass over every cell, then a
/// texture-sampled glyph pass, then the cursor. Pixel sizes derive from the font's cell
/// metrics × display scale. Designed to draw into either an offscreen texture (tests) or a
/// `CAMetalLayer` drawable (the live view, added next).
public final class TerminalMetalRenderer {
    public let device: MTLDevice
    public let cellPixelWidth: Int
    public let cellPixelHeight: Int

    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let decoPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let ascentPixels: Int
    /// The render-target pixel format both pipelines are built for.
    public static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    public init?(device: MTLDevice, fontFamily: String, fontSize: CGFloat, scale: CGFloat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let rasterizer = GlyphRasterizer(fontFamily: fontFamily, size: fontSize, scale: scale)
        guard let atlas = GlyphAtlas(device: device, rasterizer: rasterizer) else { return nil }

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
        } catch {
            return nil
        }

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
    public func render(_ frame: TerminalFrame, to target: MTLTexture, clearColor: RenderColor, origin: (x: Int, y: Int) = (0, 0), gamma: Float = 1) {
        guard let commandBuffer = encode(frame, target: target, clearColor: clearColor, origin: origin, gamma: gamma) else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Render `frame` into a layer drawable and present it. Used by the live view.
    /// `origin` is the device-pixel offset of the grid's top-left (for window padding).
    /// `gamma` > 1 applies gamma-correct (linear) text coverage; 1 = native blending.
    public func present(_ frame: TerminalFrame, to drawable: CAMetalDrawable, clearColor: RenderColor, origin: (x: Int, y: Int) = (0, 0), gamma: Float = 1) {
        guard let commandBuffer = encode(frame, target: drawable.texture, clearColor: clearColor, origin: origin, gamma: gamma) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Build the instance buffers and encode the background, glyph, and decoration passes
    /// into a fresh command buffer. Caller decides whether to wait (offscreen) or present.
    private func encode(_ frame: TerminalFrame, target: MTLTexture, clearColor: RenderColor, origin: (x: Int, y: Int), gamma: Float) -> MTLCommandBuffer? {
        let viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        let ox = Float(origin.x)
        let oy = Float(origin.y)
        let cellW = Float(cellPixelWidth)
        let cellH = Float(cellPixelHeight)
        // Decoration geometry (px): line thickness, underline baseline offset, etc.
        let thickness = max(1, Float(cellPixelHeight) / 16)
        let underlineY = min(cellH - thickness, Float(ascentPixels) + max(1, cellH * 0.08))
        let strikeY = Float(ascentPixels) * 0.65
        let overlineY = thickness

        // Cursor cell + whether the glyph there should flip to the cursor-text color.
        let cursorCol = frame.cursor.column
        let cursorRow = frame.cursor.row
        let invertCursorGlyph = frame.cursor.visible && frame.cursor.style == .block

        var backgrounds: [BgInstance] = []
        backgrounds.reserveCapacity(frame.cells.count + 1)
        var glyphs: [GlyphInstance] = []
        var decorations: [DecoInstance] = []

        for cell in frame.cells {
            let originX = ox + Float(cell.column * cellPixelWidth)
            let originY = oy + Float(cell.row * cellPixelHeight)
            backgrounds.append(BgInstance(
                origin: SIMD2(originX, originY),
                size: SIMD2(cellW, cellH),
                color: vector(cell.background)
            ))

            // Line decorations sit on top of the glyph; emit for the full cell.
            appendDecorations(cell, originX: originX, originY: originY,
                              cellSize: SIMD2(cellW, cellH),
                              thickness: thickness, underlineY: underlineY,
                              strikeY: strikeY, overlineY: overlineY, into: &decorations)

            guard cell.hasGlyph,
                  let entry = atlas.entry(for: GlyphKey(codepoint: cell.codepoint, bold: cell.bold, italic: cell.italic))
            else { continue }

            // The glyph under a block cursor flips to the cursor-text color for legibility.
            let fg = (invertCursorGlyph && cell.row == cursorRow && cell.column == cursorCol)
                ? vector(frame.cursor.textColor)
                : vector(cell.foreground)
            let gx = originX + Float(entry.bearingX)
            let gy = originY + Float(ascentPixels - entry.bearingY)
            glyphs.append(GlyphInstance(
                origin: SIMD2(gx, gy),
                size: SIMD2(Float(entry.pixelWidth), Float(entry.pixelHeight)),
                uvOrigin: entry.uvOrigin,
                uvSize: entry.uvSize,
                color: fg
            ))
        }

        // Cursor: block fills the cell (glyphs still draw on top); bar is a thin left
        // edge; underline is a thin bottom edge. All respect the grid origin offset.
        if frame.cursor.visible {
            let cellX = ox + Float(frame.cursor.column * cellPixelWidth)
            let cellY = oy + Float(frame.cursor.row * cellPixelHeight)
            let cellW = Float(cellPixelWidth)
            let cellH = Float(cellPixelHeight)
            let cursorOrigin: SIMD2<Float>
            let cursorSize: SIMD2<Float>
            switch frame.cursor.style {
            case .block:
                cursorOrigin = SIMD2(cellX, cellY)
                cursorSize = SIMD2(cellW, cellH)
            case .bar:
                let w = max(2, Float(cellPixelWidth) / 8)
                cursorOrigin = SIMD2(cellX, cellY)
                cursorSize = SIMD2(w, cellH)
            case .underline:
                let h = max(2, Float(cellPixelHeight) / 10)
                cursorOrigin = SIMD2(cellX, cellY + cellH - h)
                cursorSize = SIMD2(cellW, h)
            }
            backgrounds.append(BgInstance(
                origin: cursorOrigin,
                size: cursorSize,
                color: vector(frame.cursor.color)
            ))
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearColor.red), green: Double(clearColor.green),
            blue: Double(clearColor.blue), alpha: Double(clearColor.alpha)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }

        var vp = viewport
        // Background pass.
        if let buffer = device.makeBuffer(bytes: backgrounds, length: backgrounds.count * MemoryLayout<BgInstance>.stride, options: .storageModeShared) {
            renderEncoder.setRenderPipelineState(bgPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: backgrounds.count)
        }

        // Glyph pass (with the gamma-correct coverage uniform).
        if !glyphs.isEmpty,
           let buffer = device.makeBuffer(bytes: glyphs, length: glyphs.count * MemoryLayout<GlyphInstance>.stride, options: .storageModeShared) {
            var glyphGamma = max(0.1, gamma)
            renderEncoder.setRenderPipelineState(glyphPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.setFragmentTexture(atlas.texture, index: 0)
            renderEncoder.setFragmentSamplerState(sampler, index: 0)
            renderEncoder.setFragmentBytes(&glyphGamma, length: MemoryLayout<Float>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }

        // Decoration pass (underline family / strikethrough / overline) — over the glyphs.
        if !decorations.isEmpty,
           let buffer = device.makeBuffer(bytes: decorations, length: decorations.count * MemoryLayout<DecoInstance>.stride, options: .storageModeShared) {
            renderEncoder.setRenderPipelineState(decoPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: decorations.count)
        }

        renderEncoder.endEncoding()
        return commandBuffer
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

    private func vector(_ c: RenderColor) -> SIMD4<Float> {
        SIMD4(c.red, c.green, c.blue, c.alpha)
    }
}

