import XCTest
@testable import HarnessCore

final class IPCCodecTests: XCTestCase {
    /// Encode → decode → re-encode must be byte-stable (IPCRequest/Response aren't
    /// Equatable, so we compare the encoded form).
    func testRequestRoundTripIsStable() throws {
        let requests: [IPCRequest] = [
            .ping,
            .listSurfaces,
            .newTab(workspaceID: UUID(), cwd: "/tmp/project", shell: "/opt/homebrew/bin/fish"),
            .newSession(workspaceID: UUID(), cwd: "/tmp/project", name: "api", shell: "/bin/zsh"),
            .newTabInWorkspace(named: "Default", cwd: "/tmp/project", shell: "/bin/bash"),
            .reorderTab(workspaceID: UUID(), tabID: UUID(), toIndex: 3),
            .resizePaneRatio(tabID: UUID(), firstPaneID: UUID(), secondPaneID: UUID(), ratio: 0.42),
            .sendData(surfaceID: "surface-1", data: Data([0, 1, 2, 254, 255])),
            .notify(surfaceID: "surface-1", title: "Agent", body: "Needs approval"),
            .newSplit(tabID: UUID(), paneID: UUID(), direction: .vertical, shell: "/opt/homebrew/bin/fish"),
            .selectPane(tabID: UUID(), paneID: UUID()),
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
            .pasteBuffer(surfaceID: "surface-1", name: "scratch", bracketed: true),
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

    func testLegacyNewTabRequestsDecodeWithoutShell() throws {
        let workspaceID = UUID()
        let payload = #"{"request":{"newTab":{"workspaceID":"\#(workspaceID.uuidString)","cwd":"/tmp/project"}}}"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: payload)

        guard case let .newTab(decodedWorkspaceID, cwd, shell) = try XCTUnwrap(envelope.request) else {
            return XCTFail("expected newTab")
        }
        XCTAssertEqual(decodedWorkspaceID, workspaceID)
        XCTAssertEqual(cwd, "/tmp/project")
        XCTAssertNil(shell)
    }

    func testLegacyNewSplitRequestsDecodeWithoutShell() throws {
        let tabID = UUID()
        let paneID = UUID()
        let payload = #"{"request":{"newSplit":{"tabID":"\#(tabID.uuidString)","paneID":"\#(paneID.uuidString)","direction":"vertical"}}}"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: payload)

        guard case let .newSplit(decodedTabID, decodedPaneID, direction, shell) = try XCTUnwrap(envelope.request) else {
            return XCTFail("expected newSplit")
        }
        XCTAssertEqual(decodedTabID, tabID)
        XCTAssertEqual(decodedPaneID, paneID)
        XCTAssertEqual(direction, .vertical)
        XCTAssertNil(shell)
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
        XCTAssertNil(try IPCCodec.decodeRequest(from: &buffer))
        XCTAssertEqual(buffer.count, countBefore, "incomplete frame must be left for the next read")
    }

    func testTwoMessagesInOneBufferDecodeSequentially() throws {
        var buffer = try IPCCodec.encode(IPCEnvelope(request: .ping))
        buffer.append(try IPCCodec.encode(IPCEnvelope(request: .getSnapshot)))
        XCTAssertNotNil(try IPCCodec.decodeRequest(from: &buffer))
        XCTAssertNotNil(try IPCCodec.decodeRequest(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOversizeLengthHeaderThrowsSoTheConnectionIsDropped() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF]) // ~4 GiB > the cap
        // A declared length over the cap is unrecoverable on a stream — decode throws so the
        // reader drops the connection rather than silently mis-framing what follows.
        XCTAssertThrowsError(try IPCCodec.decodeRequest(from: &buffer)) { error in
            guard case IPCCodec.FrameError.tooLarge = error else {
                return XCTFail("expected FrameError.tooLarge, got \(error)")
            }
        }
    }

    // MARK: - Binary data frames (hot path)

    func testOutputDataFrameRoundTrip() throws {
        // Includes the JSON length high bytes (0x00, 0x01) and the binary magics (0xF5, 0xF6) in
        // the payload to prove the raw bytes survive verbatim (no base64, no escaping).
        let payload = Data([0x00, 0x01, 0xF5, 0xF6, 0xFF, 0x7F, 0x80] + Array("héllo\n".utf8))
        var buffer = try IPCCodec.encodeOutputFrame(payload, sequence: 0xABCD_1234_5678)
        let decoded = try XCTUnwrap(IPCCodec.decodeReplyOrData(from: &buffer))
        guard case let .output(got, sequence) = decoded else {
            return XCTFail("expected .output, got \(decoded)")
        }
        XCTAssertEqual(got, payload)
        XCTAssertEqual(sequence, 0xABCD_1234_5678)
        XCTAssertTrue(buffer.isEmpty, "buffer fully consumed")
    }

    func testInputFrameRoundTrip() throws {
        let payload = Data([0x00, 0x01, 0xF5, 0xF6] + Array("ls -la\r".utf8))
        let surfaceID = UUID().uuidString
        var buffer = try IPCCodec.encodeInputFrame(surfaceID: surfaceID, payload: payload)
        let decoded = try XCTUnwrap(IPCCodec.decodeRequestOrInput(from: &buffer))
        guard case let .input(gotSurface, gotPayload) = decoded else {
            return XCTFail("expected .input, got \(decoded)")
        }
        XCTAssertEqual(gotSurface, surfaceID)
        XCTAssertEqual(gotPayload, payload)
        XCTAssertTrue(buffer.isEmpty, "buffer fully consumed")
    }

    func testMixedInputFramesAndJSONResizeRequestsDecodeSequentially() throws {
        // A live attach connection interleaves binary input frames (keystrokes) with JSON
        // `.resizeSurface` requests (SIGWINCH votes — deliberately JSON, not a new binary magic,
        // so OLD daemons keep working; see DaemonSubscription.resize). All must decode in order
        // off a single buffer.
        var buffer = Data()
        buffer.append(try IPCCodec.encode(IPCEnvelope(request: .subscribeSurfaceOutput(surfaceID: "s", label: "t"))))
        buffer.append(try IPCCodec.encode(IPCEnvelope(request: .resizeSurface(surfaceID: "s", rows: 24, cols: 80))))
        buffer.append(try IPCCodec.encodeInputFrame(surfaceID: "s", payload: Data("ls\r".utf8)))
        buffer.append(try IPCCodec.encode(IPCEnvelope(request: .resizeSurface(surfaceID: "s", rows: 50, cols: 200))))

        guard case .request(.subscribeSurfaceOutput("s", "t"))? = try IPCCodec.decodeRequestOrInput(from: &buffer) else {
            return XCTFail("subscribe")
        }
        guard case .request(.resizeSurface("s", 24, 80))? = try IPCCodec.decodeRequestOrInput(from: &buffer) else {
            return XCTFail("first resize")
        }
        guard case let .input(sid, payload)? = try IPCCodec.decodeRequestOrInput(from: &buffer) else {
            return XCTFail("input")
        }
        XCTAssertEqual(sid, "s"); XCTAssertEqual(payload, Data("ls\r".utf8))
        guard case .request(.resizeSurface("s", 50, 200))? = try IPCCodec.decodeRequestOrInput(from: &buffer) else {
            return XCTFail("second resize")
        }
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEmptyPayloadFramesRoundTrip() throws {
        var outBuffer = try IPCCodec.encodeOutputFrame(Data(), sequence: 0)
        guard case let .output(outPayload, seq)? = try IPCCodec.decodeReplyOrData(from: &outBuffer) else {
            return XCTFail("expected .output")
        }
        XCTAssertEqual(outPayload, Data())
        XCTAssertEqual(seq, 0)

        var inBuffer = try IPCCodec.encodeInputFrame(surfaceID: "s", payload: Data())
        guard case let .input(sid, inPayload)? = try IPCCodec.decodeRequestOrInput(from: &inBuffer) else {
            return XCTFail("expected .input")
        }
        XCTAssertEqual(sid, "s")
        XCTAssertEqual(inPayload, Data())
    }

    func testMixedJSONAndBinaryFramesDecodeSequentially() throws {
        // A reply stream interleaving JSON control frames with binary output frames must decode in
        // order off a single buffer (this is exactly what a subscription connection carries).
        var buffer = Data()
        buffer.append(try IPCCodec.encode(IPCReply(response: .ok)))
        buffer.append(try IPCCodec.encodeOutputFrame(Data("first".utf8), sequence: 1))
        buffer.append(try IPCCodec.encode(IPCReply(response: .snapshotChanged(revision: 7))))
        buffer.append(try IPCCodec.encodeOutputFrame(Data("second".utf8), sequence: 2))

        guard case .reply(.ok)? = try IPCCodec.decodeReplyOrData(from: &buffer) else { return XCTFail("ok") }
        guard case let .output(d1, s1)? = try IPCCodec.decodeReplyOrData(from: &buffer) else { return XCTFail("out1") }
        XCTAssertEqual(d1, Data("first".utf8)); XCTAssertEqual(s1, 1)
        guard case .reply(.snapshotChanged(7))? = try IPCCodec.decodeReplyOrData(from: &buffer) else { return XCTFail("snap") }
        guard case let .output(d2, s2)? = try IPCCodec.decodeReplyOrData(from: &buffer) else { return XCTFail("out2") }
        XCTAssertEqual(d2, Data("second".utf8)); XCTAssertEqual(s2, 2)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testJSONRequestStillDecodesThroughCombinedReader() throws {
        // The daemon read path now uses decodeRequestOrInput; plain JSON requests (the CLI input
        // path, resize, etc.) must still decode unchanged.
        var buffer = try IPCCodec.encode(IPCEnvelope(request: .resizeSurface(surfaceID: "s", rows: 24, cols: 80)))
        guard case let .request(req)? = try IPCCodec.decodeRequestOrInput(from: &buffer) else {
            return XCTFail("expected .request")
        }
        guard case .resizeSurface("s", 24, 80) = try XCTUnwrap(req) else {
            return XCTFail("wrong request decoded")
        }
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPartialBinaryFrameReturnsNilAndLeavesBufferIntact() throws {
        let full = try IPCCodec.encodeOutputFrame(Data("hello world".utf8), sequence: 5)
        var buffer = full.prefix(full.count - 3) // missing trailing payload bytes
        let countBefore = buffer.count
        XCTAssertNil(try IPCCodec.decodeReplyOrData(from: &buffer))
        XCTAssertEqual(buffer.count, countBefore, "incomplete binary frame must be left for the next read")
    }

    func testOversizeBinaryFrameThrowsTooLarge() {
        // magic + a declared length over the cap → unrecoverable, drop the connection.
        var buffer = Data([IPCCodec.outputFrameMagic, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try IPCCodec.decodeReplyOrData(from: &buffer)) { error in
            guard case IPCCodec.FrameError.tooLarge = error else {
                return XCTFail("expected FrameError.tooLarge, got \(error)")
            }
        }
    }

    // MARK: - Strict reply decode (a consumed-but-undecodable frame must NOT read as "need more bytes")

    /// Frame `payload` with the same 4-byte big-endian length prefix `encode` uses, so we can hand a
    /// fully-buffered but garbage JSON reply to the decoder.
    private func jsonFrame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    func testMalformedReplyFrameThrowsUndecodableAndConsumesTheFrame() {
        // Valid JSON, correctly framed, but not an `IPCReply` (version skew / corruption). The frame
        // is already de-framed, so returning nil would read as "need more bytes" and hang the caller
        // until it times out — the decoder must throw `.undecodable` instead.
        var buffer = jsonFrame(Data(#"{"unknownField":1}"#.utf8))
        XCTAssertThrowsError(try IPCCodec.decodeReply(from: &buffer)) { error in
            guard case IPCCodec.FrameError.undecodable = error else {
                return XCTFail("expected FrameError.undecodable, got \(error)")
            }
        }
    }

    func testMalformedReplyOrDataFrameThrowsUndecodable() {
        // Same contract on the combined reply/output stream a subscription connection carries.
        var buffer = jsonFrame(Data("not even json".utf8))
        XCTAssertThrowsError(try IPCCodec.decodeReplyOrData(from: &buffer)) { error in
            guard case IPCCodec.FrameError.undecodable = error else {
                return XCTFail("expected FrameError.undecodable, got \(error)")
            }
        }
    }

    func testMalformedRequestFrameThrowsUndecodable() {
        // The daemon-side mirror: a correctly-framed payload whose bytes aren't valid JSON throws so
        // the server drops the (desynced) frame instead of returning nil and hanging the reader.
        // (Note: `IPCEnvelope.request` is optional by design, so a *well-formed* JSON object with an
        // unknown shape decodes to `request == nil` — the "unrecognized request" path — not a throw.)
        var buffer = jsonFrame(Data("not even json".utf8))
        XCTAssertThrowsError(try IPCCodec.decodeRequest(from: &buffer)) { error in
            guard case IPCCodec.FrameError.undecodable = error else {
                return XCTFail("expected FrameError.undecodable, got \(error)")
            }
        }
    }
}
