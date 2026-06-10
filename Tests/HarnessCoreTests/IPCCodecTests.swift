import XCTest
@testable import HarnessCore

final class IPCCodecTests: XCTestCase {
    /// Encode → decode → re-encode must be byte-stable (IPCRequest/Response aren't
    /// Equatable, so we compare the encoded form).
    func testRequestRoundTripIsStable() throws {
        // The full case list (see `allRequestSamples` + the `requestExhaustivenessTripwire`
        // compile-time guard) round-trips, not a hand-picked subset — a new IPCRequest case
        // breaks the build until it's added here, so the wire format can't silently regress.
        let requests = Self.allRequestSamples
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
        // Exhaustive (see `allResponseSamples` + `responseExhaustivenessTripwire`) — every
        // IPCResponse case round-trips, and a new case won't compile until it's covered here.
        let responses = Self.allResponseSamples
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

    // MARK: - IPCReadBuffer parity (the streaming read loops' O(1)-consume path)

    /// The `IPCReadBuffer` overloads must decode byte-identically to the `inout Data` originals —
    /// same frames, same order, same buffer-fully-consumed end state — including across arbitrary
    /// chunk splits (a frame header torn across two `read(2)`s) and interleaved JSON/binary frames.
    func testReadBufferDecodesIdenticallyToDataPath() throws {
        // Mixed stream: JSON reply, output frames (incl. empty + magic-bytes payloads), JSON reply.
        var stream = Data()
        stream.append(try IPCCodec.encode(IPCReply(response: .ok)))
        stream.append(try IPCCodec.encodeOutputFrame(Data([0xF5, 0xF6, 0x00, 0x01]), sequence: 7))
        stream.append(try IPCCodec.encodeOutputFrame(Data(), sequence: 8))
        stream.append(try IPCCodec.encodeOutputFrame(Data(Array("héllo wörld\r\n".utf8)), sequence: 9))
        stream.append(try IPCCodec.encode(IPCReply(response: .pong)))

        // Reference: the Data path, whole stream at once.
        var reference: [String] = []
        var dataBuf = stream
        while let frame = try IPCCodec.decodeReplyOrData(from: &dataBuf) {
            reference.append(describe(frame))
        }
        XCTAssertTrue(dataBuf.isEmpty)
        XCTAssertEqual(reference.count, 5)

        // IPCReadBuffer path, fed in every chunk size from 1 (max byte-tearing) to whole-stream.
        for chunk in [1, 2, 3, 5, 7, 16, 64, stream.count] {
            var buf = IPCReadBuffer()
            var got: [String] = []
            var i = 0
            let bytes = [UInt8](stream)
            while i < bytes.count {
                let n = min(chunk, bytes.count - i)
                buf.append(Array(bytes[i ..< i + n]), count: n)
                i += n
                while let frame = try IPCCodec.decodeReplyOrData(from: &buf) {
                    got.append(describe(frame))
                }
            }
            XCTAssertEqual(got, reference, "chunk size \(chunk) diverged from Data path")
            XCTAssertEqual(buf.count, 0, "buffer fully consumed at chunk size \(chunk)")
        }
    }

    /// Same parity for the request/input direction (the daemon's per-client read loop).
    func testReadBufferRequestPathMatchesDataPath() throws {
        var stream = Data()
        stream.append(try IPCCodec.encode(IPCEnvelope(request: .ping)))
        stream.append(try IPCCodec.encodeInputFrame(surfaceID: "surf-1", payload: Data("ls\r".utf8)))
        stream.append(try IPCCodec.encode(IPCEnvelope(request: .resizeSurface(surfaceID: "surf-1", rows: 24, cols: 80))))
        stream.append(try IPCCodec.encodeInputFrame(surfaceID: "surf-1", payload: Data([0xF6, 0x00])))

        var dataBuf = stream
        var reference: [String] = []
        while let frame = try IPCCodec.decodeRequestOrInput(from: &dataBuf) {
            reference.append(describe(frame))
        }
        XCTAssertEqual(reference.count, 4)

        for chunk in [1, 3, 9, stream.count] {
            var buf = IPCReadBuffer()
            var got: [String] = []
            var i = 0
            let bytes = [UInt8](stream)
            while i < bytes.count {
                let n = min(chunk, bytes.count - i)
                buf.append(Array(bytes[i ..< i + n]), count: n)
                i += n
                while let frame = try IPCCodec.decodeRequestOrInput(from: &buf) {
                    got.append(describe(frame))
                }
            }
            XCTAssertEqual(got, reference, "chunk size \(chunk) diverged from Data path")
            XCTAssertEqual(buf.count, 0)
        }
    }

    /// The tooLarge / undecodable error contract carries over: an oversized declared length throws
    /// (connection-fatal) and a well-framed-but-garbage JSON frame throws after consuming the frame.
    func testReadBufferErrorContractMatchesDataPath() throws {
        // Oversized binary length.
        var tooBig = IPCReadBuffer()
        var frame: [UInt8] = [0xF5]
        let badLen = UInt32(IPCCodec.maxPayloadLength + 1)
        frame += [UInt8(badLen >> 24 & 0xFF), UInt8(badLen >> 16 & 0xFF), UInt8(badLen >> 8 & 0xFF), UInt8(badLen & 0xFF)]
        tooBig.append(frame, count: frame.count)
        XCTAssertThrowsError(try IPCCodec.decodeReplyOrData(from: &tooBig)) { error in
            guard case IPCCodec.FrameError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }

        // Well-framed garbage JSON: consumed + undecodable, and the NEXT frame still decodes —
        // the in-sync-stream recovery contract the daemon's error-reply path depends on.
        let garbage = Data("not json at all".utf8)
        var lengthPrefixed = Data()
        var len = UInt32(garbage.count).bigEndian
        lengthPrefixed.append(Data(bytes: &len, count: 4))
        lengthPrefixed.append(garbage)
        lengthPrefixed.append(try IPCCodec.encode(IPCEnvelope(request: .ping)))
        var buf = IPCReadBuffer()
        buf.append(lengthPrefixed)
        XCTAssertThrowsError(try IPCCodec.decodeRequestOrInput(from: &buf)) { error in
            guard case IPCCodec.FrameError.undecodable = error else {
                return XCTFail("expected undecodable, got \(error)")
            }
        }
        guard case .request(.ping)? = try IPCCodec.decodeRequestOrInput(from: &buf) else {
            return XCTFail("stream must stay in sync after an undecodable frame")
        }
        XCTAssertEqual(buf.count, 0)
    }

    /// Compaction stress: a long stream of frames must never leave stale bytes behind or corrupt
    /// later frames when the internal compaction threshold (64 KiB dead prefix) trips mid-stream.
    func testReadBufferCompactionPreservesStream() throws {
        var buf = IPCReadBuffer()
        let payload = Data(repeating: 0x42, count: 8_192)
        var expected: UInt64 = 0
        // ~24 MiB total through the buffer; interleave appends and decodes so the offset walks
        // far past the compaction floor many times.
        for batch in 0 ..< 100 {
            for k in 0 ..< 30 {
                let frame = try IPCCodec.encodeOutputFrame(payload, sequence: UInt64(batch * 30 + k))
                buf.append(frame)
            }
            while let decoded = try IPCCodec.decodeReplyOrData(from: &buf) {
                guard case let .output(data, sequence) = decoded else { return XCTFail("expected output") }
                XCTAssertEqual(data, payload)
                XCTAssertEqual(sequence, expected)
                expected += 1
            }
        }
        XCTAssertEqual(expected, 3_000)
        XCTAssertEqual(buf.count, 0)
    }

    private func describe(_ frame: IPCCodec.DecodedReplyFrame) -> String {
        switch frame {
        case let .reply(response): return "reply:\(response)"
        case let .output(data, sequence): return "output:\(sequence):\(data.map { String($0) }.joined(separator: ","))"
        }
    }

    private func describe(_ frame: IPCCodec.DecodedRequestFrame) -> String {
        switch frame {
        case let .request(request): return "request:\(String(describing: request))"
        case let .input(surfaceID, payload): return "input:\(surfaceID):\(payload.map { String($0) }.joined(separator: ","))"
        }
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

    // MARK: - Exhaustive wire-format coverage

    /// Calling the exhaustiveness tripwires keeps them "used" and documents the contract: the
    /// round-trip tests above iterate these same fixtures, so every IPC case is byte-stable.
    func testExhaustivenessTripwiresCoverEveryCase() {
        for request in Self.allRequestSamples { requestExhaustivenessTripwire(request) }
        for response in Self.allResponseSamples { responseExhaustivenessTripwire(response) }
        XCTAssertFalse(Self.allRequestSamples.isEmpty)
        XCTAssertFalse(Self.allResponseSamples.isEmpty)
    }

    /// One sample per `IPCRequest` case (plus a few optional-field variants), in enum order.
    /// `requestExhaustivenessTripwire` is the compile-time partner: adding an enum case breaks
    /// its no-`default` switch, forcing a sample here so the wire format can't silently regress.
    static let allRequestSamples: [IPCRequest] = [
        .ping,
        .listWorkspaces,
        .listSurfaces,
        .listAgents,
        .newWorkspace(name: "Work"),
        .newSession(workspaceID: UUID(), cwd: "/tmp/project", name: "api", shell: "/bin/zsh"),
        .newSessionInGroup(targetSessionID: UUID(), name: "api-2"),
        .newTab(workspaceID: UUID(), cwd: "/tmp/project", shell: "/opt/homebrew/bin/fish"),
        .newTabInWorkspace(named: "Default", cwd: "/tmp/project", shell: "/bin/bash"),
        .newSplit(tabID: UUID(), paneID: UUID(), direction: .vertical, shell: "/opt/homebrew/bin/fish"),
        .selectWorkspace(id: UUID()),
        .selectWorkspaceByName(name: "Default"),
        .selectSession(workspaceID: UUID(), sessionID: UUID()),
        .selectTab(workspaceID: UUID(), tabID: UUID()),
        .reorderTab(workspaceID: UUID(), tabID: UUID(), toIndex: 3),
        .swapTab(workspaceID: UUID(), tabID: UUID(), withIndex: 1),
        .renumberWindows(sessionID: UUID()),
        .reorderSession(workspaceID: UUID(), sessionID: UUID(), toIndex: 2),
        .closeTab(tabID: UUID()),
        .closeSession(sessionID: UUID()),
        .closeWorkspace(id: UUID()),
        .setTheme(name: "Catppuccin Mocha"),
        .setKeepSessionsOnQuit(true),
        .setSessionPersistent(sessionID: UUID(), persistent: true),
        .setTabPersistent(tabID: UUID(), persistent: false),
        .closeEphemeralSessions,
        .notify(surfaceID: "surface-1", title: "Agent", body: "Needs approval"),
        .clearNotification(surfaceID: "surface-1"),
        .updateTabTitle(surfaceID: "surface-1", title: "vim"),
        .updateTabCwd(surfaceID: "surface-1", path: "/tmp/project/src"),
        .updateTabGitBranch(workspaceID: UUID(), tabID: UUID(), branch: "main"),
        .send(surfaceID: "surface-1", text: "ls -la\n"),
        .sendData(surfaceID: "surface-1", data: Data([0, 1, 2, 254, 255])),
        .getSnapshot,
        .createSurface(cwd: "/tmp", shell: "/bin/zsh"),
        .ensureSurface(surfaceID: "surface-1", cwd: "/tmp", shell: "/bin/zsh", rows: 40, cols: 120, scrollbackBytes: 1_048_576),
        .attachSurface(surfaceID: "surface-1"),
        .closeSurface(surfaceID: "surface-1"),
        .sendKeys(surfaceID: "surface-1", keys: ["C-a", "n", "Enter"]),
        .capturePane(surfaceID: "surface-1", includeScrollback: true),
        .capturePaneRange(surfaceID: "surface-1", start: -100, end: 0, escapeSequences: true, joinWrapped: false),
        .pipePane(surfaceID: "surface-1", shellCommand: "cat >> /tmp/log"),
        .waitFor(channel: "build-done", mode: .wait),
        .linkWindow(tabID: UUID(), targetSessionID: UUID()),
        .unlinkWindow(tabID: UUID()),
        .killPane(paneID: UUID()),
        .swapPanes(srcPaneID: UUID(), dstPaneID: UUID()),
        .resizePane(paneID: UUID(), direction: .left, amount: 5),
        .resizePaneRatio(tabID: UUID(), firstPaneID: UUID(), secondPaneID: UUID(), ratio: 0.42),
        .zoomPane(paneID: UUID()),
        .setCopyMode(surfaceID: "surface-1", enabled: true),
        .renameTab(tabID: UUID(), name: "logs"),
        .renameSession(sessionID: UUID(), name: "api"),
        .renameWorkspace(workspaceID: UUID(), name: "Work"),
        .detectAgent(surfaceID: "surface-1"),
        .subscribeSurfaceOutput(surfaceID: "surface-1", label: "harness-cli attach"),
        .cancelSubscription(surfaceID: "surface-1"),
        .replayScrollback(surfaceID: "surface-1", fromSequence: 100),
        .replayScrollbackSequenced(surfaceID: "surface-1", fromSequence: nil),
        .resizeSurface(surfaceID: "surface-1", rows: 50, cols: 200),
        .detachSurface(surfaceID: "surface-1"),
        .identifyClient(label: "harness-cli attach"),
        .listClients,
        .detachClient(clientID: UUID()),
        .daemonStats,
        .setBuffer(name: "scratch", data: Data("hello".utf8)),
        .getBuffer(name: nil),
        .listBuffers,
        .deleteBuffer(name: "scratch"),
        .pasteBuffer(surfaceID: "surface-1", name: "scratch", bracketed: true),
        .selectPaneDirectional(currentPaneID: UUID(), direction: .left),
        .selectPane(tabID: UUID(), paneID: UUID()),
        .subscribeSnapshot(label: "harness-cli attach"),
        .applyLayout(tabID: UUID(), layout: "main-vertical", mainPaneID: UUID()),
        .nextLayout(tabID: UUID()),
        .previousLayout(tabID: UUID()),
        .rotatePanes(tabID: UUID(), forward: true),
        .breakPane(paneID: UUID()),
        .joinPane(sourcePaneID: UUID(), destPaneID: UUID(), direction: .horizontal),
        .respawnPane(surfaceID: "surface-1", keepHistory: false),
        .clearHistory(surfaceID: "surface-1"),
        .setOption(scope: "global", target: nil, key: "status-position", rawValue: "top"),
        .showOptions(scope: "global"),
        .setEnvironment(sessionID: nil, key: "EDITOR", value: "nvim"),
        .showEnvironment(sessionID: UUID()),
        .bindHook(event: "pane-exited", source: "display-message done", condition: nil),
        .unbindHook(id: UUID()),
        .listHooks(event: nil),
        .displayMessage(format: "#{session_name}", print: false),
        .displayMessage(format: "#{session_name}", print: true),
        .showMessages,
        // Optional-field variants — exercise both the present and absent branch of the optionals.
        .newTab(workspaceID: UUID(), cwd: nil, shell: nil),
        .subscribeSurfaceOutput(surfaceID: "surface-1", label: nil),
        .getBuffer(name: "named"),
        .setBuffer(name: nil, data: Data([1, 2, 3])),
        .updateTabGitBranch(workspaceID: UUID(), tabID: UUID(), branch: nil),
        .ensureSurface(surfaceID: "surface-1", cwd: nil, shell: nil, rows: 24, cols: 80, scrollbackBytes: nil),
    ]

    /// One sample per `IPCResponse` case, partnered with `responseExhaustivenessTripwire`.
    static let allResponseSamples: [IPCResponse] = [
        .ok,
        .pong,
        .workspaces([WorkspaceSummary(id: UUID(), name: "Default", tabCount: 2)]),
        .surfaces([SurfaceSummary(surfaceID: "surface-1", tabTitle: "fish", workspaceName: "Default", cwd: "/tmp")]),
        .agents([AgentSessionSummary(
            workspaceName: "Default", sessionID: UUID(), sessionName: "api", tabID: UUID(),
            tabTitle: "claude", surfaceID: "surface-1", paneID: "pane-1", kind: .claudeCode,
            activity: .idle, waiting: false, lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            notificationText: "needs approval"
        )]),
        .workspaceID(UUID()),
        .sessionID(UUID()),
        .tabID(UUID()),
        .paneID(UUID()),
        .surfaceID("surface-1"),
        .snapshot(SessionSnapshot(revision: 7)),
        .text("scrollback contents"),
        .data(Data([9, 8, 7]), sequence: 42),
        .replayResult(text: "history", endSequence: 99),
        .snapshotChanged(revision: 12),
        .agentInfo(AgentSnapshot(kind: .claudeCode, executable: "/usr/bin/claude", pid: 4321)),
        .agentInfo(nil),
        .clients([ClientSummary(
            id: UUID(), label: "harness-cli attach",
            attachedSurfaceIDs: ["surface-1", "surface-2"],
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]),
        .daemonStats(DaemonStats(
            pid: 1234, uptimeSeconds: 42.5, surfaceCount: 7, totalScrollbackBytes: 12_345,
            clientCount: 2, subscriberCount: 3, snapshotRevision: 42
        )),
        .clientID(UUID()),
        .buffer(BufferSummary(
            name: "scratch", byteCount: 5, preview: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), data: Data("hello".utf8)
        )),
        .buffers([BufferSummary(
            name: "buffer0", byteCount: 5, preview: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]),
        .options([OptionEntry(scope: "global", target: nil, key: "status", value: "on")]),
        .hookID(UUID()),
        .hooks([HookEntry(id: UUID(), event: "pane-exited", commandSource: "display-message done", condition: nil)]),
        .error("Tab not found"),
    ]

    /// Compile-time guard: this no-`default` switch fails to build when an `IPCRequest` case is
    /// added — the prompt to add a matching sample to `allRequestSamples`. Never relied on at
    /// runtime; its value is the exhaustiveness check the Swift compiler performs on it.
    private func requestExhaustivenessTripwire(_ request: IPCRequest) {
        switch request {
        case .ping, .listWorkspaces, .listSurfaces, .listAgents, .getSnapshot, .listClients,
             .daemonStats, .listBuffers, .closeEphemeralSessions, .showMessages:
            break
        case .newWorkspace, .newSession, .newSessionInGroup, .newTab, .newTabInWorkspace, .newSplit,
             .selectWorkspace, .selectWorkspaceByName, .selectSession, .selectTab, .reorderTab,
             .swapTab, .renumberWindows, .reorderSession, .closeTab, .closeSession, .closeWorkspace,
             .setTheme, .setKeepSessionsOnQuit, .setSessionPersistent, .setTabPersistent,
             .notify, .clearNotification, .updateTabTitle, .updateTabCwd, .updateTabGitBranch,
             .send, .sendData, .createSurface, .ensureSurface, .attachSurface, .closeSurface,
             .sendKeys, .capturePane, .capturePaneRange, .pipePane, .waitFor, .linkWindow,
             .unlinkWindow, .killPane, .swapPanes, .resizePane, .resizePaneRatio, .zoomPane,
             .setCopyMode, .renameTab, .renameSession, .renameWorkspace, .detectAgent,
             .subscribeSurfaceOutput, .cancelSubscription, .replayScrollback,
             .replayScrollbackSequenced, .resizeSurface, .detachSurface, .identifyClient,
             .detachClient, .setBuffer, .getBuffer, .deleteBuffer, .pasteBuffer,
             .selectPaneDirectional, .selectPane, .subscribeSnapshot, .applyLayout, .nextLayout,
             .previousLayout, .rotatePanes, .breakPane, .joinPane, .respawnPane, .clearHistory, .setOption,
             .showOptions, .setEnvironment, .showEnvironment, .bindHook, .unbindHook, .listHooks,
             .displayMessage:
            break
        }
    }

    /// Compile-time guard partner for `allResponseSamples` — see `requestExhaustivenessTripwire`.
    private func responseExhaustivenessTripwire(_ response: IPCResponse) {
        switch response {
        case .ok, .pong:
            break
        case .workspaces, .surfaces, .agents, .workspaceID, .sessionID, .tabID, .paneID,
             .surfaceID, .snapshot, .text, .data, .replayResult, .snapshotChanged, .agentInfo,
             .clients, .daemonStats, .clientID, .buffer, .buffers, .options, .hookID, .hooks,
             .error:
            break
        }
    }
}
