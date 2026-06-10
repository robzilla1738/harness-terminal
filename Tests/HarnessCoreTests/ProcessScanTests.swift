#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import HarnessCore

/// Roadmap PR-12: `ProcessScan.parentMap()` is the single `pid → ppid` snapshot the agent scanner
/// (and the GUI shell tracker) build once per tick and share across surfaces, replacing the prior
/// per-surface rebuilds. These cover the primitive itself.
final class ProcessScanTests: XCTestCase {
    func testParentMapLinksCurrentProcessToItsParent() {
        let map = ProcessScan.parentMap()
        let me = getpid()
        XCTAssertFalse(map.isEmpty, "the live system always has processes")
        XCTAssertNotNil(map[me], "the current process must be in the map")
        XCTAssertEqual(map[me], getppid(), "its recorded parent must be the real ppid")
        XCTAssertEqual(map[me], ProcessScan.parentPID(me), "the map agrees with the single-PID lookup")
    }

    func testParentMapCapturesASpawnedChildsParent() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let map = ProcessScan.parentMap()
        // A `Process`-spawned child is a direct child of the test runner.
        XCTAssertEqual(map[child.processIdentifier], getpid(),
                       "a spawned child's parent in the map is the test process")
    }
}
