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
