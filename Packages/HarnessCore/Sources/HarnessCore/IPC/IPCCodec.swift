import Foundation

public enum IPCCodec {
    /// Upper bound on a single framed payload. The largest legitimate message is a
    /// scrollback `capture-pane` or a clipboard `setBuffer` — both comfortably under this.
    /// A declared length above it is garbage / a desynced or hostile stream, so the reader
    /// drops the connection rather than buffering toward it (a memory-DoS vector).
    public static let maxPayloadLength = 16 * 1024 * 1024

    /// Frame-level decode failures. `tooLarge`: the declared length exceeds `maxPayloadLength`
    /// — the byte stream can't be re-synced, so the caller closes the connection. `undecodable`:
    /// the frame was correctly sized and de-framed but its payload isn't a request this build
    /// understands (a newer client, a schema skew) — the stream stays in sync, so the caller
    /// replies with an error and keeps the connection rather than dropping it.
    public enum FrameError: Error { case tooLarge(Int), undecodable }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        // Bound the size (and avoid the `UInt32(_:)` trap on a > 4 GiB payload) — a message
        // this large is a bug, not a real reply; surface it as an error instead of crashing.
        guard payload.count <= maxPayloadLength else { throw FrameError.tooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    public static func decodeRequest(from buffer: inout Data) throws -> IPCEnvelope? {
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        // A frame that de-frames cleanly but won't decode is `undecodable`, not "need more bytes":
        // the buffer already advanced past it, so swallowing it to nil would silently drop the
        // request and hang the client. Throw so the server can reply with an error and move on.
        do {
            return try JSONDecoder().decode(IPCEnvelope.self, from: payload)
        } catch {
            throw FrameError.undecodable
        }
    }

    public static func decodeReply(from buffer: inout Data) throws -> IPCReply? {
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        // The frame de-framed cleanly (length-prefixed) but the payload won't decode — a
        // malformed/skewed reply. Throw rather than returning nil: the frame is already consumed,
        // so nil would read as "need more bytes" and hang the caller until it times out.
        do {
            return try JSONDecoder().decode(IPCReply.self, from: payload)
        } catch {
            throw FrameError.undecodable
        }
    }

    /// Pull one length-prefixed payload off the front of `buffer`. Returns nil when a full
    /// frame isn't buffered yet (caller reads more). Throws `FrameError.tooLarge` on an
    /// out-of-bounds declared length so the caller can drop the (unrecoverable) connection
    /// instead of silently clearing the buffer and mis-framing everything after it.
    private static func extractPayload(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let header = Array(buffer.prefix(4))
        let length = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        guard length <= UInt32(maxPayloadLength) else { throw FrameError.tooLarge(Int(length)) }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(Int(length)))
        buffer.removeFirst(total)
        return payload
    }

    // MARK: - Binary data frames (hot path: PTY output + keystroke input)
    //
    // Output and input byte streams are the only high-frequency payloads. Routing them through
    // `encode` (JSON) base64-encodes the bytes (+33% size) and spends JSON/base64 CPU on every
    // chunk in both directions. These binary frames carry the raw bytes with a tiny fixed header
    // and no base64; JSON stays the format for every control message.
    //
    // Disambiguation is the lead byte. A JSON frame starts with the high byte of its 4-byte length
    // prefix, which for any payload <= `maxPayloadLength` (16 MiB = 0x01000000) is 0x00 or 0x01. The
    // binary magics 0xF5/0xF6 can never collide with that, so a reader branches on byte 0 with no
    // version negotiation. (Keep `maxPayloadLength` <= 16 MiB so the JSON length high byte never
    // reaches a magic value.) NOTE: a new magic is NOT free to add — an OLD reader sees it as a
    // huge JSON length (`tooLarge`) and drops the connection, so any new frame type needs a
    // version/capability gate first. Low-frequency messages should ride the existing JSON path
    // instead (see `DaemonSubscription.resize`).
    static let outputFrameMagic: UInt8 = 0xF5
    static let inputFrameMagic: UInt8 = 0xF6

    /// Output frame (daemon → subscriber): `[0xF5][len:4 BE][sequence:8 BE][raw bytes]`. No
    /// surfaceID — an output subscription is single-surface, so the reader already knows it.
    public static func encodeOutputFrame(_ payload: Data, sequence: UInt64) throws -> Data {
        let bodyLength = 8 + payload.count
        guard bodyLength <= maxPayloadLength else { throw FrameError.tooLarge(bodyLength) }
        var data = Data(capacity: 5 + bodyLength)
        data.append(outputFrameMagic)
        appendUInt32BE(UInt32(bodyLength), to: &data)
        appendUInt64BE(sequence, to: &data)
        data.append(payload)
        return data
    }

    /// Input frame (client → daemon): `[0xF6][len:4 BE][surfaceLen:2 BE][surfaceID UTF-8][raw bytes]`.
    /// Carries surfaceID so input can ride a persistent (multi-surface-capable) connection.
    public static func encodeInputFrame(surfaceID: String, payload: Data) throws -> Data {
        let surfaceBytes = Array(surfaceID.utf8)
        guard surfaceBytes.count <= 0xFFFF else { throw FrameError.tooLarge(surfaceBytes.count) }
        let bodyLength = 2 + surfaceBytes.count + payload.count
        guard bodyLength <= maxPayloadLength else { throw FrameError.tooLarge(bodyLength) }
        var data = Data(capacity: 5 + bodyLength)
        data.append(inputFrameMagic)
        appendUInt32BE(UInt32(bodyLength), to: &data)
        appendUInt16BE(UInt16(surfaceBytes.count), to: &data)
        data.append(contentsOf: surfaceBytes)
        data.append(payload)
        return data
    }

    /// One decoded frame on a reply/output stream (a subscription connection).
    public enum DecodedReplyFrame {
        case reply(IPCResponse)
        case output(Data, sequence: UInt64)
    }

    /// Decode the next reply OR binary output frame off `buffer`. nil = a full frame isn't buffered
    /// yet. Throws `tooLarge` on an out-of-bounds declared length (unrecoverable — drop the
    /// connection), matching `decodeReply`.
    public static func decodeReplyOrData(from buffer: inout Data) throws -> DecodedReplyFrame? {
        guard let first = buffer.first else { return nil }
        if first == outputFrameMagic {
            guard let body = try extractBinaryFrame(from: &buffer) else { return nil }
            guard body.count >= 8 else { throw FrameError.undecodable }
            let sequence = readUInt64BE(body, 0)
            let payload = body.subdata(in: (body.startIndex + 8) ..< body.endIndex)
            return .output(payload, sequence: sequence)
        }
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        // Same contract as `decodeReply`: a consumed-but-undecodable frame throws (the stream read
        // loop treats it as fatal and tears down) rather than returning nil and silently dropping
        // a reply the caller is still waiting on.
        do {
            let reply = try JSONDecoder().decode(IPCReply.self, from: payload)
            return .reply(reply.response)
        } catch {
            throw FrameError.undecodable
        }
    }

    /// One decoded frame on a request/input stream (the daemon's client connections).
    public enum DecodedRequestFrame {
        case request(IPCRequest?)
        case input(surfaceID: String, payload: Data)
    }

    /// Decode the next request OR binary input frame off `buffer`. nil = incomplete. Throws
    /// `undecodable` on a framed-but-unknown JSON request (the stream stays in sync; the caller
    /// errors and continues) and `tooLarge` on an out-of-bounds length (drop the connection) — the
    /// same contract as `decodeRequest`.
    public static func decodeRequestOrInput(from buffer: inout Data) throws -> DecodedRequestFrame? {
        guard let first = buffer.first else { return nil }
        if first == inputFrameMagic {
            guard let body = try extractBinaryFrame(from: &buffer) else { return nil }
            guard body.count >= 2 else { throw FrameError.undecodable }
            let surfaceLength = Int(readUInt16BE(body, 0))
            guard body.count >= 2 + surfaceLength else { throw FrameError.undecodable }
            let sidStart = body.startIndex + 2
            let surfaceID = String(decoding: body[sidStart ..< (sidStart + surfaceLength)], as: UTF8.self)
            let payload = body.subdata(in: (sidStart + surfaceLength) ..< body.endIndex)
            return .input(surfaceID: surfaceID, payload: payload)
        }
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        do {
            return .request(try JSONDecoder().decode(IPCEnvelope.self, from: payload).request)
        } catch {
            throw FrameError.undecodable
        }
    }

    /// Pull one `[magic][len:4 BE][body]` frame's body off the front of `buffer`. Returns nil when
    /// the full frame isn't buffered yet. The caller must have verified `buffer.first` is a binary
    /// magic. Throws `tooLarge` on an out-of-bounds declared length (matches `extractPayload`).
    private static func extractBinaryFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 5 else { return nil }
        let b = buffer.startIndex
        let length = (UInt32(buffer[b + 1]) << 24)
            | (UInt32(buffer[b + 2]) << 16)
            | (UInt32(buffer[b + 3]) << 8)
            | UInt32(buffer[b + 4])
        guard length <= UInt32(maxPayloadLength) else { throw FrameError.tooLarge(Int(length)) }
        let total = 5 + Int(length)
        guard buffer.count >= total else { return nil }
        let body = Data(buffer[(b + 5) ..< (b + total)])
        buffer.removeFirst(total)
        return body
    }

    // MARK: - IPCReadBuffer overloads (streaming hot path)
    //
    // The `inout Data` entry points above consume with `Data.removeFirst` — an O(remaining)
    // left-shift per frame, which is quadratic on a long-lived subscription under flood. These
    // overloads carry the exact same framing/error contract over `IPCReadBuffer`, whose offset-
    // based `consume` is O(1) amortized. The streaming read loops (DaemonServer.readClient,
    // DaemonSubscription.start) use these; the one-shot request/reply path and the codec tests
    // keep the `Data` API (byte-identical behavior, proven by `IPCCodecTests`' dual-path suite).

    /// `decodeReplyOrData(from: inout Data)` over an `IPCReadBuffer`. Same nil/throws contract.
    public static func decodeReplyOrData(from buffer: inout IPCReadBuffer) throws -> DecodedReplyFrame? {
        guard let first = buffer.first else { return nil }
        if first == outputFrameMagic {
            guard let (bodyOffset, bodyCount) = try locateBinaryFrame(in: buffer) else { return nil }
            guard bodyCount >= 8 else {
                buffer.consume(5 + bodyCount)
                throw FrameError.undecodable
            }
            var sequence: UInt64 = 0
            for k in 0 ..< 8 { sequence = (sequence << 8) | UInt64(buffer.byte(at: bodyOffset + k)) }
            let payload = buffer.payloadData(at: bodyOffset + 8, count: bodyCount - 8)
            buffer.consume(5 + bodyCount)
            return .output(payload, sequence: sequence)
        }
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        do {
            let reply = try JSONDecoder().decode(IPCReply.self, from: payload)
            return .reply(reply.response)
        } catch {
            throw FrameError.undecodable
        }
    }

    /// `decodeRequestOrInput(from: inout Data)` over an `IPCReadBuffer`. Same nil/throws contract.
    public static func decodeRequestOrInput(from buffer: inout IPCReadBuffer) throws -> DecodedRequestFrame? {
        guard let first = buffer.first else { return nil }
        if first == inputFrameMagic {
            guard let (bodyOffset, bodyCount) = try locateBinaryFrame(in: buffer) else { return nil }
            guard bodyCount >= 2 else {
                buffer.consume(5 + bodyCount)
                throw FrameError.undecodable
            }
            let surfaceLength = (Int(buffer.byte(at: bodyOffset)) << 8) | Int(buffer.byte(at: bodyOffset + 1))
            guard bodyCount >= 2 + surfaceLength else {
                buffer.consume(5 + bodyCount)
                throw FrameError.undecodable
            }
            let surfaceID = String(decoding: buffer.payloadData(at: bodyOffset + 2, count: surfaceLength), as: UTF8.self)
            let payload = buffer.payloadData(at: bodyOffset + 2 + surfaceLength, count: bodyCount - 2 - surfaceLength)
            buffer.consume(5 + bodyCount)
            return .input(surfaceID: surfaceID, payload: payload)
        }
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        do {
            return .request(try JSONDecoder().decode(IPCEnvelope.self, from: payload).request)
        } catch {
            throw FrameError.undecodable
        }
    }

    /// JSON-frame extractor over `IPCReadBuffer` — `extractPayload(from: inout Data)`'s twin.
    private static func extractPayload(from buffer: inout IPCReadBuffer) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = (UInt32(buffer.byte(at: 0)) << 24)
            | (UInt32(buffer.byte(at: 1)) << 16)
            | (UInt32(buffer.byte(at: 2)) << 8)
            | UInt32(buffer.byte(at: 3))
        guard length <= UInt32(maxPayloadLength) else { throw FrameError.tooLarge(Int(length)) }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.payloadData(at: 4, count: Int(length))
        buffer.consume(total)
        return payload
    }

    /// Locate (don't consume) the next `[magic][len:4 BE][body]` frame: returns the body's offset
    /// and length once fully buffered, nil when incomplete. The caller consumes `5 + count` after
    /// copying what it needs — splitting locate/consume avoids materializing the body twice for
    /// frames that carry an inner structure (sequence headers, surfaceID prefixes).
    private static func locateBinaryFrame(in buffer: IPCReadBuffer) throws -> (offset: Int, count: Int)? {
        guard buffer.count >= 5 else { return nil }
        let length = (UInt32(buffer.byte(at: 1)) << 24)
            | (UInt32(buffer.byte(at: 2)) << 16)
            | (UInt32(buffer.byte(at: 3)) << 8)
            | UInt32(buffer.byte(at: 4))
        guard length <= UInt32(maxPayloadLength) else { throw FrameError.tooLarge(Int(length)) }
        guard buffer.count >= 5 + Int(length) else { return nil }
        return (5, Int(length))
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return (UInt16(data[i]) << 8) | UInt16(data[i + 1])
    }

    private static func readUInt64BE(_ data: Data, _ offset: Int) -> UInt64 {
        let i = data.startIndex + offset
        var value: UInt64 = 0
        for k in 0 ..< 8 { value = (value << 8) | UInt64(data[i + k]) }
        return value
    }
}
