import XCTest
@testable import HarnessDaemonCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class RealPtyReadSourceTests: XCTestCase {
    func testSupersededStartDoesNotTouchAReusedDescriptor() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return XCTFail("Could not create fixture pipe") }
        defer { close(descriptors[0]); close(descriptors[1]) }
        let flags = fcntl(descriptors[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)

        let pty = RealPty(forTesting: ())
        pty.startReading(fd: descriptors[0], generation: .max)

        XCTAssertEqual(fcntl(descriptors[0], F_GETFL), flags,
                       "a stale start must neither set nonblocking mode nor close a descriptor it no longer owns")
    }
}
