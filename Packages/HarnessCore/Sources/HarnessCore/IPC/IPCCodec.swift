import Foundation

public enum IPCCodec {
    /// Upper bound on a single framed payload. The largest legitimate message is a
    /// scrollback `capture-pane` or a clipboard `setBuffer` — both comfortably under this.
    /// A declared length above it is garbage / a desynced or hostile stream, so the reader
    /// drops the connection rather than buffering toward it (a memory-DoS vector).
    public static let maxPayloadLength = 16 * 1024 * 1024

    /// Thrown when a frame's declared length exceeds `maxPayloadLength`. The caller closes
    /// the connection (the byte stream can't be re-synced).
    public enum FrameError: Error { case tooLarge(Int) }

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
        return try? JSONDecoder().decode(IPCEnvelope.self, from: payload)
    }

    public static func decodeReply(from buffer: inout Data) throws -> IPCReply? {
        guard let payload = try extractPayload(from: &buffer) else { return nil }
        return try? JSONDecoder().decode(IPCReply.self, from: payload)
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
}
