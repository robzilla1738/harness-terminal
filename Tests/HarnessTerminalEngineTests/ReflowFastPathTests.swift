import XCTest
@testable import HarnessTerminalEngine

/// Proves the width-unchanged resize fast path (`TerminalScreen.resizeHeightOnly`) is byte-identical
/// to the authoritative general reflow for every height-only change. The fast path skips the
/// O(history) re-wrap (no row's wrap can change when the width is constant) and just re-homes the
/// history↔viewport boundary; this test runs the identical input through both paths
/// (`resize` vs `resizeForcingFullReflow`) and asserts the full resulting state matches, across
/// content shapes, cursor positions, history depths, the scrollback cap, and grow/shrink.
final class ReflowFastPathTests: XCTestCase {
    /// A full fingerprint of observable engine state: geometry, cursor, and every buffer row's cells
    /// (codepoint + all attributes + width via `TerminalGridCell: Equatable`) plus its OSC-133 mark.
    private func fingerprint(_ t: TerminalEmulator) -> String {
        let cur = t.readGrid().cursor
        var s = "cols=\(t.cols) rows=\(t.rows) history=\(t.historyCount)\n"
        s += "cursor r=\(cur.row) c=\(cur.col) vis=\(cur.visible) shape=\(cur.shape) blink=\(String(describing: cur.blinking))\n"
        for i in 0 ..< t.bufferLineCount {
            for cell in t.bufferLine(i) {
                s += "\(cell.codepoint),\(cell.width),"
                s += "\(cell.bold ? 1 : 0)\(cell.faint ? 1 : 0)\(cell.italic ? 1 : 0)\(cell.inverse ? 1 : 0)"
                s += "\(cell.blink ? 1 : 0)\(cell.invisible ? 1 : 0)\(cell.strikethrough ? 1 : 0)\(cell.overline ? 1 : 0),"
                s += "\(cell.underline),\(cell.foreground),\(cell.background),\(cell.underlineColor),\(cell.hyperlinkID);"
            }
            if let m = t.mark(atBufferLine: i) { s += " MARK(\(m.exit.map(String.init) ?? "-"))" }
            s += "\n"
        }
        return s
    }

    private func build(_ feed: String, cols: Int, rows: Int, cap: Int = 10_000) -> TerminalEmulator {
        let t = TerminalEmulator(cols: cols, rows: rows)
        t.maxScrollbackLines = cap
        t.feed(feed)
        return t
    }

    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

    /// Named inputs covering the cases that make height-only resize non-trivial: deep ASCII history,
    /// soft-wrapped lines, wide chars, OSC-133 marks, a cursor parked mid-screen with blank rows
    /// below it (so the trailing-blank trim pulls history up on shrink), and a nearly-empty buffer.
    private var feeds: [(name: String, feed: String)] {
        let manyLines = (0 ..< 60).map { "line \($0) content" }.joined(separator: "\r\n") + "\r\n"
        let longWrap = String(repeating: "wrap ", count: 30)
        return [
            ("deep_ascii", manyLines),
            ("softwrap", longWrap + "\r\n" + longWrap + "\r\nshort tail\r\n"),
            ("wide_cjk", (0 ..< 20).map { "宽字符行 \($0) テスト" }.joined(separator: "\r\n") + "\r\n"),
            ("marks", (0 ..< 8).map { osc133("A") + "$ cmd \($0)\r\noutput for \($0) that is a bit long\r\n" }.joined()),
            ("cursor_top_blanks_below", "alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho\u{1b}[1;1H"),
            ("cursor_mid", (0 ..< 12).map { "row \($0)" }.joined(separator: "\r\n") + "\u{1b}[3;2H"),
            ("nearly_empty", "just one line"),
            ("empty", ""),
        ]
    }

    func testHeightOnlyFastPathMatchesFullReflow() {
        let inits: [(cols: Int, rows: Int)] = [(40, 6), (20, 5), (11, 5), (80, 10), (16, 3)]
        let targetRows = [1, 2, 3, 4, 5, 6, 7, 8, 12, 24, 40]
        for (name, feed) in feeds {
            for start in inits {
                for nr in targetRows where nr != start.rows {
                    let fast = build(feed, cols: start.cols, rows: start.rows)
                    let full = build(feed, cols: start.cols, rows: start.rows)
                    fast.resize(cols: start.cols, rows: nr)
                    full.resizeForcingFullReflow(cols: start.cols, rows: nr)
                    XCTAssertEqual(
                        fingerprint(fast), fingerprint(full),
                        "fast vs full reflow diverged: \(name) \(start.cols)x\(start.rows) → \(start.cols)x\(nr)"
                    )
                }
            }
        }
    }

    /// The fast path must reproduce the general reflow's scrollback-cap trimming when shrinking
    /// pushes rows into a capped history.
    func testHeightOnlyFastPathRespectsScrollbackCap() {
        let feed = (0 ..< 50).map { "capped line \($0)" }.joined(separator: "\r\n") + "\r\n"
        for cap in [3, 8, 25] {
            for nr in [1, 2, 4, 10, 30] where nr != 12 {
                let fast = build(feed, cols: 24, rows: 12, cap: cap)
                let full = build(feed, cols: 24, rows: 12, cap: cap)
                fast.resize(cols: 24, rows: nr)
                full.resizeForcingFullReflow(cols: 24, rows: nr)
                XCTAssertEqual(fingerprint(fast), fingerprint(full), "cap \(cap), rows 12→\(nr)")
            }
        }
    }

    /// Repeated height-only changes (a vertical drag) must stay identical to the general path at
    /// every step — guards against cumulative boundary drift.
    func testHeightOnlySequenceMatchesFullReflow() {
        let feed = (0 ..< 40).map { "seq row \($0) here" }.joined(separator: "\r\n") + "\u{1b}[5;3H"
        let fast = build(feed, cols: 30, rows: 10)
        let full = build(feed, cols: 30, rows: 10)
        for nr in [8, 9, 7, 12, 4, 20, 10, 1, 24] {
            fast.resize(cols: 30, rows: nr)
            full.resizeForcingFullReflow(cols: 30, rows: nr)
            XCTAssertEqual(fingerprint(fast), fingerprint(full), "sequence step to rows \(nr)")
        }
    }

    /// A soft-wrapped row carrying an INTERIOR erased gap (EL-0 on a wrapped row leaves real default-
    /// blank content, not the wide-deferral wrap padding) must reflow identically through the verbatim
    /// fast path and the join-based general reflow. This is the case the greedy gap-trim corrupted:
    /// the full reflow used to drop the erased blanks and diverge from the fast path's verbatim copy.
    func testErasedGapOnWrappedRowMatchesFullReflow() {
        // 30 chars at width 12 wrap across 3 rows; erase the tail of the first (wrapped) row.
        let feed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\u{1b}[1;7H\u{1b}[0K"
        for nr in [2, 3, 4, 6, 8, 1] {
            let fast = build(feed, cols: 12, rows: 5)
            let full = build(feed, cols: 12, rows: 5)
            fast.resize(cols: 12, rows: nr)
            full.resizeForcingFullReflow(cols: 12, rows: nr)
            XCTAssertEqual(fingerprint(fast), fingerprint(full), "erased-gap wrapped row, rows 5→\(nr)")
        }
    }
}
