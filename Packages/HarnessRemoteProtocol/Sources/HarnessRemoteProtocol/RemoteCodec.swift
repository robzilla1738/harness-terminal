import Foundation

/// Four-byte big-endian length, then one type byte. Control is JSON (0), terminal output
/// (1) and input (2) are binary so high-volume terminal bytes never incur base64 overhead.
public enum RemoteCodec {
    public static let maximumFrameBytes = 12 * 1024 * 1024
    public enum Failure: Error, Equatable { case oversizedFrame, malformedFrame, invalidSurfaceID }

    public static func encode(_ message: RemoteMessage) throws -> Data {
        var payload = Data()
        switch message {
        case let .output(value):
            payload.append(1)
            try appendSurface(value.surfaceID, to: &payload)
            appendInteger(value.sequence, to: &payload)
            payload.append(value.data)
        case let .input(value):
            payload.append(2)
            try appendSurface(value.surfaceID, to: &payload)
            payload.append(value.data)
        default:
            payload.append(0)
            payload.append(try JSONEncoder().encode(message))
        }
        guard payload.count <= maximumFrameBytes else { throw Failure.oversizedFrame }
        var frame = Data()
        appendInteger(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return frame
    }

    /// Consumes all complete frames with a single compaction; incomplete tails remain untouched.
    public static func decode(buffer: inout Data) throws -> [RemoteMessage] {
        var offset = buffer.startIndex
        var messages: [RemoteMessage] = []
        while buffer.endIndex - offset >= 4 {
            let count = Int(integer(buffer, at: offset, bytes: 4))
            guard count > 0 else { throw Failure.malformedFrame }
            guard count <= maximumFrameBytes else { throw Failure.oversizedFrame }
            guard buffer.endIndex - offset - 4 >= count else { break }
            let start = offset + 4, end = start + count
            switch buffer[start] {
            case 0:
                messages.append(try JSONDecoder().decode(RemoteMessage.self, from: buffer[(start + 1)..<end]))
            case 1, 2:
                guard count >= 3 else { throw Failure.malformedFrame }
                let length = Int(integer(buffer, at: start + 1, bytes: 2))
                let dataStart = start + 3 + length
                guard length > 0, length <= 256, dataStart <= end,
                      let surface = String(data: buffer[(start + 3)..<dataStart], encoding: .utf8)
                else { throw Failure.malformedFrame }
                if buffer[start] == 1 {
                    guard end - dataStart >= 8 else { throw Failure.malformedFrame }
                    messages.append(.output(RemoteOutput(surfaceID: surface, sequence: integer(buffer, at: dataStart, bytes: 8), data: Data(buffer[(dataStart + 8)..<end]))))
                } else {
                    messages.append(.input(RemoteInput(surfaceID: surface, data: Data(buffer[dataStart..<end]))))
                }
            default: throw Failure.malformedFrame
            }
            offset = end
        }
        if offset > buffer.startIndex { buffer = Data(buffer[offset...]) }
        return messages
    }

    private static func appendSurface(_ id: String, to data: inout Data) throws {
        let bytes = Data(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 256 else { throw Failure.invalidSurfaceID }
        appendInteger(UInt16(bytes.count), to: &data)
        data.append(bytes)
    }
    private static func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    private static func integer(_ data: Data, at index: Int, bytes: Int) -> UInt64 {
        data[index..<(index + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
