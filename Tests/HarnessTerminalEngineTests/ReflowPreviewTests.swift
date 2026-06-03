import XCTest
@testable import HarnessTerminalEngine

/// Proves `previewViewportReflow` (the cheap, O(visible), non-mutating live-resize preview) produces
/// the SAME viewport the authoritative full `resize`/reflow produces. The preview re-wraps only the
/// logical lines that land in the visible rows so a drag can re-wrap live every frame; the
/// authoritative history-wide reflow is deferred to drag-end. This test computes the preview from the
/// pre-resize state, then performs the real resize, and asserts the viewport cells + cursor match —
/// across content shapes, cursor positions, history depths, and width/height targets.
final class ReflowPreviewTests: XCTestCase {
    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

    private func build(_ feed: String, cols: Int, rows: Int, cap: Int = 10_000) -> TerminalEmulator {
        let t = TerminalEmulator(cols: cols, rows: rows)
        t.maxScrollbackLines = cap
        t.feed(feed)
        return t
    }

    private var feeds: [(name: String, feed: String)] {
        let longWrap = String(repeating: "the quick brown fox ", count: 12)
        return [
            ("deep_ascii", (0 ..< 80).map { "line \($0) of output" }.joined(separator: "\r\n") + "\r\n"),
            ("softwrap", longWrap + "\r\n" + longWrap + "\r\nshort\r\n"),
            ("wide_cjk", (0 ..< 30).map { "宽字符行 \($0) と テスト" }.joined(separator: "\r\n") + "\r\n"),
            ("emoji", (0 ..< 20).map { "row \($0) ☕📦🚀 tail" }.joined(separator: "\r\n") + "\r\n"),
            ("marks", (0 ..< 10).map { osc133("A") + "$ cmd \($0)\r\noutput for \($0) wrapping a bit longer here\r\n" }.joined()),
            ("cursor_mid", (0 ..< 14).map { "row \($0) content here" }.joined(separator: "\r\n") + "\u{1b}[4;7H"),
            ("cursor_top", "alpha\r\nbravo\r\ncharlie\r\ndelta\u{1b}[1;1H"),
            ("nearly_empty", "one short line"),
            ("empty", ""),
        ]
    }

    /// The preview viewport must equal the authoritative reflow's viewport for every target geometry.
    func testPreviewMatchesAuthoritativeReflow() {
        let inits: [(cols: Int, rows: Int)] = [(40, 6), (24, 8), (13, 5), (80, 10)]
        let targets: [(cols: Int, rows: Int)] = [
            (20, 6), (60, 6), (8, 6), (100, 6),       // width-only (narrow + widen, the O(history) path)
            (20, 3), (20, 12), (60, 4), (9, 20),      // width + height together
            (7, 7), (120, 8),
        ]
        for (name, feed) in feeds {
            for start in inits {
                for target in targets where !(target.cols == start.cols && target.rows == start.rows) {
                    let t = build(feed, cols: start.cols, rows: start.rows)
                    guard let preview = t.previewViewportReflow(cols: target.cols, rows: target.rows) else {
                        XCTFail("nil preview on primary screen (\(name))"); continue
                    }
                    t.resize(cols: target.cols, rows: target.rows)
                    let actual = t.readGrid()
                    XCTAssertEqual(preview.cells, actual.cells, "\(name): \(start.cols)x\(start.rows) → \(target.cols)x\(target.rows) viewport cells differ")
                    XCTAssertEqual(preview.cursor.row, actual.cursor.row, "\(name): cursor row \(start.cols)x\(start.rows)→\(target.cols)x\(target.rows)")
                    XCTAssertEqual(preview.cursor.col, actual.cursor.col, "\(name): cursor col \(start.cols)x\(start.rows)→\(target.cols)x\(target.rows)")
                }
            }
        }
    }

    /// A continuous drag re-wraps live each frame; every intermediate preview must match what a real
    /// reflow to that size would show (so committing at drag-end never "jumps").
    func testPreviewDuringSimulatedDrag() {
        let feed = (0 ..< 50).map { "drag row \($0) with enough text to wrap when narrow" }.joined(separator: "\r\n") + "\u{1b}[6;4H"
        for width in [120, 100, 80, 60, 40, 30, 20, 13, 9, 7, 5] {
            let preview = build(feed, cols: 100, rows: 24)
            guard let p = preview.previewViewportReflow(cols: width, rows: 24) else { XCTFail("nil"); return }
            let authoritative = build(feed, cols: 100, rows: 24)
            authoritative.resize(cols: width, rows: 24)
            let a = authoritative.readGrid()
            XCTAssertEqual(p.cells, a.cells, "drag width \(width): viewport differs")
            XCTAssertEqual(p.cursor.row, a.cursor.row, "drag width \(width): cursor row")
            XCTAssertEqual(p.cursor.col, a.cursor.col, "drag width \(width): cursor col")
        }
    }

    func testPreviewNilOnAlternateScreen() {
        let t = TerminalEmulator(cols: 40, rows: 10)
        t.feed("\u{1b}[?1049h") // enter alternate screen
        t.feed("full-screen TUI content\r\n")
        XCTAssertNil(t.previewViewportReflow(cols: 30, rows: 8), "preview must be nil on the alternate screen")
    }
}
