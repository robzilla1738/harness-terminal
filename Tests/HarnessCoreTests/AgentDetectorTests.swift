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
}
