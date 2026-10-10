import XCTest
import HarnessCore
@testable import HarnessDaemonCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
final class ProcessResourceTests: XCTestCase {
    func testSamplingUsesKernelIdentityAndRefusesReusedIdentityBeforeSignaling() throws {
        let service = ProcessResourceService(), pid = getpid()
        let sample = try service.sample(surfaceID: UUID().uuidString, rootPID: pid)
        XCTAssertEqual(sample.rootGeneration, ProcessScan.generation(pid))
        XCTAssertGreaterThan(sample.processes.first { $0.pid == pid }?.residentBytes ?? 0, 0)
        XCTAssertNil(sample.cpuPercent, "First observation cannot invent a CPU interval")
        XCTAssertThrowsError(try service.terminate(rootPID: pid, expectedGeneration: "a different process generation"))
        XCTAssertEqual(ProcessScan.generation(pid), sample.rootGeneration)
    }
}
