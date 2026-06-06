import AppKit
import Metal
import XCTest
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme
@testable import HarnessTerminalKit

// XCTest pulls in ApplicationServices, whose QuickDraw `RGBColor` shadows ours.
private typealias RGBColor = HarnessTheme.RGBColor

/// The cell-overlay pass: selection / find / IME preedit shade a copy of the clean cached frame
/// instead of forcing a full rebuild, and the render damage gains exactly the rows whose overlay
/// fingerprint changed — so a selection drag re-encodes the rows it crossed, not the grid.
@MainActor
final class CellOverlayTests: XCTestCase {
    // MARK: - Fingerprints (pure)

    private func keys(
        selection: SelectionRegion? = nil,
        findHits: [TerminalSelection] = [],
        preedit: String = "",
        preeditCursor: (row: Int, column: Int) = (0, 0),
        rows: Int = 24, cols: Int = 80
    ) -> [Int: UInt64] {
        HarnessTerminalSurfaceView.overlayRowKeys(
            selection: selection, findHits: findHits, preedit: preedit,
            preeditCursor: preeditCursor, rows: rows, cols: cols
        )
    }

    /// The damage rule: rows whose fingerprint changed plus rows that left the overlay.
    private func changedRows(_ old: [Int: UInt64], _ new: [Int: UInt64]) -> IndexSet {
        var changed = IndexSet()
        for (row, key) in new where old[row] != key { changed.insert(row) }
        for row in old.keys where new[row] == nil { changed.insert(row) }
        return changed
    }

    func testNoOverlaysYieldNoKeys() {
        XCTAssertTrue(keys().isEmpty)
    }

    func testVerticalDragChangesOnlyTheCrossedRows() {
        // Head moves (3,8) -> (4,8): row 3's extent grows to the full row (it stops being the
        // end row) and row 4 joins — nothing else may re-encode.
        let before = keys(selection: .linear(TerminalSelection((1, 2), (3, 8))))
        let after = keys(selection: .linear(TerminalSelection((1, 2), (4, 8))))
        XCTAssertEqual(changedRows(before, after), IndexSet([3, 4]))
    }

    func testHorizontalDragChangesOnlyTheEndRow() {
        let before = keys(selection: .linear(TerminalSelection((1, 2), (3, 8))))
        let after = keys(selection: .linear(TerminalSelection((1, 2), (3, 12))))
        XCTAssertEqual(changedRows(before, after), IndexSet(integer: 3))
    }

    func testClearingSelectionDirtiesExactlyItsRows() {
        let before = keys(selection: .block(BlockSelection((2, 4), (5, 9))))
        let after = keys()
        XCTAssertEqual(changedRows(before, after), IndexSet(2 ... 5))
    }

    func testStaticOverlayAddsNoDamage() {
        let a = keys(selection: .linear(TerminalSelection((1, 2), (4, 8))),
                     findHits: [TerminalSelection((6, 0), (6, 5))])
        let b = keys(selection: .linear(TerminalSelection((1, 2), (4, 8))),
                     findHits: [TerminalSelection((6, 0), (6, 5))])
        XCTAssertEqual(changedRows(a, b), IndexSet())
    }

    func testSelectionAndFindOnTheSameRowKeySeparately() {
        // A selection span must not collide with an identical find span (different colors).
        let sel = keys(selection: .linear(TerminalSelection((2, 3), (2, 9))))
        let find = keys(findHits: [TerminalSelection((2, 3), (2, 9))])
        XCTAssertNotEqual(sel[2], find[2])
    }

    func testPreeditKeysItsRowByTextAndPosition() {
        let a = keys(preedit: "か", preeditCursor: (5, 10))
        let b = keys(preedit: "かん", preeditCursor: (5, 10))
        let c = keys(preedit: "か", preeditCursor: (5, 11))
        XCTAssertNotNil(a[5])
        XCTAssertNotEqual(a[5], b[5], "composition text change must re-encode the row")
        XCTAssertNotEqual(a[5], c[5], "composition position change must re-encode the row")
        XCTAssertEqual(changedRows(a, b), IndexSet(integer: 5))
    }

    func testOffViewportSelectionIsClamped() {
        let k = keys(selection: .linear(TerminalSelection((-3, 0), (1, 5))), rows: 24)
        XCTAssertEqual(Set(k.keys), Set([0, 1]))
        XCTAssertTrue(keys(selection: .linear(TerminalSelection((30, 0), (40, 5))), rows: 24).isEmpty)
    }

    // MARK: - Presented-frame equivalence (window-hosted; skips without Metal)

    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testSelectionPresentsBakedEquivalentCellsAndKeepsReuseWarm() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.testingSetSelectionColors(
            background: RGBColor(red: 60, green: 80, blue: 200), foreground: nil
        )
        for i in 0 ..< 30 { view.receive("\u{1b}[3\(i % 8)moverlay line \(i) content\u{1b}[0m\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingLastPresentedFrame != nil else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }

        // Select rows 1-4: the presented cells must be byte-identical to a baked build, and the
        // clean caches must survive (that is the whole point of the overlay pass).
        view.testingSetSelection(anchor: (1, 2), head: (4, 8))
        view.testingForceRender()
        let presented = try XCTUnwrap(view.testingLastPresentedFrame)
        let baked = view.testingMakeFrameBuilder().build(
            view.testingReadGridSnapshot(),
            region: .linear(TerminalSelection((1, 2), (4, 8)))
        )
        XCTAssertEqual(presented.cells, baked.cells, "overlay pass must equal the baked build")
        // The shading really happened (a selected cell carries the selection background).
        let selBg = presented.cell(row: 2, column: 4)?.background
        XCTAssertEqual(selBg, RenderColor(RGBColor(red: 60, green: 80, blue: 200)))

        // Drag the head one row down: damage must cover only the crossed rows (3 grows to a
        // full-row span, 4 joins) — not the grid.
        view.testingSetSelection(anchor: (1, 2), head: (5, 8))
        view.testingForceRender()
        let damage = try XCTUnwrap(view.testingLastPresentedDamage)
        XCTAssertFalse(damage.full)
        XCTAssertEqual(damage.rows, IndexSet([4, 5]), "a one-row drag re-encodes the crossed rows")
        if let stats = view.testingLastRenderStats {
            XCTAssertLessThanOrEqual(
                stats.encodedRows, 4,
                "the renderer re-encodes the crossed rows (+ cursor), not the grid"
            )
        }

        // Clearing the selection restores plain cells and dirties exactly the old rows.
        view.testingSetSelection(anchor: nil, head: nil)
        view.testingForceRender()
        let cleared = try XCTUnwrap(view.testingLastPresentedFrame)
        let plain = view.testingMakeFrameBuilder().build(view.testingReadGridSnapshot())
        XCTAssertEqual(cleared.cells, plain.cells)
        let clearDamage = try XCTUnwrap(view.testingLastPresentedDamage)
        XCTAssertEqual(clearDamage.rows, IndexSet(1 ... 5), "clearing dirties the old overlay rows")
    }

    func testPreeditRidesDamageAndRestoresCleanly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 10 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard let before = view.testingLastPresentedFrame else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }
        let cursorRow = before.cursor.row

        // Composition shows over the grid, dirties only its row, and never poisons the caches.
        view.setMarkedText("かん", selectedRange: NSRange(), replacementRange: NSRange())
        view.testingForceRender()
        let composing = try XCTUnwrap(view.testingLastPresentedFrame)
        let glyph = composing.cell(row: cursorRow, column: before.cursor.column)
        XCTAssertEqual(glyph?.codepoint, UnicodeScalar("か").value)
        XCTAssertEqual(glyph?.underline, .single, "preedit draws underlined")
        let damage = try XCTUnwrap(view.testingLastPresentedDamage)
        XCTAssertFalse(damage.full)
        XCTAssertEqual(damage.rows, IndexSet(integer: cursorRow), "composition dirties only its row")

        // Cancelling the composition restores the plain cells via the clean cache.
        view.unmarkText()
        view.testingForceRender()
        let restored = try XCTUnwrap(view.testingLastPresentedFrame)
        XCTAssertEqual(restored.cells, before.cells)
        let clearDamage = try XCTUnwrap(view.testingLastPresentedDamage)
        XCTAssertEqual(clearDamage.rows, IndexSet(integer: cursorRow))
    }

    /// Composing over a selected region must NOT inherit the selection shading: the preedit sits
    /// on the canvas background (no background quad, preserving window translucency) so it reads
    /// as "being typed", not "selected". applyPreedit runs after applyHighlights and used to keep
    /// whatever background the overlay pass had painted under it.
    func testPreeditOverSelectionUsesCanvasBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        let selectionBG = RGBColor(red: 60, green: 80, blue: 200)
        view.testingSetSelectionColors(background: selectionBG, foreground: nil)
        for i in 0 ..< 10 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard let before = view.testingLastPresentedFrame else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }
        let row = before.cursor.row
        let col = before.cursor.column

        // Shade the cursor row, then compose on top of the shaded cells.
        view.testingSetSelection(anchor: (row, 0), head: (row, 20))
        view.testingForceRender()
        view.setMarkedText("かん", selectedRange: NSRange(), replacementRange: NSRange())
        view.testingForceRender()

        let frame = try XCTUnwrap(view.testingLastPresentedFrame)
        let cell = try XCTUnwrap(frame.cell(row: row, column: col))
        XCTAssertEqual(cell.codepoint, UnicodeScalar("か").value)
        XCTAssertFalse(cell.drawBackground,
                       "preedit resets to the canvas background (no quad), not the selection's")
        XCTAssertNotEqual(cell.background, RenderColor(selectionBG))
    }

    func testOutputDuringActiveSelectionKeepsShadingAndDamage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.testingSetSelectionColors(
            background: RGBColor(red: 60, green: 80, blue: 200), foreground: nil
        )
        for i in 0 ..< 10 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingLastPresentedFrame != nil else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }
        view.testingSetSelection(anchor: (0, 0), head: (2, 5))
        view.testingForceRender()

        // New output lands while the selection is held: the presented frame must equal the
        // baked build of the NEW grid (selection still shaded, fresh content resolved).
        view.receive("appended while selected\r\n")
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        let presented = try XCTUnwrap(view.testingLastPresentedFrame)
        let baked = view.testingMakeFrameBuilder().build(
            view.testingReadGridSnapshot(),
            region: .linear(TerminalSelection((0, 0), (2, 5)))
        )
        XCTAssertEqual(presented.cells, baked.cells)
    }
}
