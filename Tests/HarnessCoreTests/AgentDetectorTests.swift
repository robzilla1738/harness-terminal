import Darwin
import XCTest
@testable import HarnessCore

final class AgentDetectorTests: XCTestCase {
    func testActivityTracksRecentOutputAndDecaysAfterQuietWindow() throws {
        let surfaceKey = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            AgentDetector.unregisterRootPID(forSurfaceKey: surfaceKey)
        }

        AgentDetector.registerRootPID(getpid(), forSurfaceKey: surfaceKey)
        let table = AgentTable(entries: [
            AgentTableEntry(kind: .generic, executables: ["sleep"]),
        ])

        _ = AgentDetector.scan(table: table)
        XCTAssertEqual(AgentDetector.snapshot(forSurfaceKey: surfaceKey)?.activity, .idle)
        XCTAssertTrue(AgentDetector.scan(table: table).isEmpty)

        AgentDetector.recordActivity(forSurfaceKey: surfaceKey)
        _ = AgentDetector.scan(table: table)
        XCTAssertEqual(AgentDetector.snapshot(forSurfaceKey: surfaceKey)?.activity, .working)
        XCTAssertTrue(AgentDetector.scan(table: table).isEmpty)

        Thread.sleep(forTimeInterval: 3.2)
        _ = AgentDetector.scan(table: table)
        XCTAssertEqual(AgentDetector.snapshot(forSurfaceKey: surfaceKey)?.activity, .idle)
        XCTAssertTrue(AgentDetector.scan(table: table).isEmpty)
    }

    /// Regression: native Claude Code installs symlink `claude` to a version-numbered
    /// binary (e.g. .../versions/2.1.152), so `proc_pidpath`'s lastPathComponent is the
    /// version, not "claude". Detection must still match via argv[0] — that's what
    /// `matchesAny` is for.
    func testEntryMatchesAnyFindsAgentByInvocationName() {
        let entry = AgentTableEntry(kind: .claudeCode, executables: ["claude", "claude-code"])
        // Real-world: proc_pidpath -> .../versions/2.1.152, argv[0] basename -> "claude".
        let candidates: Set<String> = ["2.1.152", "claude"]
        XCTAssertTrue(entry.matchesAny(candidates))

        // Nothing in the set matches → no false positive.
        XCTAssertFalse(entry.matchesAny(["node", "2.1.152", "cli.js"]))

        // The default table's claudeCode entry has the same coverage.
        let defaultEntry = AgentTable.default.entries.first { $0.kind == .claudeCode }
        XCTAssertNotNil(defaultEntry)
        XCTAssertTrue(defaultEntry?.matchesAny(["2.1.152", "claude"]) ?? false)
    }

    /// Title-based fallback for when the daemon proc-tree scan can't see the
    /// agent (the case the user reported: Claude Code shown as raw text in
    /// the sidebar instead of a chip).
    func testTitleInferenceRecognizesClaudeCodeWithLeadingGlyphs() {
        XCTAssertEqual(AgentTitleInference.kind(from: "* Claude Code"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "✱ Claude Code"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "✻ Claude"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "✶ Claude"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "  Claude Code"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "Claude Code"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "Claude"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "Claude-Code v2.1"), .claudeCode)
        XCTAssertEqual(AgentTitleInference.kind(from: "claude: working…"), .claudeCode)
    }

    func testTitleInferenceRecognizesOtherAgents() {
        XCTAssertEqual(AgentTitleInference.kind(from: "Codex"), .codex)
        XCTAssertEqual(AgentTitleInference.kind(from: "• Codex"), .codex)
        XCTAssertEqual(AgentTitleInference.kind(from: "Cursor Agent"), .cursor)
        XCTAssertEqual(AgentTitleInference.kind(from: "Cursor — main.swift"), .cursor)
        XCTAssertEqual(AgentTitleInference.kind(from: "Aider"), .aider)
        XCTAssertEqual(AgentTitleInference.kind(from: "Gemini-CLI"), .gemini)
        XCTAssertEqual(AgentTitleInference.kind(from: "goose run"), .goose)
        XCTAssertEqual(AgentTitleInference.kind(from: "Hermes"), .hermes)
    }

    /// Inference must NOT match partial words inside chatty shell titles —
    /// otherwise `vim claude.txt` or "agenda.md" would light up the wrong chip.
    func testTitleInferenceRejectsPartialAndGenericMatches() {
        XCTAssertNil(AgentTitleInference.kind(from: "vim claude.txt"))
        XCTAssertNil(AgentTitleInference.kind(from: "claudette"))
        XCTAssertNil(AgentTitleInference.kind(from: "cursors and selections"))
        XCTAssertNil(AgentTitleInference.kind(from: "agenda.md"))
        XCTAssertNil(AgentTitleInference.kind(from: "pip install requests"))
        XCTAssertNil(AgentTitleInference.kind(from: ""))
        XCTAssertNil(AgentTitleInference.kind(from: "   "))
        XCTAssertNil(AgentTitleInference.kind(from: "Shell"))
    }
}
