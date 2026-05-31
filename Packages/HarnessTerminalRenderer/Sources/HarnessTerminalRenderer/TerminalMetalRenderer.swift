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
            imagePipeline = try Self.makePipeline(
                device: device, library: library,
                vertex: "image_vertex", fragment: "image_fragment", blending: true
            )
        } catch {
            return nil
        }
        self.imageCache = ImageTextureCache(device: device)

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
    public func render(_ frame: TerminalFrame, to target: MTLTexture, clearColor: RenderColor, origin: (x: Int, y: Int) = (0, 0), gamma: Float = 1, ligatures: Bool = false) {
        guard let commandBuffer = encode(frame, target: target, clearColor: clearColor, origin: origin, gamma: gamma, ligatures: ligatures) else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Render `frame` into a layer drawable and present it. Used by the live view.
    /// `origin` is the device-pixel offset of the grid's top-left (for window padding).
    /// `gamma` > 1 applies gamma-correct (linear) text coverage; 1 = native blending.
    /// `ligatures` enables CoreText run shaping (programming-font ligatures).
    /// `clearColor` carries the same default-background contract as `render(_:to:clearColor:…)`.
    public func present(_ frame: TerminalFrame, to drawable: CAMetalDrawable, clearColor: RenderColor, origin: (x: Int, y: Int) = (0, 0), gamma: Float = 1, ligatures: Bool = false) {
        guard let commandBuffer = encode(frame, target: drawable.texture, clearColor: clearColor, origin: origin, gamma: gamma, ligatures: ligatures) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Build the instance buffers and encode the background, glyph, and decoration passes
    /// into a fresh command buffer. Caller decides whether to wait (offscreen) or present.
    private func encode(_ frame: TerminalFrame, target: MTLTexture, clearColor: RenderColor, origin: (x: Int, y: Int), gamma: Float, ligatures: Bool) -> MTLCommandBuffer? {
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
            // Default canvas cells already match the cleared target, so the FrameBuilder marks
            // them `drawBackground == false` and we skip the redundant quad. Block-element fills
            // and decorations below still emit unconditionally.
            if cell.drawBackground {
                backgrounds.append(BgInstance(
                    origin: SIMD2(originX, originY),
                    size: SIMD2(cellW, cellH),
                    color: vector(cell.background)
                ))
            }

            // Block-element characters (█ ▀ ▄ ▌ quadrants …) are drawn as exact-fill rects in
            // the foreground color rather than as font glyphs — font glyphs leave sub-pixel
            // gaps that show as grid seams in block art (the Codex/Claude mascots). The fills
            // share the background pass (opaque, painter-ordered after the cell bg).
            if let rects = Self.blockElementRects(cell.codepoint) {
                let fill = vector(cell.foreground)
                for r in rects {
                    let x0 = originX + (r.0 * cellW).rounded()
                    let y0 = originY + (r.1 * cellH).rounded()
                    let x1 = originX + ((r.0 + r.2) * cellW).rounded()
                    let y1 = originY + ((r.1 + r.3) * cellH).rounded()
                    backgrounds.append(BgInstance(
                        origin: SIMD2(x0, y0), size: SIMD2(x1 - x0, y1 - y0), color: fill
                    ))
                }
            }

            // Line decorations sit on top of the glyph; emit for the full cell.
            appendDecorations(cell, originX: originX, originY: originY,
                              cellSize: SIMD2(cellW, cellH),
                              thickness: thickness, underlineY: underlineY,
                              strikeY: strikeY, overlineY: overlineY, into: &decorations)
        }

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

        // Glyphs: ligated CoreText run shaping when enabled, else the fast per-cell path.
        // Both place each glyph on its source cell so the monospace grid stays aligned.
        let cursorCell = invertCursorGlyph ? (row: cursorRow, column: cursorCol) : nil
        if ligatures {
            emitLigatedGlyphs(frame, ox: ox, oy: oy, cursorCell: cursorCell,
                              cursorTextColor: frame.cursor.textColor, into: &glyphs)
        } else {
            emitPerCellGlyphs(frame, ox: ox, oy: oy, cursorCell: cursorCell,
                              cursorTextColor: frame.cursor.textColor, into: &glyphs)
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
        // Background pass. `makeBuffer(length:)` is undefined for length 0, so skip an empty
        // pass (the glyph/decoration passes already guard the same way) — production clamps the
        // grid to ≥1×1, but a directly-constructed empty frame must not hit a zero-length buffer.
        if !backgrounds.isEmpty,
           let buffer = device.makeBuffer(bytes: backgrounds, length: backgrounds.count * MemoryLayout<BgInstance>.stride, options: .storageModeShared) {
            renderEncoder.setRenderPipelineState(bgPipeline)
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: backgrounds.count)
        }

        // Images with z < 0 draw below text (Kitty negative z-index).
        drawImages(frame.images.filter { $0.z < 0 }, encoder: renderEncoder, viewport: &vp, ox: ox, oy: oy)

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

        // Images with z >= 0 (the default) draw above text.
        drawImages(frame.images.filter { $0.z >= 0 }, encoder: renderEncoder, viewport: &vp, ox: ox, oy: oy)

        renderEncoder.endEncoding()
        return commandBuffer
    }

    /// Draw each inline image as a textured quad at its cell rect. One draw per image (each has
    /// its own texture); the GPU clips quads that extend past the viewport (images scrolling off).
    private func drawImages(_ images: [FrameImage], encoder: MTLRenderCommandEncoder, viewport: inout SIMD2<Float>, ox: Float, oy: Float) {
        guard !images.isEmpty else { return }
        let cellW = Float(cellPixelWidth), cellH = Float(cellPixelHeight)
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for img in images {
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
        }
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
        _ frame: TerminalFrame, ox: Float, oy: Float,
        cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor,
        into glyphs: inout [GlyphInstance]
    ) {
        for cell in frame.cells {
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
        _ frame: TerminalFrame, ox: Float, oy: Float,
        cursorCell: (row: Int, column: Int)?, cursorTextColor: RenderColor,
        into glyphs: inout [GlyphInstance]
    ) {
        let cols = frame.columns
        for row in 0 ..< frame.rows {
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
    /// of font glyphs) tiles seamlessly the way Ghostty/kitty render block art.
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

