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

    func testAControlBoundarySeparatesAcceptedWritesAndCancelsWithItsGeneration() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
        let queue = DispatchQueue(label: "input-control-test"), writer = PtyInputWriter(queue: queue)
        let applied = expectation(description: "Control applied after earlier input")
        queue.suspend()
        XCTAssertTrue(writer.write(Data("before".utf8), master: (dup(descriptors[1]), 1)))
        let readEnd = descriptors[0]
        XCTAssertTrue(writer.perform(afterInput: (dup(descriptors[1]), 1), apply: {
            var bytes = [UInt8](repeating: 0, count: 6)
            XCTAssertEqual(read(readEnd, &bytes, bytes.count), 6)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "before")
            applied.fulfill()
        }, cancel: { XCTFail("Current control cancelled") }))
        XCTAssertTrue(writer.write(Data("after".utf8), master: (dup(descriptors[1]), 1)))
        queue.resume(); wait(for: [applied], timeout: 2)
        var bytes = [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(read(readEnd, &bytes, bytes.count), 5)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "after")
        queue.suspend()
        let cancelled = expectation(description: "Replaced generation cancels its control")
        XCTAssertTrue(writer.perform(afterInput: (dup(descriptors[1]), 1), apply: { XCTFail("Old control applied") }, cancel: { cancelled.fulfill() }))
        XCTAssertTrue(writer.write(Data("new".utf8), master: (dup(descriptors[1]), 2)))
        queue.resume(); wait(for: [cancelled], timeout: 2)
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
