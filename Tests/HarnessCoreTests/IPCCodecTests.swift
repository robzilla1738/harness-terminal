import XCTest
@testable import HarnessCore

final class IPCCodecTests: XCTestCase {
    /// Encode → decode → re-encode must be byte-stable (IPCRequest/Response aren't
    /// Equatable, so we compare the encoded form).
    func testRequestRoundTripIsStable() throws {
        let requests: [IPCRequest] = [
            .ping,
            .listSurfaces,
            .newTab(workspaceID: UUID(), cwd: "/tmp/project"),
            .reorderTab(workspaceID: UUID(), tabID: UUID(), toIndex: 3),
            .resizePaneRatio(tabID: UUID(), firstPaneID: UUID(), secondPaneID: UUID(), ratio: 0.42),
            .sendData(surfaceID: "surface-1", data: Data([0, 1, 2, 254, 255])),
            .notify(surfaceID: "surface-1", title: "Agent", body: "Needs approval"),
            .newSplit(tabID: UUID(), paneID: UUID(), direction: .vertical),
        ]
        for request in requests {
            let original = try IPCCodec.encode(IPCEnvelope(request: request))
            var buffer = original
            let decoded = try XCTUnwrap(IPCCodec.decodeRequest(from: &buffer), "decode \(request)")
            XCTAssertTrue(buffer.isEmpty, "buffer fully consumed for \(request)")
            let reencoded = try IPCCodec.encode(IPCEnvelope(request: try XCTUnwrap(decoded.request)))
            XCTAssertEqual(reencoded, original, "round-trip stable for \(request)")
        }
    }

    func testResponseRoundTripIsStable() throws {
        let responses: [IPCResponse] = [
            .ok,
            .pong,
            .tabID(UUID()),
            .paneID(UUID()),
            .text("scrollback contents"),
            .data(Data([9, 8, 7]), sequence: 42),
            .error("Tab not found"),
        ]
        for response in responses {
            let original = try IPCCodec.encode(IPCReply(response: response))
            var buffer = original
            let decoded = try XCTUnwrap(IPCCodec.decodeReply(from: &buffer))
            XCTAssertTrue(buffer.isEmpty)
            let reencoded = try IPCCodec.encode(IPCReply(response: decoded.response))
            XCTAssertEqual(reencoded, original, "round-trip stable for \(response)")
        }
    }

    func testPartialBufferDecodesToNilAndLeavesBufferIntact() throws {
        let full = try IPCCodec.encode(IPCEnvelope(request: .ping))
        var buffer = full.prefix(full.count - 1) // missing the last payload byte
        let countBefore = buffer.count
        XCTAssertNil(IPCCodec.decodeRequest(from: &buffer))
        XCTAssertEqual(buffer.count, countBefore, "incomplete frame must be left for the next read")
    }

    func testTwoMessagesInOneBufferDecodeSequentially() throws {
        var buffer = try IPCCodec.encode(IPCEnvelope(request: .ping))
        buffer.append(try IPCCodec.encode(IPCEnvelope(request: .getSnapshot)))
        XCTAssertNotNil(IPCCodec.decodeRequest(from: &buffer))
        XCTAssertNotNil(IPCCodec.decodeRequest(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOversizeLengthHeaderIsRejectedAndBufferCleared() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF]) // ~4 GiB > 64 MiB cap
        XCTAssertNil(IPCCodec.decodeRequest(from: &buffer))
        XCTAssertTrue(buffer.isEmpty, "an over-cap frame must be dropped, not buffered")
    }
}
