import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

// XCTest pulls in ApplicationServices, whose QuickDraw `RGBColor` shadows ours.
private typealias RGBColor = HarnessTheme.RGBColor

/// `SearchHighlightIndex` replaced the per-cell `highlights.contains { $0.contains(…) }`
/// scan in `appendRow` (O(matches × cells) per frame with the find bar open). These tests
/// pin the replacement to the old predicate two ways: the index's membership must equal
/// the oracle for every cell over randomized highlight sets, and frames built through the
/// index must be byte-identical between the baked (`build`) and overlay
/// (`applyHighlights`) paths — the #85 invariant.
final class SearchHighlightIndexTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!

    /// Deterministic LCG so a failure reproduces exactly (seed printed on failure).
    private struct SeededRandom {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func randomHighlights(_ rng: inout SeededRandom, rows: Int, cols: Int, count: Int) -> [TerminalSelection] {
        (0 ..< count).map { _ in
            // Endpoints intentionally allowed slightly OUT of the viewport (negative /
            // past-the-edge) — the old `contains` answered those fine and the index must too.
            let a = (row: rng.next(rows + 4) - 2, column: rng.next(cols + 8) - 4)
            let b = (row: rng.next(rows + 4) - 2, column: rng.next(cols + 8) - 4)
            return TerminalSelection(a, b)
        }
    }

    // MARK: Membership differential (index ⇔ old predicate)

    func testIndexMatchesOraclePredicateOverRandomizedSets() {
        let rows = 24, cols = 60
        var rng = SeededRandom(state: 0x5EED_CAFE)
        for round in 0 ..< 30 {
            let highlights = randomHighlights(&rng, rows: rows, cols: cols, count: 1 + rng.next(40))
            let index = SearchHighlightIndex(highlights, rows: rows, cols: cols)
            for row in 0 ..< rows {
                for column in 0 ..< cols {
                    let oracle = highlights.contains { $0.contains(row: row, column: column) }
                    if index.contains(row: row, column: column) != oracle {
                        return XCTFail("round \(round): (\(row),\(column)) index=\(!oracle ? "miss" : "hit") oracle=\(oracle) highlights=\(highlights)")
                    }
                }
            }
        }
    }

    func testIndexMergesAdjacentOverlappingAndContainedIntervals() {
        // (0…2)+(3…5) adjacent → one run; (8…14) contains (10…12); (20…25) overlaps (23…30).
        let highlights = [
            TerminalSelection((0, 0), (0, 2)), TerminalSelection((0, 3), (0, 5)),
            TerminalSelection((0, 8), (0, 14)), TerminalSelection((0, 10), (0, 12)),
            TerminalSelection((0, 20), (0, 25)), TerminalSelection((0, 23), (0, 30)),
        ]
        let index = SearchHighlightIndex(highlights, rows: 1, cols: 40)
        XCTAssertEqual(index.intervals(forRow: 0), [0 ... 5, 8 ... 14, 20 ... 30])
    }

    func testMultiRowSelectionDecomposesLikeContains() {
        // first row → [startCol…cols-1]; middle → full row; last → [0…endCol].
        let index = SearchHighlightIndex([TerminalSelection((1, 7), (3, 4))], rows: 6, cols: 10)
        XCTAssertEqual(index.intervals(forRow: 0), [])
        XCTAssertEqual(index.intervals(forRow: 1), [7 ... 9])
        XCTAssertEqual(index.intervals(forRow: 2), [0 ... 9])
        XCTAssertEqual(index.intervals(forRow: 3), [0 ... 4])
        XCTAssertEqual(index.intervals(forRow: 4), [])
    }

    func testOutOfViewportBoundsAreClamped() {
        let index = SearchHighlightIndex([TerminalSelection((-3, -5), (0, 2)),
                                          TerminalSelection((2, 8), (9, 99))], rows: 3, cols: 10)
        XCTAssertEqual(index.intervals(forRow: 0), [0 ... 2])
        XCTAssertEqual(index.intervals(forRow: 2), [8 ... 9])
        XCTAssertTrue(index.intervals(forRow: 1).isEmpty)
    }

    // MARK: Frame differential (baked vs overlay stay byte-identical through the index)

    func testRandomizedHighlightsBakeAndOverlayByteIdentical() {
        let cols = 40, rows = 12
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< (rows - 1) {
            term.feed("\u{1b}[3\(i % 8);4\((i + 1) % 8)mline \(i) 漢字 \u{1b}[4mu\u{1b}[24m \u{1b}[7mX\u{1b}[27m\r\n")
        }
        term.feed("tail")
        let snap = term.readGrid()!
        let builder = FrameBuilder(
            theme: theme,
            selectionBackground: RGBColor(red: 60, green: 80, blue: 200),
            searchBackground: RGBColor(red: 200, green: 180, blue: 40)
        )
        var rng = SeededRandom(state: 0xD1FF_5EED)
        for round in 0 ..< 20 {
            let hits = randomHighlights(&rng, rows: rows, cols: cols, count: 1 + rng.next(30))
            let region: SelectionRegion? = round % 3 == 0
                ? .linear(TerminalSelection((rng.next(rows), rng.next(cols)), (rng.next(rows), rng.next(cols))))
                : nil
            let baked = builder.build(snap, region: region, searchHighlights: hits)
            var shaded = builder.build(snap)
            builder.applyHighlights(into: &shaded, from: snap, region: region, searchHighlights: hits,
                                    rows: IndexSet(integersIn: 0 ..< rows))
            XCTAssertEqual(shaded, baked, "round \(round): overlay must equal baked build")
        }
    }
}
