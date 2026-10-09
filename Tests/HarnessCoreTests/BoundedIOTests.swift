import Foundation
import XCTest
@testable import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class BoundedIOTests: XCTestCase {
    func testDiscoveryDeadlineAndOutputLimit() {
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"], timeout: 0.05)) {
            XCTAssertEqual($0 as? ProcessCaptureError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        XCTAssertThrowsError(try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 123456789"], maxOutputBytes: 4)) {
            XCTAssertEqual($0 as? ProcessCaptureError, .outputLimit)
        }
    }

    func testEarlyStdinCloseAndCancellation() throws {
        let output = try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 0<&-; printf done"], stdin: Data(repeating: 65, count: 1_048_576), timeout: 1)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "done")
        XCTAssertThrowsError(try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"], cancelled: { true })) {
            XCTAssertEqual($0 as? ProcessCaptureError, .cancelled)
        }
    }

    func testBlockedSocketWriteUsesOneDeadline() throws {
        var pair: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, socketType, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SocketDeadline(timeout: 0.05).write(Data(repeating: 0, count: 4_194_304), to: pair[0])) {
            guard case DaemonClientError.timeout = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
}
