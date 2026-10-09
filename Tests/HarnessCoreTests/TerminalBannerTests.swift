import XCTest
@testable import HarnessCore

final class TerminalBannerTests: XCTestCase {
    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Strip SGR sequences so width assertions measure what the terminal displays.
    private func stripSGR(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func displayLines(_ data: Data) -> [String] {
        text(data).components(separatedBy: "\r\n").map(stripSGR)
    }

    private var sampleNotes: ReleaseNotes {
        ReleaseNotes(
            version: "9.9.9",
            changelogDigest: "0",
            sections: [
                ReleaseNotes.Section(title: "Fixed", items: (1 ... 10).map { "Fixed item number \($0)" }),
                ReleaseNotes.Section(title: "Added", items: ["A new thing", "Another new thing"]),
            ]
        )
    }

    func testWelcomeIsAGuidedTour() {
        let banner = text(TerminalBanner.welcome(version: "1.2.3", columns: 80))
        XCTAssertTrue(banner.contains("Harness 1.2.3"))
        XCTAssertTrue(banner.contains("Why it's different"))
        XCTAssertTrue(banner.contains("Try this, in order"))
        XCTAssertTrue(banner.contains("ctrl-a ?"))
        XCTAssertTrue(banner.contains("harness-cli"))
        XCTAssertTrue(banner.contains("thebestterminal.com"))
        XCTAssertTrue(banner.contains("won't print again"))
    }

    /// The tour wraps; it never truncates at any width the box renders at (44+). Below
    /// that the body still wraps but degenerate one-line headers may ellipsize — spawn
    /// width is always 80, so that path is synthetic.
    func testWelcomeNeverTruncates() {
        for columns in [44, 50, 60, 80, 200] {
            let lines = displayLines(TerminalBanner.welcome(version: "1.2.3", columns: columns))
            for line in lines {
                XCTAssertFalse(line.contains("…"), "truncated tour line at \(columns) cols: \(line)")
            }
        }
    }

    func testWrapIsDisplayWidthAware() {
        XCTAssertEqual(TerminalBanner.wrap("one two three", width: 7), ["one two", "three"])
        XCTAssertEqual(TerminalBanner.wrap("", width: 10), [""])
        // Wide glyphs count two columns: two 漢 (4 cols) + space + two 漢 exceeds 8.
        XCTAssertEqual(TerminalBanner.wrap("漢漢 漢漢", width: 8), ["漢漢", "漢漢"])
        XCTAssertEqual(TerminalBanner.wrap("漢漢 漢漢", width: 9), ["漢漢 漢漢"])
    }

    /// PTY output needs CRLF — a bare `\n` is LF-only to the emulator and stairsteps
    /// the whole banner.
    func testEveryNewlineIsCRLF() {
        for data in [
            TerminalBanner.welcome(version: "1.2.3", columns: 80),
            TerminalBanner.whatsNew(sampleNotes, columns: 80),
        ] {
            let banner = text(data)
            var previous: Character = " "
            for char in banner {
                if char == "\n" { XCTAssertEqual(previous, "\r", "bare \\n in banner output") }
                previous = char
            }
        }
    }

    /// Surfaces spawn at 80 columns; a wider line would wrap and shear the box frame.
    func testNoDisplayLineExceedsSpawnWidth() {
        for data in [
            TerminalBanner.welcome(version: "1.2.3", columns: 80),
            TerminalBanner.whatsNew(sampleNotes, columns: 80),
        ] {
            for line in displayLines(data) {
                XCTAssertLessThanOrEqual(TerminalBanner.displayWidth(line), 80, "line too wide: \(line)")
            }
        }
    }

    func testWhatsNewCapsItemsPerSection() {
        let banner = text(TerminalBanner.whatsNew(sampleNotes, columns: 80))
        XCTAssertTrue(banner.contains("Fixed item number 4"))
        XCTAssertFalse(banner.contains("Fixed item number 5"), "items beyond the cap must collapse")
        XCTAssertTrue(banner.contains("… and 6 more"))
        // Below the cap: no collapse line for the 2-item section.
        XCTAssertTrue(banner.contains("Another new thing"))
        XCTAssertFalse(banner.contains("… and 0 more"))
    }

    /// "Added" reads first in a what's-new card even though the changelog lists
    /// "Fixed" first.
    func testWhatsNewOrdersAddedBeforeFixed() {
        let banner = text(TerminalBanner.whatsNew(sampleNotes, columns: 80))
        guard let added = banner.range(of: "Added"), let fixed = banner.range(of: "Fixed") else {
            return XCTFail("missing section titles")
        }
        XCTAssertLessThan(added.lowerBound, fixed.lowerBound)
    }

    func testLongItemsTruncateWithEllipsisInsideWidth() {
        let notes = ReleaseNotes(
            version: "9.9.9",
            changelogDigest: "0",
            sections: [ReleaseNotes.Section(title: "Fixed", items: [String(repeating: "x", count: 200)])]
        )
        let lines = displayLines(TerminalBanner.whatsNew(notes, columns: 80))
        guard let itemLine = lines.first(where: { $0.contains("xxx") }) else {
            return XCTFail("missing item line")
        }
        XCTAssertTrue(itemLine.contains("…"))
        XCTAssertLessThanOrEqual(TerminalBanner.displayWidth(itemLine), 80)
    }

    /// CJK items must truncate by display columns, not scalar count.
    func testWideGlyphTruncationStaysInsideWidth() {
        let notes = ReleaseNotes(
            version: "9.9.9",
            changelogDigest: "0",
            sections: [ReleaseNotes.Section(title: "Fixed", items: [String(repeating: "漢", count: 100)])]
        )
        for line in displayLines(TerminalBanner.whatsNew(notes, columns: 80)) {
            XCTAssertLessThanOrEqual(TerminalBanner.displayWidth(line), 80)
        }
    }

    /// Narrow panes drop the frame instead of rendering a sheared box.
    func testNarrowColumnsRenderWithoutBox() {
        let banner = text(TerminalBanner.welcome(version: "1.2.3", columns: 30))
        XCTAssertFalse(banner.contains("╭"))
        XCTAssertTrue(banner.contains("Try this, in order"))
    }

    func testBoxFrameIsAlignedAtSpawnWidth() {
        let lines = displayLines(TerminalBanner.welcome(version: "1.2.3", columns: 80))
        let frame = lines.filter { $0.hasPrefix("╭") || $0.hasPrefix("│") || $0.hasPrefix("╰") }
        XCTAssertFalse(frame.isEmpty)
        let widths = Set(frame.map { TerminalBanner.displayWidth($0) })
        XCTAssertEqual(widths.count, 1, "box rows must all be the same width: \(widths)")
    }
}
