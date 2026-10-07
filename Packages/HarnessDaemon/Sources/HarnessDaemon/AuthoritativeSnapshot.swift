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

/// Visible screen handed to a client before scrollback. Internal. Not a
/// compatibility promise and not a published wire format.
struct ReadyFrame: Equatable, Sendable, Codable {
    var cols: Int
    var rows: Int
    var cursorRow: Int
    var cursorCol: Int
    var cursorVisible: Bool
    var alternateScreen: Bool
    var cursorKeysApplication: Bool
    var keypadApplication: Bool
    var lines: [String]
    var sequence: UInt64

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> ReadyFrame? {
        try? JSONDecoder().decode(ReadyFrame.self, from: data)
    }
}

enum AttachPiece: Equatable {
    case ready(ReadyFrame)
    case history(Data)
}

/// Ready frame first, then history newest-first. A client can paint `ready`
/// before it reads the rest.
enum AttachStream {
    static func pieces(frame: ReadyFrame, historyNewestFirst: [Data]) -> [AttachPiece] {
        [.ready(frame)] + historyNewestFirst.map { .history($0) }
    }
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
        try? created.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            fedThrough = last.sequence &+ UInt64(last.data.count)
        }
    }

    func frame() -> ReadyFrame? {
        guard let term else { return nil }
        let grid = term.readGrid()
        return ReadyFrame(
            cols: grid.cols,
            rows: grid.rows,
            cursorRow: grid.cursor.row,
            cursorCol: grid.cursor.col,
            cursorVisible: grid.cursor.visible,
            alternateScreen: term.isAlternateScreenActive,
            cursorKeysApplication: term.modes.cursorKeysApplication,
            keypadApplication: term.modes.keypadApplication,
            lines: Self.lines(grid),
            sequence: fedThrough
        )
    }

    func releaseGrid() {
        term = nil
    }

    private static func lines(_ grid: TerminalGridSnapshot) -> [String] {
        (0 ..< grid.rows).map { row in
            var line = ""
            var col = 0
            while col < grid.cols {
                guard let cell = grid.cell(row: row, col: col) else { break }
                if cell.width == .spacerTail {
                    col += 1
                    continue
                }
                line += cell.codepoint == 0 ? " " : cell.cluster
                col += 1
            }
            return line
        }
    }
}

/// A desynced client copies the authoritative screen. The other client is returned
/// untouched, and this function does not write the client's bytes anywhere.
enum DesyncReattach {
    static func apply(authoritative: ReadyFrame, to client: inout [String], other: [String]) -> [String] {
        client = authoritative.lines
        return other
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
