import Foundation
import HarnessTerminalEngine
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import Security
#endif

/// One chunk of the PTY byte ring. The read loop appends these. The authoritative
/// parser reads them later.
struct SnapshotByteSpan: Equatable, Sendable {
    var sequence: UInt64
    var data: Data
}

/// The visible screen as VT bytes (`PaneCapture.screen`) and the ring sequence it reflects.
/// A screen-only attach paints it; a parked pane seals it to disk.
struct ScreenFrame: Equatable, Sendable {
    var vt: Data
    var sequence: UInt64

    /// `[sequence: 8 bytes BE][vt]`, the plaintext of a `.park` file.
    func encoded() -> Data {
        var out = Data(capacity: 8 + vt.count)
        withUnsafeBytes(of: sequence.bigEndian) { out.append(contentsOf: $0) }
        out.append(vt)
        return out
    }

    static func decode(_ data: Data) -> ScreenFrame? {
        guard data.count >= 8 else { return nil }
        let sequence = data.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return ScreenFrame(vt: Data(data.dropFirst(8)), sequence: sequence)
    }
}

/// The ring bytes an attaching client is sent, oldest first, and where live output resumes.
struct AttachHistory: Equatable {
    var chunks: [RealPty.ScrollbackReplaySegment]
    var endSequence: UInt64
    /// The client's `fromSequence` was evicted or absent: it must reset before painting.
    var resync: Bool
    /// On a resync, the screen at `endSequence`, painted before the history.
    var screen: ScreenFrame?
}

/// Bytes the snapshot has not applied yet. Nil means the ring no longer holds
/// `fedThrough`, so the emulator has to be reset and fed the ring that remains.
enum SnapshotResync {
    static func gap(fedThrough: UInt64, ring: [SnapshotByteSpan]) -> Data? {
        guard let first = ring.first else { return Data() }
        if fedThrough < first.sequence { return nil }
        var out = Data()
        for entry in ring {
            let end = entry.sequence &+ UInt64(entry.data.count)
            if fedThrough >= end { continue }
            if fedThrough > entry.sequence {
                out.append(entry.data.dropFirst(Int(fedThrough - entry.sequence)))
            } else {
                out.append(entry.data)
            }
        }
        return out
    }
}

enum SnapshotCipher {
    static func seal(plain: Data, key: Data) -> Data? {
        let key = key32(key)
        #if canImport(CryptoKit)
        let material = SymmetricKey(data: key)
        guard let box = try? AES.GCM.seal(plain, using: material) else { return nil }
        return box.combined
        #else
        var out = Data([0x01])
        out.reserveCapacity(plain.count + 1)
        for (index, byte) in plain.enumerated() {
            out.append(byte ^ key[index % key.count])
        }
        return out
        #endif
    }

    static func open(sealed: Data, key: Data) -> Data? {
        let key = key32(key)
        #if canImport(CryptoKit)
        let material = SymmetricKey(data: key)
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: material)
        #else
        guard sealed.first == 0x01 else { return nil }
        let body = sealed.dropFirst()
        var out = Data()
        out.reserveCapacity(body.count)
        for (index, byte) in body.enumerated() {
            out.append(byte ^ key[index % key.count])
        }
        return out
        #endif
    }

    private static func key32(_ key: Data) -> Data {
        if key.count >= 32 { return Data(key.prefix(32)) }
        var out = key
        out.append(Data(repeating: 0, count: 32 - key.count))
        return out
    }
}

/// The snapshot key is a mode-0600 file next to the control socket, on every platform.
/// (A key from the old keychain backend is not carried over: the sealed park file is only
/// written today, never read back, so a fresh key loses nothing.)
/// That is the same trust boundary as the socket and the scrollback log beside it; a
/// keychain item added nothing but an access prompt whenever the daemon binary changed.
enum SnapshotKeyStore {
    static func loadOrCreate(socketDirectory: URL) -> Data {
        fileLoadOrCreate(directory: socketDirectory)
    }

    static func fileLoadOrCreate(directory: URL) -> Data {
        let url = directory.appendingPathComponent("snapshot.key")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }
        let created = randomKey()
        // Created 0600 and renamed into place, so the key is never readable by others,
        // not even between a write and a chmod.
        let temporary = directory.appendingPathComponent("snapshot.key.\(UUID().uuidString)")
        if FileManager.default.createFile(atPath: temporary.path, contents: created, attributes: [.posixPermissions: 0o600]) {
            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        }
        return created
    }

    private static func randomKey() -> Data {
        var bytes = Data(count: 32)
        #if os(macOS)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        #else
        let fd = open("/dev/urandom", O_RDONLY)
        if fd >= 0 {
            _ = bytes.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress, 32)
            }
            close(fd)
        }
        #endif
        return bytes
    }
}

/// Applies the byte ring off the PTY read thread. `readLoopFeeds` stays zero
/// because the read loop never calls `catchUp`.
final class AuthoritativeParser {
    private var term: TerminalEmulator?
    private(set) var fedThrough: UInt64 = 0
    private(set) var bytesFed = 0
    private(set) var readLoopFeeds = 0
    var gridResident: Bool { term != nil }
    var terminal: TerminalEmulator? { term }

    func catchUp(ring: [SnapshotByteSpan], cols: Int, rows: Int) {
        let sizeChanged = term?.cols != cols || term?.rows != rows
        let gap = SnapshotResync.gap(fedThrough: fedThrough, ring: ring)
        if term == nil || sizeChanged || gap == nil {
            let created = TerminalEmulator(cols: max(cols, 1), rows: max(rows, 1))
            created.maxScrollbackLines = 100_000
            created.readsGraphicsFiles = false
            term = created
            let all = ring.reduce(into: Data()) { $0.append($1.data) }
            if !all.isEmpty { created.feed(all) }
            bytesFed += all.count
            fedThrough = ring.last.map { $0.sequence &+ UInt64($0.data.count) } ?? 0
            return
        }
        if let gap, !gap.isEmpty {
            term?.feed(gap)
            bytesFed += gap.count
        }
        if let last = ring.last {
            // A ring copied before another reader's must not move the mark backwards.
            fedThrough = max(fedThrough, last.sequence &+ UInt64(last.data.count))
        }
    }

    func frame() -> ScreenFrame? {
        guard let term else { return nil }
        return ScreenFrame(vt: PaneCapture.screen(term), sequence: fedThrough)
    }

    func releaseGrid() {
        term = nil
    }
}

/// Cost of appending bytes versus parsing them. The read loop uses only the append.
enum PtyDrainComparison {
    static func measure(byteCount: Int, repeats: Int) -> (appendNanos: UInt64, parseNanos: UInt64) {
        let payload = Data(repeating: 0x41, count: byteCount)
        var sink = Data()
        sink.reserveCapacity(byteCount * repeats)
        let appendStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< repeats { sink.append(payload) }
        let appendNanos = DispatchTime.now().uptimeNanoseconds &- appendStart
        let term = TerminalEmulator(cols: 80, rows: 24)
        let parseStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< repeats { term.feed(payload) }
        let parseNanos = DispatchTime.now().uptimeNanoseconds &- parseStart
        return (appendNanos, parseNanos)
    }
}
