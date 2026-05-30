import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Inline image protocols (Phase A): Sixel, Kitty graphics, iTerm2 — decode + placement, all
/// headless (no GPU). Rendering is verified separately.
final class ImageProtocolTests: XCTestCase {
    // A 1×1 red PNG (standard well-known blob).
    private let redPixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    // MARK: Decoders

    func testSixelDecodesColorAndDimensions() throws {
        // DCS q, define color 0 as RGB(100%,0,0), then '~' = all six vertical pixels in column 0.
        let payload = Array("q#0;2;100;0;0~".utf8)
        let img = try XCTUnwrap(SixelDecoder.decode(payload))
        XCTAssertEqual(img.pixelWidth, 1)
        XCTAssertEqual(img.pixelHeight, 6)
        XCTAssertEqual(img.rgba[0], 255) // R of the top pixel
        XCTAssertEqual(img.rgba[1], 0)
        XCTAssertEqual(img.rgba[2], 0)
        XCTAssertEqual(img.rgba[3], 255)
    }

    func testImageDecoderDecodesPNG() throws {
        let data = try XCTUnwrap(Data(base64Encoded: redPixelPNGBase64))
        let img = try XCTUnwrap(ImageDecoder.decode(data))
        XCTAssertEqual(img.pixelWidth, 1)
        XCTAssertEqual(img.pixelHeight, 1)
    }

    func testKittyRawRGBADecodes() {
        let pixels = [UInt8](repeating: 200, count: 2 * 2 * 4) // 2×2 RGBA
        let b64 = Array(Data(pixels).base64EncodedString().utf8)
        let cmd = try! XCTUnwrap(KittyGraphicsCommand.parse(Array("Gf=32,s=2,v=2,a=T".utf8) + [0x3B] + b64))
        let img = try! XCTUnwrap(cmd.decode(base64Payload: cmd.payload))
        XCTAssertEqual(img.pixelWidth, 2)
        XCTAssertEqual(img.pixelHeight, 2)
        XCTAssertEqual(img.rgba[0], 200)
    }

    // MARK: Placement (through the emulator)

    private func placements(_ term: TerminalEmulator) -> [ImagePlacementSnapshot] { term.readGrid().images }

    func testSixelPlacesImageInSnapshot() throws {
        let term = TerminalEmulator(cols: 20, rows: 10)
        term.feed("\u{1b}Pq#0;2;100;0;0~\u{1b}\\")
        let imgs = placements(term)
        XCTAssertEqual(imgs.count, 1)
        // 1×6 px with the default 8×16 cell → 1×1 cell footprint, anchored at the origin.
        XCTAssertEqual(imgs[0].row, 0)
        XCTAssertEqual(imgs[0].col, 0)
        XCTAssertEqual(imgs[0].cols, 1)
        XCTAssertEqual(imgs[0].rows, 1)
        XCTAssertNotNil(term.image(for: imgs[0].id))
    }

    func testKittyGraphicsPlaces() {
        let pixels = [UInt8](repeating: 100, count: 16 * 16 * 4) // 16×16 RGBA
        let b64 = Data(pixels).base64EncodedString()
        term_feedKitty(pixels: b64, s: 16, v: 16)
    }

    private func term_feedKitty(pixels b64: String, s: Int, v: Int) {
        let term = TerminalEmulator(cols: 40, rows: 20)
        term.feed("\u{1b}_Gf=32,s=\(s),v=\(v),a=T;\(b64)\u{1b}\\")
        let imgs = placements(term)
        XCTAssertEqual(imgs.count, 1)
        // 16×16 px / 8×16 cell → 2 cols × 1 row.
        XCTAssertEqual(imgs[0].cols, 2)
        XCTAssertEqual(imgs[0].rows, 1)
    }

    func testITerm2InlineImagePlaces() {
        let term = TerminalEmulator(cols: 20, rows: 10)
        term.feed("\u{1b}]1337;File=inline=1:\(redPixelPNGBase64)\u{07}")
        XCTAssertEqual(placements(term).count, 1)
    }

    func testImageScrollsThenDropsOffScreen() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        term.feed("\u{1b}Pq#0;2;100;0;0~\u{1b}\\")  // places at row 0 (1 cell tall)
        XCTAssertEqual(placements(term).count, 1)
        term.feed(String(repeating: "\r\n", count: 20)) // scroll well past it
        XCTAssertTrue(placements(term).isEmpty, "image fully scrolled off the top is dropped")
    }

    func testAltScreenIsolatesImages() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        term.feed("\u{1b}Pq#0;2;100;0;0~\u{1b}\\")
        XCTAssertEqual(placements(term).count, 1)
        term.feed("\u{1b}[?1049h")              // enter alt screen
        XCTAssertTrue(placements(term).isEmpty)
        term.feed("\u{1b}[?1049l")              // back to primary
        XCTAssertEqual(placements(term).count, 1)
    }

    func testResizeClearsImages() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        term.feed("\u{1b}Pq#0;2;100;0;0~\u{1b}\\")
        XCTAssertEqual(placements(term).count, 1)
        term.resize(cols: 30, rows: 8)
        XCTAssertTrue(placements(term).isEmpty)
    }
}
