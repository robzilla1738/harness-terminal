import CoreText
import XCTest
import HarnessCore
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

/// The renderer side of the Thai combining-mark fix: the engine cell's combining scalars must reach
/// the `RenderCell`, and the rasterizer must compose a base + marks into one CoreText bitmap so the
/// vowel/tone are positioned instead of dropped.
final class ThaiClusterRenderTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!
    private var builder: FrameBuilder { FrameBuilder(theme: theme) }
    private let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 16, scale: 2)

    private func frame(_ bytes: String, cols: Int = 12, rows: Int = 2) -> TerminalFrame {
        let term = TerminalEmulator(cols: cols, rows: rows)
        term.feed(bytes)
        return builder.build(term.readGrid())
    }

    /// Whether CoreText inserts a U+25CC DOTTED CIRCLE when shaping `s` in Menlo (which lacks Thai,
    /// so it falls back to a Thai-capable face). The Thai scalars we use map 1:1 to glyphs in the
    /// fallback face, so an extra glyph beyond the scalar count is the inserted dotted circle. This
    /// is the exact artifact #66 is about: an orphaned spacing mark with no base in its shaping run.
    private func dottedCircleInserted(_ s: String) -> Bool {
        let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
        let attr = NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        return CTLineGetGlyphCount(line) > s.unicodeScalars.count
    }

    /// FrameBuilder copies the engine cell's combining scalars onto the RenderCell so the rasterizer
    /// can compose them; a no-mark cell is unaffected.
    func testFrameBuilderBridgesCombining() {
        let f = frame("ที่") // ท + ◌ี + ◌่
        let cell = f.cells[0]
        XCTAssertEqual(cell.codepoint, 0x0E17)
        XCTAssertEqual(cell.combining0, 0x0E35)
        XCTAssertEqual(cell.combining1, 0x0E48)
        XCTAssertEqual(cell.cluster, "ที่")
    }

    /// CoreText composes the cluster into a real bitmap with MORE ink than the bare consonant (the
    /// vowel + tone add coverage), and at least as tall (marks rise above the cap).
    func testRasterizesThaiClusterWithComposedInk() {
        guard let cluster = rasterizer.rasterize(cluster: "ที่"),
              let base = rasterizer.rasterize(codepoint: 0x0E17)
        else { return XCTFail("expected bitmaps for ที่ and ท") }
        let clusterInk = cluster.coverage.reduce(0) { $0 + Int($1) }
        let baseInk = base.coverage.reduce(0) { $0 + Int($1) }
        XCTAssertGreaterThan(clusterInk, 0, "cluster bitmap has ink")
        XCTAssertGreaterThan(clusterInk, baseInk, "vowel + tone add ink over the bare consonant")
        XCTAssertGreaterThanOrEqual(cluster.height, base.height, "marks rise above the consonant")
    }

    /// A single-scalar cluster takes the per-glyph path: byte-identical to rasterizing the codepoint,
    /// so ASCII/CJK rendering and the atlas cache are unchanged.
    func testSingleScalarClusterMatchesPerGlyph() {
        guard let viaCluster = rasterizer.rasterize(cluster: "A"),
              let viaCode = rasterizer.rasterize(codepoint: UInt32(UnicodeScalar("A").value))
        else { return XCTFail("expected a bitmap for 'A'") }
        XCTAssertEqual(viaCluster.width, viaCode.width)
        XCTAssertEqual(viaCluster.height, viaCode.height)
        XCTAssertEqual(viaCluster.coverage, viaCode.coverage)
    }

    // MARK: - SARA AM after a marked base (issue #66)

    /// The detector itself must be sound: a LONE SARA AM (U+0E33) — the pre-fix orphan — DOES make
    /// CoreText insert a dotted circle, while a lone SARA AA (U+0E32, the decomposed spacing piece)
    /// does NOT. If this baseline ever stops holding the render assertions below would be vacuous.
    func testDottedCircleDetectorBaseline() {
        XCTAssertTrue(dottedCircleInserted("\u{0E33}"),
                      "a lone SARA AM is exactly the pre-fix orphan that triggers U+25CC")
        XCTAssertFalse(dottedCircleInserted("\u{0E32}"),
                       "a lone SARA AA shapes cleanly — no dotted circle")
    }

    /// The headline #66 fix: SARA AM after a MARKED base no longer produces a dotted circle. The
    /// engine decomposes `น้ำ`/`ต่ำ`/`ซ้ำ` into a base-cluster cell (base + tone + NIKHAHIT) and a
    /// SARA AA spacing cell; rasterizing EVERY cell's cluster shapes without inserting U+25CC.
    func testMarkedBaseSaraAmRendersWithoutDottedCircle() {
        for word in ["น้ำ", "ต่ำ", "ซ้ำ", "ค่ำ", "ย้ำ"] {
            let f = frame(word)
            for cell in f.cells where cell.hasGlyph || cell.combining0 != 0 {
                XCTAssertFalse(dottedCircleInserted(cell.cluster),
                               "\(word): cell cluster \(cell.cluster) must not shape a dotted circle")
                // And the cluster actually rasterizes to ink (it is a real glyph, not nothing).
                if cell.codepoint != 0x20 {
                    XCTAssertNotNil(rasterizer.rasterize(cluster: cell.cluster),
                                    "\(word): cell cluster \(cell.cluster) rasterizes")
                }
            }
        }
    }

    /// `น้ำ` lays out as exactly two glyph cells in the frame: a base-cluster cell carrying the tone
    /// and the SARA AM's NIKHAHIT, then a SARA AA spacing cell — no orphaned SARA AM cell remains.
    func testNamWaterFrameIsBaseClusterPlusSpacingVowel() {
        let f = frame("น้ำ")
        let c0 = f.cells[0]
        XCTAssertEqual(c0.codepoint, 0x0E19)              // น
        XCTAssertEqual(c0.combining0, 0x0E49)             // tone ◌้
        XCTAssertEqual(c0.combining1, 0x0E4D)             // SARA AM's NIKHAHIT folded on
        XCTAssertEqual(c0.cluster, "น\u{0E49}\u{0E4D}")
        let c1 = f.cells[1]
        XCTAssertEqual(c1.codepoint, 0x0E32)              // SARA AA in its own cell
        XCTAssertEqual(c1.combining0, 0)
        XCTAssertEqual(f.cells[2].codepoint, 0, "no third glyph cell — SARA AM never explodes")
    }

    /// Unmarked SARA AM words (`ทำ`, `รำ`) — which already rendered fine pre-fix — stay perfect: the
    /// NIKHAHIT folds onto the bare base and neither cell shapes a dotted circle.
    func testUnmarkedSaraAmStaysPerfect() {
        for word in ["ทำ", "รำ"] {
            let f = frame(word)
            XCTAssertEqual(f.cells[0].combining0, 0x0E4D, "\(word): NIKHAHIT folds onto the bare base")
            XCTAssertEqual(f.cells[1].codepoint, 0x0E32, "\(word): SARA AA in its own cell")
            for cell in f.cells where cell.hasGlyph || cell.combining0 != 0 {
                XCTAssertFalse(dottedCircleInserted(cell.cluster),
                               "\(word): cell cluster \(cell.cluster) must not shape a dotted circle")
            }
        }
    }
}
