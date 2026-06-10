import Foundation

/// Accumulation buffer for framed IPC byte streams with O(1) amortized consumption.
///
/// The `inout Data` decode entry points on `IPCCodec` consume with `Data.removeFirst`, which
/// left-shifts every remaining byte — fine for a one-shot request/reply socket, quadratic for a
/// long-lived subscription under flood (the macOS PTY hands out ~1 KiB per read, so a busy
/// surface delivers thousands of small frames per second, each paying a full-buffer shift).
/// This buffer advances a read *offset* instead, exactly like `DaemonServer`'s `PendingWrite.consumed`
/// on the write side, and compacts only when the dead prefix outgrows both a fixed floor and the
/// live remainder — so each byte is moved at most twice (the append, plus at most one amortized
/// compaction memmove) no matter how many frames it spans.
///
/// Storage is `[UInt8]`, not `Data`, deliberately: array indices always start at 0, so the
/// offset arithmetic has no `startIndex` trap, and `append` from a `read(2)` scratch buffer is a
/// single memcpy with no intermediate slice.
public struct IPCReadBuffer: Sendable {
    private var storage: [UInt8] = []
    /// Index of the first unconsumed byte in `storage`.
    private var start = 0
    /// Never compact while the dead prefix is below this — small buffers just keep appending,
    /// avoiding churn for the common short-message case.
    private static let compactionFloor = 64 * 1024

    public init() {}

    /// Number of unconsumed bytes.
    public var count: Int { storage.count - start }

    /// The first unconsumed byte (the frame-type discriminator), or nil when empty.
    public var first: UInt8? { start < storage.count ? storage[start] : nil }

    /// Append the first `count` bytes of `scratch` (a `read(2)` destination buffer). One memcpy;
    /// never reads past `count`. Counts `<= 0` are no-ops so callers can pass a raw read result.
    public mutating func append(_ scratch: [UInt8], count: Int) {
        guard count > 0 else { return }
        let n = Swift.min(count, scratch.count)
        scratch.withUnsafeBufferPointer { buf in
            storage.append(contentsOf: UnsafeBufferPointer(rebasing: buf[0 ..< n]))
        }
    }

    /// Append a whole `Data` chunk (for callers whose bytes already arrive as `Data`).
    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            storage.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }
    }

    /// Byte at `offset` into the unconsumed region. The caller bounds-checks against `count`
    /// (frame headers are only read once `count` says they're fully buffered).
    func byte(at offset: Int) -> UInt8 { storage[start + offset] }

    /// Copy `count` bytes at `offset` (unconsumed-relative) out as `Data` — the extracted frame
    /// payload. One copy, identical to what the `Data` path's `Data(buffer[...])` slice paid.
    func payloadData(at offset: Int, count: Int) -> Data {
        guard count > 0 else { return Data() }
        return storage.withUnsafeBufferPointer { buf in
            // Non-nil: count > 0 here and the caller bounds offset + count within the
            // unconsumed region, so storage is non-empty (an empty array is the only nil case).
            Data(bytes: buf.baseAddress! + start + offset, count: count)
        }
    }

    /// Consume `n` bytes from the front. O(1) amortized: advances the offset; an emptied buffer
    /// resets in place (keeping capacity), and compaction runs only when the dead prefix exceeds
    /// `compactionFloor` AND the live remainder, so the memmove it pays is always the *smaller*
    /// half and each retained byte is copied at most once per halving.
    public mutating func consume(_ n: Int) {
        start += Swift.min(n, count)
        if start == storage.count {
            storage.removeAll(keepingCapacity: true)
            start = 0
        } else if start > Self.compactionFloor, start > storage.count - start {
            storage.removeFirst(start)
            start = 0
        }
    }

    /// Drop everything (stream-desync teardown).
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        start = 0
    }
}
