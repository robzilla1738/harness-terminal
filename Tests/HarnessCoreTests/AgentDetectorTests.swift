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
}
