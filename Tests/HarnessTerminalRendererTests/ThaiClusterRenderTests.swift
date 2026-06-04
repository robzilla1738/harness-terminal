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
}
