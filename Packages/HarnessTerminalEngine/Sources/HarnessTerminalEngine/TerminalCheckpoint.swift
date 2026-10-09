import Foundation

/// Versioned, bounded terminal continuation state, aligned by the host with an output sequence.
/// Old scrollback is deliberately paged separately. The payload is opaque to the wire protocol.
public struct TerminalCheckpoint: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let maxPayloadBytes = 8 * 1024 * 1024
    public let version: Int
    public let payload: Data

    public init(version: Int = TerminalCheckpoint.currentVersion, payload: Data) throws {
        guard version == Self.currentVersion else { throw TerminalCheckpointError.unsupportedVersion }
        guard payload.count <= Self.maxPayloadBytes else { throw TerminalCheckpointError.tooLarge }
        self.version = version
        self.payload = payload
    }
}

public enum TerminalCheckpointError: Error, Sendable {
    case unsupportedVersion
    case tooLarge
    case invalidState
    case parserBusy
}

// Stable, endian-defined cell storage. Never encode Swift enum layout or padding as raw memory.
enum CheckpointCells {
    static func encode(_ cells: [TerminalGridCell]) -> Data {
        var bytes = Data()
        bytes.reserveCapacity(cells.count * 32)
        func append16(_ value: UInt16) {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            append16(UInt16(truncatingIfNeeded: value))
            append16(UInt16(truncatingIfNeeded: value >> 16))
        }
        func color(_ value: TerminalGridColor) {
            switch value {
            case .none: bytes.append(contentsOf: [0, 0, 0, 0])
            case let .palette(index): bytes.append(contentsOf: [1, index, 0, 0])
            case let .rgb(r, g, b): bytes.append(contentsOf: [2, r, g, b])
            }
        }
        for cell in cells {
            append32(cell.codepoint); append32(cell.combining0); append32(cell.combining1)
            color(cell.foreground); color(cell.background); color(cell.underlineColor)
            append16(cell.attributes); append16(cell.placeholderMark); append32(cell.hyperlinkID)
        }
        return bytes
    }

    static func decode(_ data: Data) throws -> [TerminalGridCell] {
        guard data.count % 32 == 0, data.count <= TerminalCheckpoint.maxPayloadBytes else {
            throw TerminalCheckpointError.invalidState
        }
        return try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var index = 0
            func read16() -> UInt16 {
                let value = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                index += 2; return value
            }
            func read32() -> UInt32 { let lo = read16(); return UInt32(lo) | UInt32(read16()) << 16 }
            func color() throws -> TerminalGridColor {
                let tag = bytes[index], r = bytes[index + 1], g = bytes[index + 2], b = bytes[index + 3]
                index += 4
                switch tag {
                case 0: return .none
                case 1: return .palette(r)
                case 2: return .rgb(r: r, g: g, b: b)
                default: throw TerminalCheckpointError.invalidState
                }
            }
            var cells: [TerminalGridCell] = []
            cells.reserveCapacity(data.count / 32)
            while index < bytes.count {
                var cell = TerminalGridCell()
                cell.codepoint = read32(); cell.combining0 = read32(); cell.combining1 = read32()
                cell.foreground = try color(); cell.background = try color(); cell.underlineColor = try color()
                let attributes = read16()
                guard attributes & ~0x1fff == 0, (attributes >> 8) & 7 <= 5,
                      (attributes >> 11) & 3 <= 2,
                      cell.codepoint == 0 || UnicodeScalar(cell.codepoint) != nil,
                      cell.combining0 == 0 || UnicodeScalar(cell.combining0) != nil,
                      cell.combining1 == 0 || cell.combining1 & 0x8000_0000 != 0 || UnicodeScalar(cell.combining1) != nil
                else { throw TerminalCheckpointError.invalidState }
                cell.attributes = attributes
                cell.placeholderMark = read16(); cell.hyperlinkID = read32()
                cells.append(cell)
            }
            return cells
        }
    }
}
