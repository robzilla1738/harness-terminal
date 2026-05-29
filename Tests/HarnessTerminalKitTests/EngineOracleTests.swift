import GhosttyTerminal
import HarnessTerminalEngine
import XCTest

/// A/B oracle: drive identical byte streams through the native `HarnessGridTerminal`
/// and the libghostty `GridTerminal`, then diff their `readGrid()` snapshots cell by
/// cell. While the fork is still in the build (until Phase 8) it serves as the
/// reference implementation the native engine must match.
///
/// A failure here is a divergence to reconcile in `HarnessTerminalEngine` (or a benign
/// default-representation difference to normalize) — exactly what the oracle is for.
/// This whole file is removed when the fork is dropped.
final class EngineOracleTests: XCTestCase {
    private let cases: [(name: String, bytes: String)] = [
        ("plain", "Hello, world"),
        ("multiline", "alpha\r\nbeta\r\ngamma"),
        ("sgr-basic", "\u{1b}[1;31mbold-red\u{1b}[0m normal"),
        ("sgr-256", "\u{1b}[38;5;208morange\u{1b}[48;5;21m on-blue"),
        ("sgr-truecolor", "\u{1b}[38;2;10;20;30mrgb\u{1b}[0m"),
        ("attributes", "\u{1b}[3mit\u{1b}[4mund\u{1b}[7minv\u{1b}[0m"),
        ("cursor-move", "\u{1b}[5;10HX\u{1b}[1;1HY"),
        ("erase-line", "junk\u{1b}[2Kclean"),
        ("wide-cjk", "ab世界cd"),
        ("tabs", "a\tb\tc"),
        ("wrap", String(repeating: "z", count: 100)),
    ]

    func testNativeEngineMatchesGhosttyOracle() {
        for c in cases {
            guard
                let mine = HarnessGridTerminal(cols: 80, rows: 24),
                let theirs = GridTerminal(cols: 80, rows: 24)
            else {
                XCTFail("[\(c.name)] terminal creation failed")
                continue
            }
            mine.feed(c.bytes)
            theirs.feed(c.bytes)
            guard
                let a = mine.readGrid(),
                let b = theirs.readGrid()
            else {
                XCTFail("[\(c.name)] readGrid returned nil")
                continue
            }
            XCTAssertEqual(a.cols, b.cols, "[\(c.name)] cols")
            XCTAssertEqual(a.rows, b.rows, "[\(c.name)] rows")
            XCTAssertEqual(a.cursor.row, b.cursor.row, "[\(c.name)] cursor row")
            XCTAssertEqual(a.cursor.col, b.cursor.col, "[\(c.name)] cursor col")

            let rows = min(a.rows, b.rows)
            let cols = min(a.cols, b.cols)
            for r in 0 ..< rows {
                for col in 0 ..< cols {
                    guard let ca = a.cell(row: r, col: col), let cb = b.cell(row: r, col: col) else { continue }
                    XCTAssertEqual(
                        signature(ca), signature(cb),
                        "[\(c.name)] cell mismatch at (\(r),\(col))"
                    )
                }
            }
        }
    }

    // MARK: - Cross-module cell signatures

    private func signature(_ c: HarnessTerminalEngine.TerminalGridCell) -> String {
        [
            "cp:\(c.codepoint)",
            "fg:\(color(c.foreground))",
            "bg:\(color(c.background))",
            "b:\(c.bold)", "i:\(c.italic)",
            "u:\(underline(c.underline))",
            "rev:\(c.inverse)",
            "w:\(width(c.width))",
        ].joined(separator: " ")
    }

    private func signature(_ c: GhosttyTerminal.TerminalGridCell) -> String {
        [
            "cp:\(c.codepoint)",
            "fg:\(color(c.foreground))",
            "bg:\(color(c.background))",
            "b:\(c.bold)", "i:\(c.italic)",
            "u:\(underline(c.underline))",
            "rev:\(c.inverse)",
            "w:\(width(c.width))",
        ].joined(separator: " ")
    }

    private func color(_ c: HarnessTerminalEngine.TerminalGridColor) -> String {
        switch c {
        case .none: return "none"
        case let .palette(i): return "p\(i)"
        case let .rgb(r, g, b): return "rgb(\(r),\(g),\(b))"
        }
    }

    private func color(_ c: GhosttyTerminal.TerminalGridColor) -> String {
        switch c {
        case .none: return "none"
        case let .palette(i): return "p\(i)"
        case let .rgb(r, g, b): return "rgb(\(r),\(g),\(b))"
        @unknown default: return "?"
        }
    }

    private func underline(_ u: HarnessTerminalEngine.TerminalGridUnderline) -> String {
        switch u {
        case .none: return "none"
        case .single: return "single"
        case .double: return "double"
        case .curly: return "curly"
        case .dotted: return "dotted"
        case .dashed: return "dashed"
        }
    }

    private func underline(_ u: GhosttyTerminal.TerminalGridUnderline) -> String {
        switch u {
        case .none: return "none"
        case .single: return "single"
        case .double: return "double"
        case .curly: return "curly"
        case .dotted: return "dotted"
        case .dashed: return "dashed"
        @unknown default: return "?"
        }
    }

    private func width(_ w: HarnessTerminalEngine.TerminalCellWidth) -> String {
        if w == .wide { return "wide" }
        if w == .spacerTail { return "spacerTail" }
        return "normal"
    }

    private func width(_ w: GhosttyTerminal.TerminalGridCellWidth) -> String {
        if w == .wide { return "wide" }
        if w == .spacerTail { return "spacerTail" }
        return "normal"
    }
}
