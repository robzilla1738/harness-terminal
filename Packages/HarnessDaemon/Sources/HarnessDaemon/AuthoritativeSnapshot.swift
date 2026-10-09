import Foundation
import HarnessCore
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
    var checkpoint: Data? = nil
    private static let checkpointMagic = Data("HARCP001".utf8)

    /// Original `[sequence][vt]` park files remain readable. New files preserve a full
    /// checkpoint so parking does not lose parser continuation, images or inactive screens.
    func encoded() -> Data {
        var out = Data()
        if let checkpoint {
            out.append(Self.checkpointMagic)
            withUnsafeBytes(of: sequence.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(vt.count).bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(checkpoint.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(vt); out.append(checkpoint)
        } else {
            withUnsafeBytes(of: sequence.bigEndian) { out.append(contentsOf: $0) }
            out.append(vt)
        }
        return out
    }

    static func decode(_ data: Data) -> ScreenFrame? {
        guard data.count >= 8 else { return nil }
        if data.prefix(8) == checkpointMagic {
            guard data.count >= 24 else { return nil }
            let sequence = data[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let vtCount = data[16..<20].reduce(0) { $0 << 8 | Int($1) }
            let checkpointCount = data[20..<24].reduce(0) { $0 << 8 | Int($1) }
            guard vtCount <= 16 * 1024 * 1024, checkpointCount <= 8 * 1024 * 1024,
                  vtCount + checkpointCount == data.count - 24 else { return nil }
            return ScreenFrame(vt: Data(data[24..<(24 + vtCount)]), sequence: sequence,
                               checkpoint: Data(data[(24 + vtCount)...]))
        }
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
    var replaySizes: [ReplaySize]?
}

enum SnapshotCipher {
    static func seal(plain: Data, key: Data) -> Data? {
        let key = key32(key)
        #if canImport(CryptoKit)
        let material = SymmetricKey(data: key)
        guard let box = try? AES.GCM.seal(plain, using: material) else { return nil }
        return box.combined
        #else
        // No CryptoKit: the bytes stay plain, guarded by the 0600 file mode like the scrollback
        // log beside them. The header names the key and checks the body, so a park file from
        // another key, or a damaged one, is refused rather than read as garbage.
        var out = Data([0x02])
        out.append(fingerprint(key))
        out.append(fingerprint(plain))
        out.append(plain)
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
        guard sealed.count >= 17, sealed.first == 0x02,
              sealed.dropFirst().prefix(8) == fingerprint(key) else { return nil }
        let plain = Data(sealed.dropFirst(17))
        return sealed.dropFirst(9).prefix(8) == fingerprint(plain) ? plain : nil
        #endif
    }

    #if !canImport(CryptoKit)
    /// FNV-1a 64, little-endian. A fingerprint, not a MAC: it tells keys and bodies apart.
    private static func fingerprint(_ data: Data) -> Data {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return withUnsafeBytes(of: hash.littleEndian) { Data($0) }
    }
    #endif

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
    private let historyLines: Int
    private(set) var fedThrough: UInt64 = 0
    private(set) var bytesFed = 0
    private(set) var readLoopFeeds = 0
    var gridResident: Bool { term != nil }
    var terminal: TerminalEmulator? { term }

    /// `historyLines` caps the scrollback the grid keeps (at least 1; the emulator reads 0 as
    /// unlimited). Capture needs it all; a screen needs none, and a full row of history costs
    /// as much as a row of screen.
    init(historyLines: Int = 100_000) {
        self.historyLines = historyLines
    }

    func catchUp(ring: [SnapshotByteSpan], cols: Int, rows: Int, sizes: [ReplaySize] = []) {
        let evicted = ring.first.map { fedThrough < $0.sequence } ?? false
        if term == nil || evicted {
            let initial = sizes.first
            let created = TerminalEmulator(cols: Int(initial?.cols ?? UInt16(clamping: cols)),
                                           rows: Int(initial?.rows ?? UInt16(clamping: rows)))
            created.maxScrollbackLines = historyLines
            created.readsGraphicsFiles = false
            created.isReplaying = true
            term = created
            // A fresh PTY starts at sequence 1 even before its first output byte.
            // Its launch/resize marker is the boundary for an empty screen.
            fedThrough = ring.first?.sequence ?? sizes.last?.sequence ?? 0
        }
        guard let term else { return }
        var low = 0
        var high = ring.count
        while low < high {
            let mid = low + (high - low) / 2
            if ring[mid].sequence + UInt64(ring[mid].data.count) <= fedThrough { low = mid + 1 }
            else { high = mid }
        }
        for span in ring[low...] {
            let end = span.sequence &+ UInt64(span.data.count)
            guard end > fedThrough else { continue }
            let offset = fedThrough > span.sequence ? Int(fedThrough - span.sequence) : 0
            let data = Data(span.data.dropFirst(offset))
            ReplaySize.replay(data, sequence: span.sequence + UInt64(offset), sizes: sizes,
                              resize: { c, r in
                                  if term.cols != c || term.rows != r { term.resize(cols: c, rows: r) }
                              }, feed: term.feed)
            bytesFed += data.count
            fedThrough = end
        }
        if term.cols != cols || term.rows != rows { term.resize(cols: cols, rows: rows) }
    }

    func frame(includeCheckpoint: Bool = false) -> ScreenFrame? {
        guard let term else { return nil }
        var checkpoint: Data?
        if includeCheckpoint {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let state = try? term.checkpoint(), let encoded = try? encoder.encode(state), encoded.count <= 8 * 1024 * 1024 {
                checkpoint = encoded
            }
        }
        return ScreenFrame(vt: PaneCapture.screen(term), sequence: fedThrough, checkpoint: checkpoint)
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

/// Keeps the screens of panes no client watches caught up (`RealPty.warmScreen`), so an attach
/// paints without parsing the ring. A pane asks when it starts, when its last client leaves, and
/// on output or a resize while nobody watches. Requests coalesce per pane, at most `width` panes
/// parse at once, at utility QoS (never on the server queue or a PTY read loop), and after each
/// pass a pane rests nine times as long, so keeping it warm takes at most a tenth of a core even
/// under a flood.
final class ScreenWarmer: @unchecked Sendable {
    static let shared = ScreenWarmer(width: 2)

    private let width: Int
    private let lock = NSLock()
    private var pending: [RealPty] = []
    private var queued: Set<ObjectIdentifier> = []
    /// Panes in a pass or resting after one, and whether another was asked for meanwhile.
    private var busy: [ObjectIdentifier: (pty: RealPty, asked: Bool)] = [:]
    private var running = 0

    init(width: Int) {
        self.width = width
    }

    func request(_ pty: RealPty) {
        let id = ObjectIdentifier(pty)
        lock.lock()
        if busy[id] != nil {
            busy[id]?.asked = true
            lock.unlock()
            return
        }
        guard queued.insert(id).inserted else {
            lock.unlock()
            return
        }
        pending.append(pty)
        let start = running < width
        if start { running += 1 }
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.drain() } }
    }

    /// One worker: warm queued panes until none are left. A request that arrives during a
    /// pane's pass or rest is held, and queues it again once the rest is over.
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                running -= 1
                lock.unlock()
                return
            }
            let pty = pending.removeFirst()
            let id = ObjectIdentifier(pty)
            queued.remove(id)
            busy[id] = (pty, false)
            lock.unlock()
            let started = DispatchTime.now().uptimeNanoseconds
            pty.warmScreen()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(elapsed * 9))) {
                self.lock.lock()
                let rested = self.busy.removeValue(forKey: id)
                self.lock.unlock()
                if let rested, rested.asked { self.request(rested.pty) }
            }
        }
    }
}
