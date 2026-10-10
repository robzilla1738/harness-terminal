import Foundation
import XCTest
@testable import HarnessDaemonCore
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class SessionHostWireTests: XCTestCase {
    func testFinalRepliesSurviveRepeatedPeerReplacement() throws {
        _ = testSIGPIPEIgnored
        let request = try IPCCodec.encode(IPCEnvelope(request: .ping))
        let reply = try IPCCodec.encode(IPCReply(response: .pong))
        for _ in 0..<128 {
            var descriptors: [Int32] = [-1, -1]
            #if canImport(Darwin)
            let streamType = SOCK_STREAM
            #else
            let streamType = Int32(SOCK_STREAM.rawValue)
            #endif
            XCTAssertEqual(socketpair(AF_UNIX, streamType, 0, &descriptors), 0)
            let channel = SessionHostChannel(fd: descriptors[0])
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            XCTAssertEqual(setsockopt(descriptors[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
            channel.start(onFrame: { frame in
                if frame == request { channel.send(reply); channel.closeAfterWrites() }
            })
            XCTAssertEqual(request.withUnsafeBytes { sysWrite(descriptors[1], $0.baseAddress, $0.count) }, request.count)
            var received = Data(), bytes = [UInt8](repeating: 0, count: 256)
            while received.count < reply.count {
                let count = read(descriptors[1], &bytes, bytes.count)
                guard count > 0 else { XCTFail("Replacement peer lost its final reply"); break }
                received.append(contentsOf: bytes.prefix(count))
            }
            XCTAssertEqual(received, reply)
            sysClose(descriptors[1])
            channel.closeChannel()
        }
    }
    func testFragmentedMixedFramesKeepTheirOrderAcrossBufferCompaction() throws {
        _ = testSIGPIPEIgnored
        var descriptors: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, streamType, 0, &descriptors), 0)
        let receiver = SessionHostChannel(fd: descriptors[0])
        defer { receiver.closeChannel(); sysClose(descriptors[1]) }
        let expected = try (0..<64).map { index -> Data in
            if index.isMultiple(of: 2) { return try IPCCodec.encode(IPCEnvelope(request: .ping)) }
            return try IPCCodec.encodeInputFrame(surfaceID: "pane", payload: Data("\(index)".utf8))
        }
        let received = FrameBox()
        let done = expectation(description: "all mixed frames")
        receiver.start(onFrame: { frame in if received.append(frame) == expected.count { done.fulfill() } })
        // Each write splits a different header/body boundary; several reads consume
        // complete frames and then leave a partial successor in the same buffer.
        let combined = expected.reduce(into: Data()) { $0.append($1) }
        var offset = 0
        while offset < combined.count {
            let size = min(17, combined.count - offset)
            let chunk = combined.subdata(in: offset..<(offset + size))
            XCTAssertEqual(chunk.withUnsafeBytes { sysWrite(descriptors[1], $0.baseAddress, $0.count) }, size)
            offset += size
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(received.frames, expected)
    }
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []
        func append(_ frame: Data) -> Int { lock.lock(); defer { lock.unlock() }; storage.append(frame); return storage.count }
        var frames: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
