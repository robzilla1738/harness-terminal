import Foundation
import XCTest
@testable import HarnessTerminalKit
import HarnessCore
import HarnessTerminalEngine

/// Output triggers: rule compilation, the completed-line scan, highlight recording, notify
/// cooldown, and the bounded-cost guarantees (batch budget, alt-screen skip).
@MainActor
final class TriggerTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func settle(_ view: HarnessTerminalSurfaceView) async {
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
    }

    // MARK: - Scanner

    func testLiteralPatternsAreEscapedAndRegexPatternsAreNot() {
        let scanner = TriggerScanner(rules: [
            TriggerRule(pattern: "a.b", match: .literal),
            TriggerRule(pattern: "^x+$", match: .regex),
        ])
        XCTAssertNotNil(scanner)
        XCTAssertEqual(scanner?.scan("a.b here").map(\.ruleIndex), [0])
        XCTAssertTrue(scanner?.scan("axb").isEmpty ?? false, "literal dot must not match as regex")
        XCTAssertEqual(scanner?.scan("xxx").map(\.ruleIndex), [1])
    }

    func testInvalidAndDisabledRulesAreDroppedAndRulesCapApplies() {
        XCTAssertNil(TriggerScanner(rules: []), "no rules → nil → zero-cost path")
        XCTAssertNil(TriggerScanner(rules: [TriggerRule(pattern: "[", match: .regex)]),
                     "an invalid regex alone compiles to nothing")
        XCTAssertNil(TriggerScanner(rules: [TriggerRule(pattern: "x", enabled: false)]))
        let many = (0 ..< 40).map { TriggerRule(pattern: "p\($0)") }
        XCTAssertEqual(TriggerScanner(rules: many)?.rules.count, TriggerScanner.maxRules)
    }

    func testScanTextKeepsColumnAlignmentForWideAndBlankCells() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: false)
        view.receive("ab日本ERROR")
        let snapshot = view.testingReadGridSnapshot()
        let cells = (0 ..< snapshot.cols).compactMap { snapshot.cell(row: 0, col: $0) }
        let text = TriggerScanner.scanText(cells: cells)
        // 日 and 本 occupy two columns each (base + spacer→space): ERROR starts at column 6.
        let scanner = TriggerScanner(rules: [TriggerRule(pattern: "ERROR")])
        let match = scanner?.scan(text).first
        XCTAssertEqual(match?.columns.lowerBound, 6)
        XCTAssertEqual(match?.columns.upperBound, 10)
    }

    // MARK: - Highlight action

    func testHighlightRecordsCompletedLinesOnly() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules([TriggerRule(pattern: "ERROR", action: .highlight)])
        view.receive("fine line\r\nERROR: bad thing\r\n")
        await settle(view)
        // The ERROR line is complete (cursor moved past it) — exactly one span recorded.
        let matches = view.testingTriggerHighlightMatches()
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.columns, 0 ..< 5)

        // A match on the line the cursor still occupies is NOT recorded until it completes.
        view.receive("ERROR pending")
        await settle(view)
        XCTAssertEqual(view.testingTriggerHighlightMatches().count, 1)
        view.receive("\r\n")
        await settle(view)
        XCTAssertEqual(view.testingTriggerHighlightMatches().count, 2)
    }

    func testSyncPipelineScansToo() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: false)
        view.applyTriggerRules([TriggerRule(pattern: "WARN", action: .highlight)])
        view.receive("WARN here\r\n")
        await settle(view)
        XCTAssertEqual(view.testingTriggerHighlightMatches().count, 1)
    }

    // MARK: - Notify action

    func testNotifyFiresOncePerCooldown() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules([TriggerRule(pattern: "PANIC", action: .notify)])
        var fired: [String] = []
        view.onTriggerMatched = { _, line in fired.append(line) }

        view.receive("PANIC one\r\nPANIC two\r\n")
        await settle(view)
        await drainMainQueue() // the notify hop is its own main dispatch
        XCTAssertEqual(fired.count, 1, "repeats inside the cooldown stay quiet")
        XCTAssertEqual(fired.first, "PANIC one")
    }

    func testNoRulesMeansNoScanState() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("ERROR but nobody is watching\r\n")
        await settle(view)
        XCTAssertTrue(view.testingTriggerHighlightMatches().isEmpty)
    }

    func testReplayedOutputNeverFiresTriggers() async {
        // A reopen replays scrollback through the emulator; triggers must NOT re-fire on it
        // (#168's lesson — same contract the engine enforces for query replies). The replay
        // still advances the scan high-water so the restored content isn't backfilled later,
        // and live output after the replay scans normally.
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules([TriggerRule(pattern: "ERROR", action: .highlight)])
        view.receive("ERROR from a previous session\r\n", replay: true)
        await settle(view)
        XCTAssertTrue(view.testingTriggerHighlightMatches().isEmpty,
                      "replayed history must not fire triggers")
        view.receive("ERROR live\r\n")
        await settle(view)
        XCTAssertEqual(view.testingTriggerHighlightMatches().count, 1,
                       "live output after a replay scans normally")
    }

    func testAlternateScreenIsNeverScanned() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules([TriggerRule(pattern: "ERROR", action: .highlight)])
        view.receive("\u{1b}[?1049h") // enter alt screen
        view.receive("ERROR drawn by a TUI\r\n")
        view.receive("\u{1b}[?1049l") // leave
        await settle(view)
        XCTAssertTrue(view.testingTriggerHighlightMatches().isEmpty)
    }

    func testFloodSkipsBacklogInsteadOfScanningEverything() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules([TriggerRule(pattern: "needle", action: .highlight)])
        // One needle deep in a single huge batch, beyond the newest-256-lines budget…
        var flood = "needle early\r\n"
        flood += String(repeating: "hay\r\n", count: 2_000)
        view.receive(flood)
        await settle(view)
        XCTAssertTrue(view.testingTriggerHighlightMatches().isEmpty,
                      "the budgets keep the drain path bounded — flood backlog is skipped")
        // …and once the rate-budget window rolls over, fresh output scans again.
        try? await Task.sleep(nanoseconds: 120_000_000)
        view.receive("needle late\r\n")
        await settle(view)
        XCTAssertEqual(view.testingTriggerHighlightMatches().count, 1)
    }

    // MARK: - Settings decode

    func testTriggerRuleDecodingIsTolerant() throws {
        let json = #"[{"pattern":"ok"},{"pattern":"x","match":"bogus","action":"???"},{"action":"notify"}]"#
        let rules = try JSONDecoder().decode([TriggerRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[1].match, .literal, "unknown match string falls back per field")
        XCTAssertEqual(rules[1].action, .highlight)
        XCTAssertEqual(rules[2].pattern, "", "missing pattern decodes empty (rule is ignored)")
    }
}
