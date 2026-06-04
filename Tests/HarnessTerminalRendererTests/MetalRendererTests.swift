import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

/// Harness's own offscreen renderer conformance suite: render a known frame to a texture,
/// read pixels/stats back, and assert structural behavior without an external oracle.
///
/// Set `HARNESS_WRITE_RENDER_SNAPSHOTS=1` to dump PNGs to
/// `$TMPDIR/HarnessRenderSnapshots/` for human debugging. CI must rely on the structural
/// assertions here, not pixel-perfect snapshot files.
final class MetalRendererTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!

    private struct RenderedFixture {
        let stats: TerminalRenderStats
        let pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    }

    private func makeRenderer() throws -> (MTLDevice, TerminalMetalRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        let renderer = try makeRenderer(device: device)
        return (device, renderer)
    }

    private func makeRenderer(device: MTLDevice, atlasSize: Int = 1024, atlasMaxPages: Int = 4) throws -> TerminalMetalRenderer {
        // A device exists, so a nil renderer means a real shader/pipeline failure — fail
        // rather than skip so it surfaces.
        return try XCTUnwrap(
            TerminalMetalRenderer(
                device: device,
                fontFamily: "Menlo",
                fontSize: 14,
                scale: 2,
                atlasSize: atlasSize,
                atlasMaxPages: atlasMaxPages
            ),
            "TerminalMetalRenderer failed to build (shader/pipeline error)"
        )
    }

    private func makeAtlas(_ device: MTLDevice, size: Int = 1024, maxPages: Int = 4) throws -> GlyphAtlas {
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        return try XCTUnwrap(
            GlyphAtlas(device: device, rasterizer: rasterizer, size: size, maxPages: maxPages),
            "GlyphAtlas failed to build"
        )
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
        FrameBuilder(theme: theme).build(snapshot(bytes, cols: cols, rows: rows))
    }

    private func snapshot(_ bytes: String, cols: Int, rows: Int) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return term.readGrid()!
    }

    private func backgroundFrame(
        _ colors: [RenderColor],
        codepoints: [UInt32]? = nil,
        foregrounds: [RenderColor]? = nil
    ) -> TerminalFrame {
        let fg = RenderColor(red: 1, green: 1, blue: 1, alpha: 1)
        let cells = colors.enumerated().map { column, color in
            RenderCell(
                row: 0,
                column: column,
                codepoint: codepoints?[column] ?? 0x20,
                foreground: foregrounds?[column] ?? fg,
                background: color,
                underlineColor: foregrounds?[column] ?? fg,
                bold: false,
                italic: false,
                underline: .none,
                strikethrough: false,
                overline: false,
                width: .normal,
                drawBackground: true
            )
        }
        return TerminalFrame(
            columns: colors.count,
            rows: 1,
            cells: cells,
            cursor: CursorRender(
                row: 0,
                column: 0,
                visible: false,
                color: fg,
                textColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1)
            )
        )
    }

    private func renderFixture(
        _ frame: TerminalFrame,
        name: String,
        cols: Int,
        rows: Int,
        device: MTLDevice,
        renderer: TerminalMetalRenderer,
        clearColor: RenderColor = RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
        ligatures: Bool = false
    ) throws -> RenderedFixture {
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        renderer.render(frame, to: target, clearColor: clearColor, ligatures: ligatures)
        writeSnapshotIfRequested(texture: target, width: w, height: h, name: name)
        return RenderedFixture(stats: renderer.stats, pixel: readPixels(target, width: w, height: h))
    }

    func testRendererInitializes() throws {
        let (_, renderer) = try makeRenderer()
        XCTAssertGreaterThan(renderer.cellPixelWidth, 0)
        XCTAssertGreaterThan(renderer.cellPixelHeight, 0)
        let size = renderer.surfacePixelSize(columns: 80, rows: 24)
        XCTAssertEqual(size.width, renderer.cellPixelWidth * 80)
        XCTAssertEqual(size.height, renderer.cellPixelHeight * 24)
    }

    /// Glitchless live resize: a transaction-synchronized present (commit → waitUntilScheduled →
    /// drawable.present) must succeed against a layer in `presentsWithTransaction` mode and record
    /// the bounded schedule wait in the stats; the async path must leave that stat at zero (it's
    /// per-frame, self-clearing via `encode`'s fresh stats).
    func testPresentSynchronizedWithTransactionPresentsAndRecordsSchedule() throws {
        let (device, renderer) = try makeRenderer()
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = TerminalMetalRenderer.pixelFormat
        layer.framebufferOnly = true
        let (w, h) = renderer.surfacePixelSize(columns: 20, rows: 4)
        layer.drawableSize = CGSize(width: w, height: h)
        layer.presentsWithTransaction = true
        guard let drawable = layer.nextDrawable() else { throw XCTSkip("no drawable") }
        let clear = RenderColor(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertTrue(renderer.present(
            frame("sync present", cols: 20, rows: 4),
            to: drawable,
            clearColor: clear,
            synchronizedWithTransaction: true
        ))
        XCTAssertGreaterThan(renderer.stats.presentScheduleNanos, 0)

        layer.presentsWithTransaction = false
        guard let second = layer.nextDrawable() else { throw XCTSkip("no second drawable") }
        XCTAssertTrue(renderer.present(
            frame("async present", cols: 20, rows: 4),
            to: second,
            clearColor: clear
        ))
        XCTAssertEqual(renderer.stats.presentScheduleNanos, 0)
    }

    /// Scroll-delta rotation: rendering frame B (= frame A's window scrolled back one row) with
    /// `scrollShift` must reuse every kept row from the cache (stats) and produce pixels identical
    /// to a from-scratch render of B — pinning both the rotation bookkeeping and the baked-Y
    /// rewrite on every instance type.
    func testScrollShiftRotationMatchesFullRenderReadback() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 10 {
            term.feed("\u{1b}[3\(i % 8)mr\(i)\u{1b}[0m \u{1b}[4mu\(i)\u{1b}[24m \u{1b}[41mB\u{1b}[0m\r\n")
        }
        let builder = FrameBuilder(theme: theme)
        let frameA = builder.build(term.readGrid(scrollbackOffset: 1)!)
        let frameB = builder.build(term.readGrid(scrollbackOffset: 2)!) // = A shifted down 1 row
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        let clear = RenderColor(theme.background)
        // Seed the row cache with frame A (full damage caches every row).
        renderer.render(frameA, to: target, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< rows), full: true))
        // Shifted render of B: rotate the cache, encode only the exposed top row.
        renderer.render(frameB, to: target, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integer: 0)), scrollShift: 1)
        XCTAssertEqual(renderer.stats.encodedRows, 1)
        XCTAssertEqual(renderer.stats.reusedRows, rows - 1)
        let rotated = readPixels(target, width: w, height: h)

        let reference = try makeRenderer(device: device)
        guard let refTarget = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        reference.render(frameB, to: refTarget, clearColor: clear)
        let expected = readPixels(refTarget, width: w, height: h)
        var mismatches = 0
        for y in 0 ..< h {
            for x in 0 ..< w where rotated(x, y) != expected(x, y) {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "rotated render must be pixel-identical to a full render")
    }

    /// Pixel-smooth scrolling, renderer half. Fraction 0 with no clip must be byte-identical to
    /// the pre-uniform pipeline (the at-rest pin); a whole-pixel translate must move every drawn
    /// pixel up by exactly that amount (uniform-only — the instances are untouched); and the
    /// scissor must hold content inside the grid box (the peek row stays hidden at fraction 0).
    func testScrollFractionTranslateAndClipReadback() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 10 {
            term.feed("\u{1b}[3\(i % 8)mf\(i)\u{1b}[0m \u{1b}[4mu\(i)\u{1b}[24m \u{1b}[4\(i % 8)m#\u{1b}[0m\r\n")
        }
        let builder = FrameBuilder(theme: theme)
        let testFrame = builder.build(term.readGrid(scrollbackOffset: 1)!)
        let clear = RenderColor(theme.background)
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)

        // Reference: plain render, no smooth-scroll parameters.
        guard let refTarget = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        renderer.render(testFrame, to: refTarget, clearColor: clear)
        let reference = readPixelBytes(refTarget, width: w, height: h)

        // At-rest pin: explicit fraction 0 / nil clip is byte-identical.
        guard let zeroTarget = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        renderer.render(testFrame, to: zeroTarget, clearColor: clear,
                        scrollFractionPx: 0, smoothScrollClipRows: nil)
        XCTAssertEqual(readPixelBytes(zeroTarget, width: w, height: h), reference,
                       "fraction 0 must be byte-identical to the plain pipeline")

        // Whole-pixel translate: every output row equals the reference row `n` pixels below.
        let n = renderer.cellPixelHeight / 2
        guard let shifted = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        renderer.render(testFrame, to: shifted, clearColor: clear,
                        scrollFractionPx: Float(n), smoothScrollClipRows: rows)
        let translated = readPixelBytes(shifted, width: w, height: h)
        var mismatches = 0
        for y in 0 ..< (h - n) {
            let out = translated[(y * w * 4) ..< ((y + 1) * w * 4)]
            let ref = reference[((y + n) * w * 4) ..< ((y + n + 1) * w * 4)]
            if !out.elementsEqual(ref) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "translated content must match the reference shifted by \(n)px")

        // Clip: with the scissor bounding the first `rows - 1` rows, the last row's box must be
        // pure clear color even though the (untranslated) frame draws content there.
        guard let clipped = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        renderer.render(testFrame, to: clipped, clearColor: clear,
                        scrollFractionPx: 0, smoothScrollClipRows: rows - 1)
        let clippedPixel = readPixels(clipped, width: w, height: h)
        let referencePixel = readPixels(refTarget, width: w, height: h)
        let clearBytes = (UInt8(clear.red * 255), UInt8(clear.green * 255), UInt8(clear.blue * 255))
        // Find a pixel the reference genuinely draws in the last row (e.g. the colored `#` cell),
        // then assert the clip leaves that exact pixel at the clear color.
        let lastRowY = (rows - 1) * renderer.cellPixelHeight + renderer.cellPixelHeight / 2
        var drawnX: Int?
        for x in 0 ..< w {
            let c = referencePixel(x, lastRowY)
            if abs(Int(c.0) - Int(clearBytes.0)) > 8 || abs(Int(c.1) - Int(clearBytes.1)) > 8
                || abs(Int(c.2) - Int(clearBytes.2)) > 8 {
                drawnX = x
                break
            }
        }
        let x = try XCTUnwrap(drawnX, "the reference must draw something in the last row")
        assertColor(clippedPixel(x, lastRowY),
                    r: Int(clear.red * 255), g: Int(clear.green * 255), b: Int(clear.blue * 255),
                    label: "clipped pixel x=\(x)")
    }

    /// Rotation across a shift matrix — positive, negative, and multi-row. Pins the baked-Y
    /// rewrite sign (dy = shift·cellH in BOTH directions), the fall-off end (top rows drop for
    /// negative shifts, bottom for positive), and the exposed band, all at the pixel level —
    /// the count-only stats assertions are sign-symmetric and cannot catch a flipped dy.
    func testScrollShiftRotationMatrixMatchesFullRender() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 16 {
            term.feed("\u{1b}[3\(i % 8)mm\(i)\u{1b}[0m \u{1b}[4mu\(i)\u{1b}[24m \u{1b}[4\(i % 8)m#\u{1b}[0m\r\n")
        }
        let builder = FrameBuilder(theme: theme)
        let clear = RenderColor(theme.background)
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        let baseOffset = 5
        for shift in [1, 3, -1, -2] {
            let seed = builder.build(term.readGrid(scrollbackOffset: baseOffset)!)
            let target = builder.build(term.readGrid(scrollbackOffset: baseOffset + shift)!)
            guard let texture = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
            renderer.render(seed, to: texture, clearColor: clear,
                            damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< rows), full: true))
            let exposed = shift > 0
                ? IndexSet(integersIn: 0 ..< shift)
                : IndexSet(integersIn: (rows + shift) ..< rows)
            renderer.render(target, to: texture, clearColor: clear,
                            damage: TerminalDamage(rows: exposed), scrollShift: shift)
            XCTAssertEqual(renderer.stats.encodedRows, abs(shift), "shift \(shift)")
            XCTAssertEqual(renderer.stats.reusedRows, rows - abs(shift), "shift \(shift)")
            let rotated = readPixels(texture, width: w, height: h)

            let reference = try makeRenderer(device: device)
            guard let refTexture = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
            reference.render(target, to: refTexture, clearColor: clear)
            let expected = readPixels(refTexture, width: w, height: h)
            var mismatches = 0
            for y in 0 ..< h {
                for x in 0 ..< w where rotated(x, y) != expected(x, y) {
                    mismatches += 1
                }
            }
            XCTAssertEqual(mismatches, 0, "shift \(shift) must be pixel-identical to a full render")
        }
    }

    /// A deliberately WRONG exposed band with the correct scrollShift must still render perfectly:
    /// rotation nils the truly-exposed slots, and the nil-slot fallback re-encodes them from the
    /// (always-correct) frame regardless of what the damage band claims. This documents that the
    /// nil slots — not the caller's band — are the correctness guarantor.
    func testScrollShiftSurvivesWrongDamageBand() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 10 { term.feed("wrongband \(i)\r\n") }
        let builder = FrameBuilder(theme: theme)
        let clear = RenderColor(theme.background)
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        guard let texture = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        let seed = builder.build(term.readGrid(scrollbackOffset: 1)!)
        let target = builder.build(term.readGrid(scrollbackOffset: 2)!)
        renderer.render(seed, to: texture, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< rows), full: true))
        // Exposed row is 0 (shift +1); claim row 2 instead.
        renderer.render(target, to: texture, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integer: 2)), scrollShift: 1)
        let rotated = readPixels(texture, width: w, height: h)
        let reference = try makeRenderer(device: device)
        guard let refTexture = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        reference.render(target, to: refTexture, clearColor: clear)
        let expected = readPixels(refTexture, width: w, height: h)
        var mismatches = 0
        for y in 0 ..< h {
            for x in 0 ..< w where rotated(x, y) != expected(x, y) {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    /// Drop-recovery contract: when a present fails, the view calls `invalidateRowReuseCache()`
    /// because its frame bookkeeping advanced while the glass (and possibly the cache) did not —
    /// the next "nothing changed" frame must re-encode from frame content rather than reuse rows
    /// that disagree with the screen. Pinned here deterministically since real drops are
    /// drawable-starvation races.
    func testInvalidateRowReuseCacheForcesFullReencode() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let frameA = frame("alpha", cols: cols, rows: rows)
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        guard let texture = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        let clear = RenderColor(theme.background)
        renderer.render(frameA, to: texture, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< rows), full: true))
        // Baseline: a quiet frame reuses every cached row.
        renderer.render(frameA, to: texture, clearColor: clear, damage: TerminalDamage())
        XCTAssertEqual(renderer.stats.encodedRows, 0)
        XCTAssertEqual(renderer.stats.reusedRows, rows)
        // After a drop the view invalidates; the same quiet frame must now re-encode everything.
        renderer.invalidateRowReuseCache()
        renderer.render(frameA, to: texture, clearColor: clear, damage: TerminalDamage())
        XCTAssertEqual(renderer.stats.encodedRows, rows)
        XCTAssertEqual(renderer.stats.reusedRows, 0)
    }

    /// Live→scrolled with a visible block cursor: the cursor's row carries an inverted glyph in
    /// the cache, and after the shift it must re-encode at its SHIFTED slot (the cached cursor key
    /// rotates with the content) — otherwise the stale inversion rides along one row down.
    func testScrollShiftReencodesShiftedCursorRow() throws {
        let (device, renderer) = try makeRenderer()
        let cols = 12, rows = 4
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 10 { term.feed("cursor\(i)\r\n") }
        term.feed("\u{1b}[2;5H") // park the cursor mid-screen so its row survives the shift
        let builder = FrameBuilder(theme: theme)
        let live = builder.build(term.readGrid()!) // visible block cursor on viewport row 1
        XCTAssertTrue(live.cursor.visible)
        XCTAssertEqual(live.cursor.row, 1)
        let scrolled = builder.build(term.readGrid(scrollbackOffset: 1)!) // cursor hidden
        XCTAssertFalse(scrolled.cursor.visible)
        let (w, h) = renderer.surfacePixelSize(columns: cols, rows: rows)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        let clear = RenderColor(theme.background)
        renderer.render(live, to: target, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< rows), full: true))
        renderer.render(scrolled, to: target, clearColor: clear,
                        damage: TerminalDamage(rows: IndexSet(integer: 0)), scrollShift: 1)
        let rotated = readPixels(target, width: w, height: h)

        let reference = try makeRenderer(device: device)
        guard let refTarget = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }
        reference.render(scrolled, to: refTarget, clearColor: clear)
        let expected = readPixels(refTarget, width: w, height: h)
        var mismatches = 0
        for y in 0 ..< h {
            for x in 0 ..< w where rotated(x, y) != expected(x, y) {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "shifted cursor row must re-encode without the stale inversion")
    }

    func testRenderStatsDistinguishNonEmptyAndDefaultCanvasFrames() throws {
        let (device, renderer) = try makeRenderer()
        let nonEmpty = frame("\u{1b}[?25l\u{1b}[48;2;255;0;0mA", cols: 1, rows: 1)
        var size = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let nonEmptyTarget = makeTarget(device, width: size.width, height: size.height) else {
            throw XCTSkip("no texture")
        }

        renderer.render(nonEmpty, to: nonEmptyTarget, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let nonEmptyStats = renderer.stats
        XCTAssertGreaterThan(nonEmptyStats.cells, 0)
        XCTAssertGreaterThan(nonEmptyStats.glyphInstances, 0)
        XCTAssertGreaterThan(nonEmptyStats.bgInstances, 0)
        XCTAssertEqual(nonEmptyStats.bgSpans, nonEmptyStats.bgInstances)
        XCTAssertEqual(nonEmptyStats.bgCells, 1)
        XCTAssertEqual(nonEmptyStats.atlasPages, 1)
        XCTAssertGreaterThan(nonEmptyStats.encodeNanos, 0)

        let blank = frame("\u{1b}[?25l", cols: 2, rows: 1)
        size = renderer.surfacePixelSize(columns: 2, rows: 1)
        guard let blankTarget = makeTarget(device, width: size.width, height: size.height) else {
            throw XCTSkip("no texture")
        }

        renderer.render(blank, to: blankTarget, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let blankStats = renderer.stats
        XCTAssertGreaterThan(blankStats.cells, 0)
        XCTAssertEqual(blankStats.bgInstances, 0)
        XCTAssertEqual(blankStats.bgCells, 0)
        XCTAssertEqual(blankStats.glyphInstances, 0)
        XCTAssertNotEqual(nonEmptyStats.bgInstances, blankStats.bgInstances)
        XCTAssertNotEqual(nonEmptyStats.glyphInstances, blankStats.glyphInstances)
    }

    func testRendererDamageReusesCleanRowsWithoutChangingReadback() throws {
        let (device, renderer) = try makeRenderer()
        let initial = frame("\u{1b}[?25lAAAA\r\nBBBB\r\nCCCC", cols: 4, rows: 3)
        let changed = frame("\u{1b}[?25lAAAA\r\nBXBB\r\nCCCC", cols: 4, rows: 3)
        let size = renderer.surfacePixelSize(columns: 4, rows: 3)
        guard let incrementalTarget = makeTarget(device, width: size.width, height: size.height),
              let fullTarget = makeTarget(device, width: size.width, height: size.height)
        else { throw XCTSkip("no texture") }

        renderer.render(
            initial,
            to: incrementalTarget,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< 3), full: true)
        )
        XCTAssertEqual(renderer.stats.encodedRows, 3)
        XCTAssertEqual(renderer.stats.reusedRows, 0)

        renderer.render(
            changed,
            to: incrementalTarget,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: IndexSet(integer: 1), full: false)
        )
        let incrementalStats = renderer.stats
        XCTAssertEqual(incrementalStats.encodedRows, 1)
        XCTAssertEqual(incrementalStats.reusedRows, 2)
        XCTAssertGreaterThan(incrementalStats.instanceUploadBytes, 0)

        renderer.render(
            changed,
            to: incrementalTarget,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: [], full: false)
        )
        XCTAssertEqual(renderer.stats.encodedRows, 0)
        XCTAssertEqual(renderer.stats.reusedRows, 3)
        XCTAssertGreaterThan(renderer.stats.instanceUploadBytes, 0, "first stable frame primes immutable upload buffers")

        renderer.render(
            changed,
            to: incrementalTarget,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: [], full: false)
        )
        XCTAssertEqual(renderer.stats.encodedRows, 0)
        XCTAssertEqual(renderer.stats.reusedRows, 3)
        XCTAssertEqual(renderer.stats.instanceUploadBytes, 0)

        let reference = try makeRenderer(device: device)
        reference.render(changed, to: fullTarget, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(
            readPixelBytes(incrementalTarget, width: size.width, height: size.height),
            readPixelBytes(fullTarget, width: size.width, height: size.height)
        )
    }

    func testRendererDamageRebuildsBlockCursorGlyphRowWhenBlinking() throws {
        let (device, renderer) = try makeRenderer()
        var visible = frame("A", cols: 1, rows: 1)
        visible.cursor.visible = true
        visible.cursor.style = .block
        var hidden = visible
        hidden.cursor.visible = false
        let size = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: size.width, height: size.height) else {
            throw XCTSkip("no texture")
        }

        renderer.render(
            visible,
            to: target,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< 1), full: true)
        )
        renderer.render(
            hidden,
            to: target,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            damage: TerminalDamage(rows: [], full: false)
        )

        XCTAssertEqual(renderer.stats.encodedRows, 1, "cursor blink invalidates the glyph row")
        XCTAssertEqual(renderer.stats.reusedRows, 0)
    }

    func testRendererDamageDoesNotReuseStableBuffersForInvalidFrameShape() throws {
        let (device, renderer) = try makeRenderer()
        let red = RenderColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = RenderColor(red: 0, green: 1, blue: 0, alpha: 1)
        let valid = backgroundFrame(Array(repeating: red, count: 4))
        let size = renderer.surfacePixelSize(columns: 4, rows: 1)
        guard let target = makeTarget(device, width: size.width, height: size.height) else {
            throw XCTSkip("no texture")
        }

        renderer.render(
            valid,
            to: target,
            clearColor: green,
            damage: TerminalDamage(rows: IndexSet(integer: 0), full: true)
        )
        renderer.render(valid, to: target, clearColor: green, damage: TerminalDamage(rows: [], full: false))
        renderer.render(valid, to: target, clearColor: green, damage: TerminalDamage(rows: [], full: false))
        XCTAssertEqual(renderer.stats.instanceUploadBytes, 0)

        let invalid = TerminalFrame(columns: 4, rows: 1, cells: [], cursor: valid.cursor)
        renderer.render(invalid, to: target, clearColor: green, damage: TerminalDamage(rows: [], full: false))
        XCTAssertEqual(renderer.stats.bgInstances, 0)
        XCTAssertEqual(renderer.stats.glyphInstances, 0)

        let px = readPixels(target, width: size.width, height: size.height)
        assertColor(
            px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
            r: 0,
            g: 255,
            b: 0,
            label: "invalid frame clears instead of reusing stale stable buffers"
        )
    }

    func testGlyphAtlasStatsTrackMissThenHit() throws {
        let (device, _) = try makeRenderer()
        let atlas = try makeAtlas(device)
        let key = GlyphKey(codepoint: UInt32(UnicodeScalar("A").value), bold: false, italic: false)

        XCTAssertEqual(atlas.stats.hits, 0)
        XCTAssertEqual(atlas.stats.misses, 0)
        let first = try XCTUnwrap(atlas.entry(for: key))
        XCTAssertEqual(first.pageIndex, 0)
        XCTAssertEqual(atlas.stats.entries, 1)
        XCTAssertEqual(atlas.stats.misses, 1)
        XCTAssertEqual(atlas.stats.hits, 0)

        let second = try XCTUnwrap(atlas.entry(for: key))
        XCTAssertEqual(second.pageIndex, 0)
        XCTAssertEqual(atlas.stats.entries, 1)
        XCTAssertEqual(atlas.stats.misses, 1)
        XCTAssertEqual(atlas.stats.hits, 1)
        XCTAssertEqual(atlas.stats.pages, 1)
    }

    func testGlyphAtlasSinglePageEntriesUsePageZero() throws {
        let (device, _) = try makeRenderer()
        let atlas = try makeAtlas(device)

        for scalar in "Harness".unicodeScalars {
            let entry = try XCTUnwrap(atlas.entry(for: GlyphKey(codepoint: scalar.value, bold: false, italic: false)))
            XCTAssertEqual(entry.pageIndex, 0)
        }

        XCTAssertEqual(atlas.stats.pages, 1)
        XCTAssertEqual(atlas.stats.resets, 0)
    }

    func testGlyphAtlasGrowsPagesWithoutReset() throws {
        let (device, _) = try makeRenderer()
        let atlas = try makeAtlas(device, size: 48, maxPages: 2)
        var seenPages = Set<Int>()

        for scalar in atlasPressureScalars() {
            guard let entry = atlas.entry(for: GlyphKey(codepoint: scalar.value, bold: false, italic: false)) else {
                continue
            }
            seenPages.insert(entry.pageIndex)
            if seenPages.contains(0), seenPages.contains(1) { break }
        }

        XCTAssertEqual(seenPages, [0, 1])
        XCTAssertEqual(atlas.stats.pages, 2)
        XCTAssertEqual(atlas.stats.resets, 0)
    }

    func testMultiPageAtlasGlyphsRenderFromBothPages() throws {
        let (device, _) = try makeRenderer()
        let probe = try multiPageProbeText(device: device, atlasSize: 48, atlasMaxPages: 2)
        let renderer = try makeRenderer(device: device, atlasSize: 48, atlasMaxPages: 2)
        let f = frame("\u{1b}[?25l\(probe.text)", cols: probe.text.count, rows: 1)
        let rendered = try renderFixture(f, name: "glyph_atlas_multi_page", cols: probe.text.count, rows: 1,
                                         device: device, renderer: renderer)

        XCTAssertEqual(renderer.glyphAtlasStats.pages, 2)
        XCTAssertEqual(renderer.glyphAtlasStats.resets, 0)
        assertCellContainsInk(rendered, renderer: renderer, column: probe.pageZeroColumn, label: "page 0 glyph")
        assertCellContainsInk(rendered, renderer: renderer, column: probe.pageOneColumn, label: "page 1 glyph")
    }

    func testGlyphAtlasOverflowAllPagesResetsAndHeals() throws {
        let (device, _) = try makeRenderer()
        let atlas = try makeAtlas(device, size: 48, maxPages: 1)
        var healedEntry: AtlasEntry?

        for scalar in atlasPressureScalars() {
            healedEntry = atlas.entry(for: GlyphKey(codepoint: scalar.value, bold: false, italic: false))
            if atlas.stats.resets > 0, healedEntry != nil { break }
        }

        let entry = try XCTUnwrap(healedEntry, "expected a glyph to render after max-page reset")
        XCTAssertEqual(entry.pageIndex, 0)
        XCTAssertEqual(atlas.stats.pages, 1)
        XCTAssertGreaterThan(atlas.stats.resets, 0)
    }

    func testLigatedRunsUseShapedRunCacheAcrossFrames() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25loffice => != ->", cols: 18, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 18, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1), ligatures: true)
        let afterFirst = renderer.glyphAtlasStats
        XCTAssertGreaterThan(afterFirst.shapedRunEntries, 0)
        XCTAssertGreaterThan(afterFirst.shapedRunCacheMisses, 0)
        XCTAssertEqual(afterFirst.shapedRunCacheHits, 0)
        XCTAssertGreaterThan(renderer.stats.glyphInstances, 0)

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1), ligatures: true)
        let afterSecond = renderer.glyphAtlasStats
        XCTAssertEqual(afterSecond.shapedRunEntries, afterFirst.shapedRunEntries)
        XCTAssertEqual(afterSecond.shapedRunCacheMisses, afterFirst.shapedRunCacheMisses)
        XCTAssertGreaterThan(afterSecond.shapedRunCacheHits, afterFirst.shapedRunCacheHits)
    }

    func testProceduralBoxAndBlockCellsDoNotEnterShapedRunCache() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l\u{2500}\u{2588}", cols: 2, rows: 1)
        let rendered = try renderFixture(f, name: "procedural_no_shaped_run_cache", cols: 2, rows: 1,
                                         device: device, renderer: renderer, ligatures: true)

        XCTAssertGreaterThan(rendered.stats.glyphInstances, 0, "box drawing still emits its procedural sprite")
        XCTAssertGreaterThan(rendered.stats.bgInstances, 0, "block element still emits its procedural fill")
        XCTAssertEqual(renderer.glyphAtlasStats.shapedRunEntries, 0)
        XCTAssertEqual(renderer.glyphAtlasStats.shapedRunCacheHits, 0)
        XCTAssertEqual(renderer.glyphAtlasStats.shapedRunCacheMisses, 0)
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

    func testUniformBackgroundRowCoalescesWithoutChangingReadback() throws {
        let (device, renderer) = try makeRenderer()
        let red = RenderColor(red: 1, green: 0, blue: 0, alpha: 1)
        // Alpha > 1 clamps to the same rgba8Unorm byte, but the color value is unequal, so
        // this reference frame exercises the old one-instance-per-cell shape.
        let equivalentRed = RenderColor(red: 1, green: 0, blue: 0, alpha: 1.0001)
        let coalesced = backgroundFrame(Array(repeating: red, count: 8))
        let unmergedEquivalent = backgroundFrame((0 ..< 8).map { $0.isMultiple(of: 2) ? red : equivalentRed })
        let (w, h) = renderer.surfacePixelSize(columns: 8, rows: 1)
        guard let coalescedTarget = makeTarget(device, width: w, height: h),
              let unmergedTarget = makeTarget(device, width: w, height: h)
        else { throw XCTSkip("no texture") }

        renderer.render(coalesced, to: coalescedTarget, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let coalescedStats = renderer.stats
        let coalescedBytes = readPixelBytes(coalescedTarget, width: w, height: h)

        renderer.render(unmergedEquivalent, to: unmergedTarget, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let unmergedStats = renderer.stats
        let unmergedBytes = readPixelBytes(unmergedTarget, width: w, height: h)

        XCTAssertEqual(coalescedBytes, unmergedBytes)
        XCTAssertEqual(coalescedStats.bgCells, 8)
        XCTAssertEqual(coalescedStats.bgSpans, 1)
        XCTAssertEqual(coalescedStats.bgInstances, 1)
        XCTAssertEqual(unmergedStats.bgCells, 8)
        XCTAssertEqual(unmergedStats.bgSpans, 8)
        XCTAssertEqual(unmergedStats.bgInstances, 8)
    }

    func testBackgroundSpanStatsFollowColorRuns() throws {
        let (device, renderer) = try makeRenderer()
        let red = RenderColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = RenderColor(red: 0, green: 0, blue: 1, alpha: 1)
        let f = backgroundFrame([red, red, blue, blue, red])
        let rendered = try renderFixture(f, name: "background_runs", cols: 5, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgCells, 5)
        XCTAssertEqual(rendered.stats.bgSpans, 3)
        XCTAssertEqual(rendered.stats.bgInstances, 3)
    }

    func testBackgroundSpanBreaksBeforeBlockElementFill() throws {
        let (device, renderer) = try makeRenderer()
        let red = RenderColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = RenderColor(red: 0, green: 1, blue: 0, alpha: 1)
        let f = backgroundFrame(
            [red, red, red],
            codepoints: [0x20, 0x2588, 0x20],
            foregrounds: [green, green, green]
        )
        let rendered = try renderFixture(f, name: "background_block_break", cols: 3, rows: 1,
                                         device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgCells, 3)
        XCTAssertEqual(rendered.stats.bgSpans, 3)
        XCTAssertEqual(rendered.stats.bgInstances, 4, "block fill remains a separate background-pass instance")
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 255, g: 0, b: 0, label: "left red background")
        assertColor(rendered.pixel(renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 0, g: 255, b: 0, label: "block fill stays on top")
        assertColor(rendered.pixel(2 * renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 255, g: 0, b: 0, label: "right red background")
    }

    func testPureRedBackgroundReadbackIsIdentity() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l\u{1b}[48;2;255;0;0m ", cols: 1, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
        let px = readPixels(target, width: w, height: h)
        let center = px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2)

        XCTAssertEqual(center.0, 255)
        XCTAssertEqual(center.1, 0)
        XCTAssertEqual(center.2, 0)
        XCTAssertEqual(center.3, 255)
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
        XCTAssertEqual(renderer.stats.imageInstances, 1)
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
        XCTAssertEqual(renderer.stats.bgInstances, 1, "prompt gutter emits one background-pass instance")
        XCTAssertEqual(renderer.stats.bgSpans, 0, "prompt gutter does not count as a cell background span")

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

    func testTranslucentCanvasClearIsPremultipliedForLayerCompositing() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l", cols: 1, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        renderer.render(f, to: target, clearColor: RenderColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        let px = readPixels(target, width: w, height: h)
        let center = px(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2)

        XCTAssertLessThanOrEqual(abs(Int(center.0) - 128), 1, "red channel is premultiplied by alpha")
        XCTAssertEqual(center.1, 0)
        XCTAssertEqual(center.2, 0)
        XCTAssertLessThanOrEqual(abs(Int(center.3) - 128), 1, "alpha channel is preserved")
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

    func testRepeatedRendersReuseInstanceBuffersWithoutCorruption() throws {
        let (device, renderer) = try makeRenderer()
        // Background + glyph + decoration all present so every reused ring buffer is exercised:
        // red bg, green underlined "A". Cursor hidden so it can't repaint the cell.
        let f = frame("\u{1b}[?25l\u{1b}[48;2;255;0;0m\u{1b}[38;2;0;255;0m\u{1b}[4mA", cols: 1, rows: 1)
        let (w, h) = renderer.surfacePixelSize(columns: 1, rows: 1)
        guard let target = makeTarget(device, width: w, height: h) else { throw XCTSkip("no texture") }

        // Render the same frame more times than the ring is deep (3) so slots wrap and are
        // overwritten while prior frames may still be referenced — output must stay identical.
        var samples: [(UInt8, UInt8, UInt8, UInt8)] = []
        for _ in 0 ..< 6 {
            renderer.render(f, to: target, clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1))
            let px = readPixels(target, width: w, height: h)
            // Top-left corner sits outside the glyph: pure red background, a stable witness.
            samples.append(px(1, 1))
        }
        for (i, s) in samples.enumerated() {
            assertColor(s, r: 255, g: 0, b: 0, label: "reused-buffer frame \(i) red bg", tolerance: 24)
        }
    }

    // MARK: - Harness-owned renderer guardrails

    func testHarnessRendererFixtureDefaultTextReportsPlausibleGlyphStats() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25lABC", cols: 5, rows: 1)
        let rendered = try renderFixture(f, name: "default_text", cols: 5, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.cells, 5)
        XCTAssertEqual(rendered.stats.bgInstances, 0, "default-canvas cells rely on the clear color")
        XCTAssertEqual(rendered.stats.bgCells, 0)
        XCTAssertEqual(rendered.stats.glyphInstances, 3)
        XCTAssertEqual(rendered.stats.decoInstances, 0)
        XCTAssertGreaterThan(rendered.stats.encodeNanos, 0)
    }

    func testHarnessRendererFixtureANSIColorBackgroundsFill() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l\u{1b}[41m \u{1b}[42m ", cols: 2, rows: 1)
        let rendered = try renderFixture(f, name: "ansi_backgrounds", cols: 2, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgCells, 2)
        XCTAssertEqual(rendered.stats.bgSpans, 2)
        XCTAssertEqual(rendered.stats.bgInstances, 2)
        let red = theme.palette[1]
        let green = theme.palette[2]
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(red.red), g: Int(red.green), b: Int(red.blue),
                    label: "ANSI red background", tolerance: 24)
        assertColor(rendered.pixel(renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(green.red), g: Int(green.green), b: Int(green.blue),
                    label: "ANSI green background", tolerance: 24)
    }

    func testHarnessRendererFixtureTruecolorGradientFillsEveryCell() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame(
            "\u{1b}[?25l\u{1b}[48;2;0;0;0m \u{1b}[48;2;85;0;0m \u{1b}[48;2;170;0;0m \u{1b}[48;2;255;0;0m ",
            cols: 4,
            rows: 1
        )
        let rendered = try renderFixture(f, name: "truecolor_gradient", cols: 4, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgCells, 4)
        XCTAssertEqual(rendered.stats.bgSpans, 4)
        XCTAssertEqual(rendered.stats.bgInstances, 4)
        for (column, red) in [0, 85, 170, 255].enumerated() {
            assertColor(
                rendered.pixel(column * renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                r: red, g: 0, b: 0, label: "truecolor gradient column \(column)", tolerance: 10
            )
        }
    }

    func testHarnessRendererFixtureSelectionAndSearchHighlightsFill() throws {
        let (device, renderer) = try makeRenderer()
        let grid = snapshot("\u{1b}[?25l    ", cols: 4, rows: 1)
        let selection = HarnessTheme.RGBColor(red: 10, green: 20, blue: 30)
        let search = HarnessTheme.RGBColor(red: 40, green: 50, blue: 60)
        let builder = FrameBuilder(
            theme: theme,
            selectionBackground: selection,
            searchBackground: search
        )
        let f = builder.build(
            grid,
            region: SelectionRegion.linear(TerminalSelection((0, 0), (0, 1))),
            searchHighlights: [TerminalSelection((0, 2), (0, 3))]
        )
        let rendered = try renderFixture(f, name: "selection_search", cols: 4, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgCells, 4)
        XCTAssertEqual(rendered.stats.bgSpans, 2)
        XCTAssertEqual(rendered.stats.bgInstances, 2)
        XCTAssertEqual(rendered.stats.glyphInstances, 0)
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(selection.red), g: Int(selection.green), b: Int(selection.blue),
                    label: "selection fill", tolerance: 10)
        assertColor(rendered.pixel(2 * renderer.cellPixelWidth + renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(search.red), g: Int(search.green), b: Int(search.blue),
                    label: "search fill", tolerance: 10)
    }

    func testHarnessRendererFixtureUnderlineStylesStrikeAndOverlineEmitDecorations() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame(
            "\u{1b}[?25l\u{1b}[4mA\u{1b}[4:3mB\u{1b}[4:4mC\u{1b}[4:5mD\u{1b}[24m\u{1b}[9mS\u{1b}[29m\u{1b}[53mO",
            cols: 6,
            rows: 1
        )
        let rendered = try renderFixture(f, name: "decorations", cols: 6, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.glyphInstances, 6)
        XCTAssertEqual(rendered.stats.decoInstances, 6)
    }

    func testHarnessRendererFixtureBlockElementsAreProceduralFills() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l\u{1b}[38;2;0;255;0m\u{2580}", cols: 1, rows: 1)
        let rendered = try renderFixture(f, name: "block_element", cols: 1, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.glyphInstances, 0, "block elements must not come from the font atlas")
        XCTAssertEqual(rendered.stats.bgInstances, 1)
        XCTAssertEqual(rendered.stats.bgSpans, 0)
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 4),
                    r: 0, g: 255, b: 0, label: "upper-half block fill", tolerance: 24)
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight * 3 / 4),
                    r: 0, g: 0, b: 0, label: "lower half stays clear", tolerance: 8)
    }

    func testHarnessRendererFixtureBoxDrawingUsesProceduralSpritePath() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l\u{1b}[38;2;0;255;255m\u{2500}", cols: 1, rows: 1)
        let rendered = try renderFixture(f, name: "box_drawing", cols: 1, rows: 1, device: device, renderer: renderer)

        XCTAssertEqual(rendered.stats.bgInstances, 0)
        XCTAssertEqual(rendered.stats.glyphInstances, 1)
        assertColor(rendered.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 0, g: 255, b: 255, label: "box drawing center stroke", tolerance: 48)
    }

    func testHarnessRendererFixtureCursorStylesPreserveFillGeometry() throws {
        let (device, renderer) = try makeRenderer()
        let grid = snapshot("", cols: 1, rows: 1)
        let clear = RenderColor(red: 0, green: 0, blue: 0, alpha: 1)
        let cursor = theme.cursor ?? theme.foreground

        let block = FrameBuilder(theme: theme, cursorStyle: .block).build(grid)
        let blockOut = try renderFixture(block, name: "cursor_block", cols: 1, rows: 1,
                                         device: device, renderer: renderer, clearColor: clear)
        XCTAssertEqual(blockOut.stats.bgInstances, 1)
        XCTAssertEqual(blockOut.stats.bgSpans, 0)
        assertColor(blockOut.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: Int(cursor.red), g: Int(cursor.green), b: Int(cursor.blue),
                    label: "block cursor center", tolerance: 24)

        let bar = FrameBuilder(theme: theme, cursorStyle: .bar).build(grid)
        let barOut = try renderFixture(bar, name: "cursor_bar", cols: 1, rows: 1,
                                       device: device, renderer: renderer, clearColor: clear)
        XCTAssertEqual(barOut.stats.bgInstances, 1)
        XCTAssertEqual(barOut.stats.bgSpans, 0)
        assertColor(barOut.pixel(0, renderer.cellPixelHeight / 2),
                    r: Int(cursor.red), g: Int(cursor.green), b: Int(cursor.blue),
                    label: "bar cursor left edge", tolerance: 24)
        assertColor(barOut.pixel(1, renderer.cellPixelHeight / 2),
                    r: 0, g: 0, b: 0, label: "bar cursor second pixel stays clear", tolerance: 8)
        assertColor(barOut.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight / 2),
                    r: 0, g: 0, b: 0, label: "bar cursor center stays clear", tolerance: 8)

        let underline = FrameBuilder(theme: theme, cursorStyle: .underline).build(grid)
        let underlineOut = try renderFixture(underline, name: "cursor_underline", cols: 1, rows: 1,
                                             device: device, renderer: renderer, clearColor: clear)
        XCTAssertEqual(underlineOut.stats.bgInstances, 1)
        XCTAssertEqual(underlineOut.stats.bgSpans, 0)
        assertColor(underlineOut.pixel(renderer.cellPixelWidth / 2, renderer.cellPixelHeight - 1),
                    r: Int(cursor.red), g: Int(cursor.green), b: Int(cursor.blue),
                    label: "underline cursor bottom edge", tolerance: 24)
        assertColor(underlineOut.pixel(renderer.cellPixelWidth / 2, 1),
                    r: 0, g: 0, b: 0, label: "underline cursor top stays clear", tolerance: 8)
    }

    func testHarnessRendererFixtureLigatureShapingPathReportsPlausibleGlyphs() throws {
        let (device, renderer) = try makeRenderer()
        let f = frame("\u{1b}[?25l=>!=", cols: 4, rows: 1)
        let rendered = try renderFixture(f, name: "ligature_path", cols: 4, rows: 1,
                                         device: device, renderer: renderer, ligatures: true)

        XCTAssertGreaterThan(rendered.stats.glyphInstances, 0)
        XCTAssertLessThanOrEqual(rendered.stats.glyphInstances, 4)
        XCTAssertEqual(rendered.stats.bgInstances, 0)
    }

    // MARK: - Atlas test helpers

    private func atlasPressureScalars() -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        for value in 0x21 ... 0x7E {
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        for value in 0xA1 ... 0xFF {
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return scalars
    }

    private func multiPageProbeText(
        device: MTLDevice,
        atlasSize: Int,
        atlasMaxPages: Int
    ) throws -> (text: String, pageZeroColumn: Int, pageOneColumn: Int) {
        let atlas = try makeAtlas(device, size: atlasSize, maxPages: atlasMaxPages)
        var scalars = String.UnicodeScalarView()
        var pageZeroColumn: Int?
        var pageOneColumn: Int?

        for scalar in atlasPressureScalars() {
            guard let entry = atlas.entry(for: GlyphKey(codepoint: scalar.value, bold: false, italic: false)) else {
                continue
            }
            let column = scalars.count
            scalars.append(scalar)
            if entry.pageIndex == 0, pageZeroColumn == nil {
                pageZeroColumn = column
            } else if entry.pageIndex == 1, pageOneColumn == nil {
                pageOneColumn = column
                break
            }
        }

        XCTAssertEqual(atlas.stats.resets, 0)
        return (
            String(scalars),
            try XCTUnwrap(pageZeroColumn, "expected at least one glyph on page 0"),
            try XCTUnwrap(pageOneColumn, "expected atlas pressure text to spill onto page 1")
        )
    }

    // MARK: - Pixel helpers

    private func readPixelBytes(_ texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    private func readPixels(_ texture: MTLTexture, width: Int, height: Int) -> (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let bytes = readPixelBytes(texture, width: width, height: height)
        return { x, y in
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    private func writeSnapshotIfRequested(texture: MTLTexture, width: Int, height: Int, name: String) {
        guard ProcessInfo.processInfo.environment["HARNESS_WRITE_RENDER_SNAPSHOTS"] == "1" else { return }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HarnessRenderSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func assertColor(_ c: (UInt8, UInt8, UInt8, UInt8), r: Int, g: Int, b: Int, label: String, tolerance: Int = 8) {
        XCTAssertLessThanOrEqual(abs(Int(c.0) - r), tolerance, "\(label) red (\(c.0) vs \(r))")
        XCTAssertLessThanOrEqual(abs(Int(c.1) - g), tolerance, "\(label) green (\(c.1) vs \(g))")
        XCTAssertLessThanOrEqual(abs(Int(c.2) - b), tolerance, "\(label) blue (\(c.2) vs \(b))")
    }

    private func assertCellContainsInk(
        _ rendered: RenderedFixture,
        renderer: TerminalMetalRenderer,
        column: Int,
        row: Int = 0,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let startX = column * renderer.cellPixelWidth
        let startY = row * renderer.cellPixelHeight
        for y in startY ..< startY + renderer.cellPixelHeight {
            for x in startX ..< startX + renderer.cellPixelWidth {
                let pixel = rendered.pixel(x, y)
                if Int(pixel.0) + Int(pixel.1) + Int(pixel.2) > 32 {
                    return
                }
            }
        }
        XCTFail("\(label) cell did not contain rendered glyph ink", file: file, line: line)
    }
}
