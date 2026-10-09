import Foundation
import XCTest
@testable import HarnessDaemonCore
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PtyInputAdmissionTests: XCTestCase {
    func testAdmissionIsBoundedBeforeDispatchAndNeverTruncates() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
        let queue = DispatchQueue(label: "input-admission-test")
        queue.suspend()
        let writer = PtyInputWriter(queue: queue, limit: 5)
        XCTAssertTrue(writer.write(Data("abc".utf8), master: (dup(descriptors[1]), 1)))
        XCTAssertFalse(writer.write(Data("XYZ".utf8), master: (dup(descriptors[1]), 1)))
        XCTAssertTrue(writer.write(Data("de".utf8), master: (dup(descriptors[1]), 1)))
        queue.resume()
        queue.sync {}
        var bytes = [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(read(descriptors[0], &bytes, 5), 5)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "abcde")
    }

    func testReplacementCannotReceiveOldQueuedInput() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
        let queue = DispatchQueue(label: "input-generation-test")
        queue.suspend()
        let writer = PtyInputWriter(queue: queue)
        XCTAssertTrue(writer.write(Data("old".utf8), master: (dup(descriptors[1]), 1)))
        XCTAssertTrue(writer.write(Data("new".utf8), master: (dup(descriptors[1]), 2)))
        XCTAssertFalse(writer.write(Data("late".utf8), master: (dup(descriptors[1]), 1)))
        queue.resume()
        queue.sync {}
        var bytes = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(read(descriptors[0], &bytes, 3), 3)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "new")
    }
}
