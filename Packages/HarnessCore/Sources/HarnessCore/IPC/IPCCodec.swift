import Foundation

public enum IPCCodec {
    private static let maxPayloadLength = 64 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    public static func decodeRequest(from buffer: inout Data) -> IPCEnvelope? {
        guard let payload = extractPayload(from: &buffer) else { return nil }
        return try? JSONDecoder().decode(IPCEnvelope.self, from: payload)
    }

    public static func decodeReply(from buffer: inout Data) -> IPCReply? {
        guard let payload = extractPayload(from: &buffer) else { return nil }
        return try? JSONDecoder().decode(IPCReply.self, from: payload)
    }

    private static func extractPayload(from buffer: inout Data) -> Data? {
        guard buffer.count >= 4 else { return nil }
        let header = Array(buffer.prefix(4))
        let length = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        guard length <= maxPayloadLength else {
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(Int(length)))
        buffer.removeFirst(total)
        return payload
    }
}
