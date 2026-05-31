import Metal
import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

/// Offscreen golden-image tests: render a known frame to a texture and read pixels back.
/// They validate the whole GPU path (device, pipelines, atlas, coordinate mapping,
/// blending) without a window. Skipped where no Metal device is available.
final class MetalRendererTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!

    private func makeRenderer() throws -> (MTLDevice, TerminalMetalRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        // A device exists, so a nil renderer means a real shader/pipeline failure — fail
        // rather than skip so it surfaces.
        let renderer = try XCTUnwrap(
            TerminalMetalRenderer(device: device, fontFamily: "Menlo", fontSize: 14, scale: 2),
            "TerminalMetalRenderer failed to build (shader/pipeline error)"
        )
        return (device, renderer)
    }

    private func makeTarget(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TerminalMetalRenderer.pixelFormat, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    private func frame(_ bytes: String, cols: Int, rows: Int) -> TerminalFrame {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return FrameBuilder(theme: theme).build(term.readGrid()!)
    }

    func testRendererInitializes() throws {
        let (_, renderer) = try makeRenderer()
        XCTAssertGreaterThan(renderer.cellPixelWidth, 0)
        XCTAssertGreaterThan(renderer.cellPixelHeight, 0)
        let size = renderer.surfacePixelSize(columns: 80, rows: 24)
        XCTAssertEqual(size.width, renderer.cellPixelWidth * 80)
        XCTAssertEqual(size.height, renderer.cellPixelHeight * 24)
    }

    func testBackgroundColorsRenderPerCell() throws {
        let (device, renderer) = try makeRenderer()
        // Cursor hidden so it doesn't paint over a cell; two spaces, red then blue bg.
        let f = frame("\u{1b}[?25l\u{1b}[48;2;255;0;0m \u{1b}[48;2;0;0;255m ", cols: 2, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 2, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)

        let left = px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2)
        let right = px(renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2)
        assertColor(left, r: 255, g: 0, b: 0, label: "left cell red bg")
        assertColor(right, r: 0, g: 0, b: 255, label: "right cell blue bg")
    }

    func testGlyphRendersForegroundColor() throws {
        let (device, renderer) = try makeRenderer()
        // Full block U+2588 in green fills the cell with the foreground color.
        let f = frame("\u{1b}[?25l\u{1b}[38;2;0;255;0m\u{2588}", cols: 1, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)
        let center = px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2)
        // Block coverage at center is ~1, so the cell reads as green.
        assertColor(center, r: 0, g: 255, b: 0, label: "block glyph green", tolerance: 32)
    }

    func testInlineImageRendersOverCell() throws {
        let (device, renderer) = try makeRenderer()
        let (w, h) = renderer.surfacePixelSize(columns: 2, rows: 2)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        // A solid-green image the size of one cell, placed at cell (0,0).
        let iw = renderer.cellPixelWidth, ih = renderer.cellPixelHeight
        var rgba = [UInt8](repeating: 0, count: iw * ih * 4)
        for p in 0 ..< (iw * ih) { rgba[p * 4 + 1] = 255; rgba[p * 4 + 3] = 255 }
        let img = DecodedImage(rgba: rgba, pixelWidth: iw, pixelHeight: ih)
        var f = FrameBuilder(theme: theme).build(HarnessGridTerminal(cols: 2, rows: 2)!.readGrid()!)
        f.images = [FrameImage(id: 1, column: 0, row: 0, columns: 1, rows: 1, z: 0, image: img)]

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)
        // Inside the image: green. A cell with no image: not green.
        assertColor(px(iw / 2, ih / 2), r: 0, g: 255, b: 0, label: "inline image green", tolerance: 24)
        XCTAssertLessThan(Int(px(iw + iw / 2, ih + ih / 2).1), 160, "no-image cell isn't green")
    }

    func testPromptGutterStripeRendersInLeftPadding() throws {
        let (device, renderer) = try makeRenderer()
        // A prompt that succeeded → green stripe (ANSI green, palette[2]). Cursor hidden so it
        // can't paint anything; the prompt row stays at viewport row 0.
        let f = frame("\u{1b}[?25l\u{1b}]133;A\u{07}$ ok\r\n\u{1b}]133;D;0\u{07}", cols: 4, rows: 4)
        XCTAssertEqual(f.promptGutter[0], RenderColor(theme.palette[2]), "succeeded prompt → green gutter")
        let grid = renderer.surfacePixelSize(columns: 4, rows: 4)
        let pad = 12
        guard let target = makeTarget(device, width: grid.width + pad, height: grid.height) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target,
                        clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
                        origin: (x: pad, y: 0))
        let px = readPixels(target, width: grid.width + pad, height: grid.height)

        // The stripe sits in the padding flush to the grid's left edge ([pad-gutterW, pad)), on
        // the prompt row (row 0). Sample its rightmost pixel; the far-left padding stays black.
        let g = theme.palette[2]
        let y = renderer.cellPixelHeight / 2
        assertColor(px(pad - 1, y), r: Int(g.red), g: Int(g.green), b: Int(g.blue),
                    label: "prompt gutter green", tolerance: 24)
        assertColor(px(0, y), r: 0, g: 0, b: 0, label: "padding left of the gutter stays clear")
    }

    func testDefaultCanvasCellRevealsClearColor() throws {
        let (device, renderer) = try makeRenderer()
        // Cursor hidden; the blank default-background cells must not paint a quad, so the target
        // keeps the clear color (which in production equals the canvas background, making the
        // skip invisible). A pre-skip renderer would paint the theme bg over the clear instead.
        let f = frame("\u{1b}[?25l", cols: 2, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 2, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 1, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)
        assertColor(px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 255, g: 0, b: 0, label: "blank cell reveals red clear color")
    }

    func testCursorFillDrawsOverSkippedDefaultCell() throws {
        let (device, renderer) = try makeRenderer()
        // The single cell is default-background (its quad is skipped), but the visible block
        // cursor must still paint over it.
        let f = frame("", cols: 1, rows: 1)
        XCTAssertTrue(f.cursor.visible, "program cursor visible by default")
        let (w, h) = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)
        let cursor = theme.cursor ?? theme.foreground
        assertColor(px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(cursor.red), g: Int(cursor.green), b: Int(cursor.blue),
                    label: "block cursor fill over skipped cell", tolerance: 24)
    }

    // MARK: - Pixel helpers

    private func readPixels(_ texture: MTLTexture, width: Int, height: Int) -> (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return { x, y in
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    private func assertColor(_ c: (UInt8, UInt8, UInt8, UInt8), r: Int, g: Int, b: Int, label: String, tolerance: Int = 8) {
        XCTAssertLessThanOrEqual(abs(Int(c.0) - r), tolerance, "\(label) red (\(c.0) vs \(r))")
        XCTAssertLessThanOrEqual(abs(Int(c.1) - g), tolerance, "\(label) green (\(c.1) vs \(g))")
        XCTAssertLessThanOrEqual(abs(Int(c.2) - b), tolerance, "\(label) blue (\(c.2) vs \(b))")
    }
}
