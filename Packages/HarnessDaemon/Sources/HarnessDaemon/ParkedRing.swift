import Foundation

/// An idle surface's byte ring, compressed into one blob. A parked pane costs a fraction of its
/// scrollback in memory; reading it (capture, attach) decompresses a copy and leaves it parked,
/// and the next PTY output unpacks it back into the ring.
struct ParkedRing: Equatable {
    /// The ring sequence of the first byte.
    var sequence: UInt64
    var stored: Data
    var rawCount: Int
    var compressed: Bool

    init(sequence: UInt64, bytes: Data) {
        self.sequence = sequence
        rawCount = bytes.count
        if let packed = RingCodec.compress(bytes), packed.count < bytes.count {
            stored = packed
            compressed = true
        } else {
            stored = bytes
            compressed = false
        }
    }

    /// The original bytes. A blob that won't decompress (it always should) reads as empty
    /// rather than as garbage.
    var bytes: Data {
        compressed ? (RingCodec.decompress(stored) ?? Data()) : stored
    }
}

/// LZ4 through Apple's Compression framework, which favors speed over ratio: terminal output
/// is repetitive enough that LZ4 alone shrinks it several times over. Platforms without it keep
/// the bytes as they are.
enum RingCodec {
    static func compress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        guard !data.isEmpty else { return nil }
        return try? (data as NSData).compressed(using: .lz4) as Data
        #else
        return nil
        #endif
    }

    static func decompress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        return try? (data as NSData).decompressed(using: .lz4) as Data
        #else
        return nil
        #endif
    }
}
