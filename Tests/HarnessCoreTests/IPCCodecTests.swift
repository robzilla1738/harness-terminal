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
            .identifyClient(label: "harness-cli attach"),
            .listClients,
            .detachClient(clientID: UUID()),
            .daemonStats,
            .subscribeSurfaceOutput(surfaceID: "surface-1", label: "harness-cli attach"),
            .subscribeSurfaceOutput(surfaceID: "surface-1", label: nil),
            .setBuffer(name: "scratch", data: Data("hello".utf8)),
            .setBuffer(name: nil, data: Data([1, 2, 3])),
            .getBuffer(name: "scratch"),
            .getBuffer(name: nil),
            .listBuffers,
            .deleteBuffer(name: "scratch"),
            .pasteBuffer(surfaceID: "surface-1", name: "scratch"),
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
            .clientID(UUID()),
            .clients([
                ClientSummary(
                    id: UUID(),
                    label: "harness-cli attach",
                    attachedSurfaceIDs: ["surface-1", "surface-2"],
                    connectedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ]),
            .daemonStats(DaemonStats(
                pid: 1234,
                uptimeSeconds: 42.5,
                surfaceCount: 7,
                totalScrollbackBytes: 12_345,
                clientCount: 2,
                subscriberCount: 3,
                snapshotRevision: 42
            )),
            .buffer(BufferSummary(
                name: "scratch",
                byteCount: 5,
                preview: "hello",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                data: Data("hello".utf8)
            )),
            .buffers([
                BufferSummary(
                    name: "buffer0",
                    byteCount: 5,
                    preview: "hello",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ]),
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
