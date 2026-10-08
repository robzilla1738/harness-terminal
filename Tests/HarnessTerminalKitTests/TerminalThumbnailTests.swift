import AppKit
import HarnessTerminalEngine
import HarnessTerminalRenderer
import Metal
import XCTest
@testable import HarnessTerminalKit

/// Overview / tab-peek thumbnails: drawn by the terminal renderer at a fitted scale, rebuilt only
/// for new output, and never a write to the pane they show.
@MainActor
final class TerminalThumbnailTests: XCTestCase {
    private func makeSurface() -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: false)
        view.configureAppearance(
            fontFamily: "Menlo",
            fontSize: 14,
            vivid: false,
            canvasBackgroundHex: "#000000",
            canvasForegroundHex: "#ffffff",
            cursorHex: "#ffffff",
            outputPaletteHex: Array(repeating: nil, count: 16),
            canvasOpacity: 1,
            cursorStyle: "block",
            cursorBlink: true,
            paddingX: 0,
            paddingY: 0,
            selectionBackgroundHex: nil,
            selectionForegroundHex: nil,
            copyOnSelect: false,
            scrollbackLines: 1000,
            linearBlending: false,
            ligatures: true,
            offMainParserFramePipeline: false
        )
        view.testingResizeGrid(cols: 80, rows: 24) // headless, the view sized itself to nothing
        return view
    }

    private func thumbnail(of source: TerminalThumbnailSource) throws -> TerminalThumbnail {
        var built: TerminalThumbnail?
        source.thumbnail { built = $0 } // synchronous on the main-confined pipeline
        return try XCTUnwrap(built)
    }

    private func text(_ frame: TerminalFrame, row: Int) -> String {
        String(String.UnicodeScalarView((0 ..< frame.columns).compactMap {
            frame.cell(row: row, column: $0).flatMap { Unicode.Scalar($0.codepoint == 0 ? 32 : $0.codepoint) }
        })).trimmingCharacters(in: .whitespaces)
    }

    func testScaleFitsWholePixelCellsAndNeverGrowsPastThePane() {
        let cell = CellMetrics(width: 8.4, height: 17, ascent: 13, descent: 4, leading: 0)
        let scale = TerminalThumbnailView.scale(fitting: (600, 300), columns: 80, rows: 24, cell: cell, backing: 2)
        let cellHeight = cell.height * scale
        XCTAssertEqual(cellHeight, cellHeight.rounded(), "cells land on whole device pixels")
        XCTAssertLessThanOrEqual(80 * (cell.width * scale).rounded(), 600)
        XCTAssertLessThanOrEqual(24 * cellHeight, 300)
        let larger = (cellHeight + 1) / cell.height
        XCTAssertTrue(
            80 * (cell.width * larger).rounded() > 600 || 24 * (cellHeight + 1) > 300,
            "the largest whole-pixel cell that fits"
        )
        XCTAssertEqual(
            TerminalThumbnailView.scale(fitting: (2000, 2000), columns: 10, rows: 2, cell: cell, backing: 2), 2,
            "a small pane in a big tile draws at the pane's own size"
        )
    }

    func testThumbnailRendersSmallIntoATextureOfTheFittedGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device available") }
        let surface = makeSurface()
        surface.receive("\u{1b}[42mhello\u{1b}[0m world")
        let shot = try thumbnail(of: surface)
        XCTAssertEqual(shot.frame.columns, 80)
        XCTAssertEqual(shot.frame.rows, 24)

        let (width, height) = (320, 200)
        let metrics = GlyphRasterizer(fontFamily: "Menlo", size: 14).metrics()
        let scale = TerminalThumbnailView.scale(fitting: (width, height), columns: 80, rows: 24, cell: metrics, backing: 2)
        let renderer = try XCTUnwrap(TerminalMetalRenderer(device: device, fontFamily: "Menlo", fontSize: 14, scale: scale, atlasSize: 512))
        let grid = renderer.surfacePixelSize(columns: 80, rows: 24)
        XCTAssertLessThanOrEqual(grid.width, width)
        XCTAssertLessThanOrEqual(grid.height, height)
        XCTAssertGreaterThan(grid.width, width / 2, "fills the tile, not a corner of it")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TerminalMetalRenderer.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        XCTAssertTrue(renderer.render(shot.frame, to: target, clearColor: shot.clearColor))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        func inked(rows: Range<Int>) -> Int {
            rows.reduce(0) { count, y in
                count + (0 ..< width).filter { x in pixels[(y * width + x) * 4 ..< (y * width + x) * 4 + 3].contains { $0 > 0 } }.count
            }
        }
        XCTAssertGreaterThan(inked(rows: 0 ..< renderer.cellPixelHeight), 0, "the first row's text and green fill are drawn")
        XCTAssertEqual(inked(rows: renderer.cellPixelHeight * 2 ..< grid.height), 0, "blank rows stay the canvas")
    }

    func testThumbnailIsAReadThatNeverResizesAnswersOrConsumesDamage() throws {
        let surface = makeSurface()
        var resizes = 0
        var input = Data()
        surface.onResize = { _, _ in resizes += 1 }
        surface.onInput = { input.append($0) }
        surface.receive("prompt$ ")
        let gridBefore = surface.testingGridSize
        _ = try thumbnail(of: surface)
        _ = try thumbnail(of: surface)
        XCTAssertEqual(resizes, 0)
        XCTAssertTrue(input.isEmpty)
        XCTAssertEqual(surface.testingGridSize.cols, gridBefore.cols)
        XCTAssertEqual(surface.testingGridSize.rows, gridBefore.rows)

        let emulator = TerminalEmulator(cols: 20, rows: 4)
        emulator.feed(Data("changed".utf8))
        _ = surface.thumbnailStyle.thumbnail(of: emulator)
        XCTAssertTrue(emulator.consumeDamage().rows.contains(0), "the pane's renderer still gets its damage")
    }

    func testFollowingRebuildsOncePerTickAndOnlyForNewOutput() throws {
        let surface = makeSurface()
        let thumbnail = TerminalThumbnailView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        thumbnail.follow(surface)
        XCTAssertEqual(thumbnail.testingBuildCount, 0, "nothing builds outside a window")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView?.addSubview(thumbnail)
        XCTAssertEqual(thumbnail.testingBuildCount, 1, "the first frame draws on arrival")
        thumbnail.tick()
        XCTAssertEqual(thumbnail.testingBuildCount, 1, "no output, no rebuild")

        for line in 0 ..< 50 { surface.receive("line \(line)\r\n") }
        thumbnail.tick()
        thumbnail.tick()
        XCTAssertEqual(thumbnail.testingBuildCount, 2, "a burst of output is one rebuild per tick")

        thumbnail.isHidden = true
        surface.receive("more")
        thumbnail.tick()
        XCTAssertEqual(thumbnail.testingBuildCount, 2, "a hidden thumbnail doesn't build")
        thumbnail.isHidden = false
        thumbnail.removeFromSuperview()
        thumbnail.tick()
        XCTAssertEqual(thumbnail.testingBuildCount, 2, "nor one out of its window")
    }

    func testCaptureShowsTheScreenRowsWithoutACursor() {
        let vt = PaneCapture.render(
            bytes: Data("one\r\ntwo\r\n\u{1b}[1;31mthree\u{1b}[0m\r\nfour".utf8),
            cols: 12, rows: 3, format: "vt", trim: false, unwrap: false
        )
        let shot = TerminalThumbnail(capture: vt, columns: 12, rows: 3, style: makeSurface().thumbnailStyle)
        XCTAssertEqual(shot.frame.columns, 12)
        XCTAssertEqual(shot.frame.rows, 3)
        XCTAssertEqual((0 ..< 3).map { text(shot.frame, row: $0) }, ["two", "three", "four"], "history scrolls off; the screen stays")
        XCTAssertTrue(shot.frame.cell(row: 1, column: 0)?.bold ?? false)
        XCTAssertFalse(shot.frame.cursor.visible)
    }
}
