import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RecordingDocument: Sendable {
    public var events: [RecordingEvent]
    public var interrupted: Bool
    public var skippedLines: Int
    public var protection: String
    public var legacyGeometry = false
}
public enum RecordingArchiveError: Error, LocalizedError {
    case invalid, capacity, exists, writeFailed
    public var errorDescription: String? {
        switch self {
        case .invalid: "The recording has invalid framing, order, metadata or dimensions. Its source was preserved."
        case .capacity: "The recording exceeds the bounded event or byte limit. Start another recording."
        case .exists: "The recording path already exists or cannot be created safely. Choose a new output path."
        case .writeFailed: "Recording storage failed. The completed frames remain available; running programs are unaffected."
        }
    }
}

/// Framing is public; each event and the completion marker are authenticated with
/// the archive identity and exact frame order before any bytes reach disk.
public enum RecordingArchive {
    static let magic = Data("HARNREC1".utf8)
    public static let maximumBytes = 128 << 20
    public static let maximumEvents = 100_000
    static func identity(_ id: UUID) -> String { "recording:" + id.uuidString }
    static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
    static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    struct Frame: Codable { var event: RecordingEvent?; var completedCount: Int?; var legacyGeometry: Bool? }
    public static func read(_ url: URL, protection: HistoryProtection = .system()) throws -> RecordingDocument {
        guard let bytes = try PrivateFile.read(url, maximumBytes: maximumBytes) else { throw RecordingArchiveError.invalid }
        return try decode(bytes, protection: protection)
    }
    public static func decode(_ bytes: Data, protection: HistoryProtection) throws -> RecordingDocument {
        let bytes = Data(bytes)
        guard bytes.count <= maximumBytes else { throw RecordingArchiveError.capacity }
        if !bytes.starts(with: magic) {
            let decoded = TerminalRecordingCodec.decode(String(decoding: bytes, as: UTF8.self))
            try validate(decoded.events)
            return RecordingDocument(events: decoded.events, interrupted: decoded.skipped > 0, skippedLines: decoded.skipped, protection: "Legacy plaintext", legacyGeometry: true)
        }
        guard bytes.count >= 44, let text = String(data: bytes[8..<44], encoding: .utf8), let id = UUID(uuidString: text) else { throw RecordingArchiveError.invalid }
        var offset = 44, sequence: UInt64 = 0, events: [RecordingEvent] = [], completed = false, interrupted = false
        var plaintext: Bool?, legacyGeometry: Bool?
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { interrupted = true; break }
            let size = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }; offset += 4
            guard size > 0, size <= (2 << 20), !completed else { throw RecordingArchiveError.invalid }
            guard bytes.count - offset >= size else { interrupted = true; break }
            let record = Data(bytes[offset..<(offset + size)]), linuxPlain = record.starts(with: Data("HARNPLN1".utf8))
            if let plaintext, plaintext != linuxPlain { throw RecordingArchiveError.invalid }; plaintext = linuxPlain
            let plain = try linuxPlain ? HistoryProtection.openLinuxRecordForImport(record, identity: identity(id), sequence: sequence) : protection.open(record, identity: identity(id), sequence: sequence)
            let frame = try decoder().decode(Frame.self, from: plain)
            let imported = frame.legacyGeometry ?? false
            if let legacyGeometry, legacyGeometry != imported { throw RecordingArchiveError.invalid }; legacyGeometry = imported
            if let event = frame.event {
                guard frame.completedCount == nil, events.count < maximumEvents else { throw RecordingArchiveError.invalid }; events.append(event)
            } else if let count = frame.completedCount, count == events.count { completed = true }
            else { throw RecordingArchiveError.invalid }
            offset += size; sequence += 1
        }
        try validate(events)
        return RecordingDocument(events: events, interrupted: interrupted || !completed, skippedLines: 0, protection: plaintext == true ? "Owner-only Linux plaintext (not authenticated)" : "Keychain encrypted", legacyGeometry: legacyGeometry ?? false)
    }
    /// Explicit, interruption-safe conversion of a user-selected legacy file.
    /// Only an encrypted verified stage can replace the unchanged plaintext source.
    public static func protectLegacy(at url: URL, protection: HistoryProtection = .system()) throws {
        guard protection.kind == .keychainEncrypted else { throw HistoryProtectionError.encryptionUnavailable }
        guard let original = try PrivateFile.read(url, maximumBytes: maximumBytes) else { throw RecordingArchiveError.invalid }
        if original.starts(with: magic) { _ = try decode(original, protection: protection); return }
        let document = try decode(original, protection: protection)
        guard document.skippedLines == 0 else { throw RecordingArchiveError.invalid }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".recording-conversion-" + UUID().uuidString)
        defer { _ = unlink(stage.path) }
        let writer = try RecordingArchiveWriter(url: stage, protection: protection, legacyGeometry: true)
        for event in document.events { try writer.append(event) }; try writer.finish()
        let verified = try read(stage, protection: protection)
        guard !verified.interrupted, verified.events == document.events, let sealed = try PrivateFile.read(stage, maximumBytes: maximumBytes) else { throw RecordingArchiveError.invalid }
        _ = try PrivateFile.replace(url, data: sealed, expected: original, backup: false, maximumBytes: maximumBytes)
    }

    public static func validate(_ events: [RecordingEvent]) throws {
        guard events.count <= maximumEvents, case let .metadata(version, _, _) = events.first, version == TerminalRecordingCodec.formatVersion else { throw RecordingArchiveError.invalid }
        var last = 0
        for (index, event) in events.enumerated() {
            if case .metadata = event { guard index == 0 else { throw RecordingArchiveError.invalid }; continue }
            guard let time = event.timeMs, time >= last, time <= 30 * 86400 * 1000 else { throw RecordingArchiveError.invalid }; last = time
            switch event {
            case let .resize(_, rows, cols): guard ReplaySize(sequence: 0, cols: cols, rows: rows).isValid else { throw RecordingArchiveError.invalid }
            case let .output(_, data), let .input(_, data): guard data.count <= 1 << 20 else { throw RecordingArchiveError.capacity }
            case .metadata: break
            }
        }
    }
}

/// Owned streaming recorder. It creates a new owner-only file; never truncates an
/// existing recording and never substitutes plaintext for an unavailable key.
public final class RecordingArchiveWriter: @unchecked Sendable {
    private let lock = NSLock(), protection: HistoryProtection, id = UUID()
    private let handle: FileHandle
    private let legacyGeometry: Bool
    private var sequence: UInt64 = 0, bytesWritten = 44, count = 0, lastTime = 0
    private var closed = false, failed = false
    public init(url: URL, protection: HistoryProtection = .system(), legacyGeometry: Bool = false) throws {
        guard protection.kind != .keyUnavailable else { throw HistoryProtectionError.keyUnavailable(protection.unavailableReason ?? "The recording key is unavailable.") }
        self.protection = protection; self.legacyGeometry = legacyGeometry
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecordingArchiveError.exists }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: RecordingArchive.magic + Data(id.uuidString.utf8)) }
        catch { try? handle.close(); _ = unlink(url.path); throw error }
    }
    deinit { try? handle.close() }
    public func append(_ event: RecordingEvent) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !failed, count < RecordingArchive.maximumEvents else { throw RecordingArchiveError.capacity }
        if case let .metadata(version, _, _) = event { guard count == 0, version == TerminalRecordingCodec.formatVersion else { throw RecordingArchiveError.invalid } }
        else {
            guard count > 0, let time = event.timeMs, time >= lastTime, time <= 30 * 86400 * 1000 else { throw RecordingArchiveError.invalid }
            if case let .resize(_, rows, cols) = event, !ReplaySize(sequence: 0, cols: cols, rows: rows).isValid { throw RecordingArchiveError.invalid }
        }
        do { try writeFrame(RecordingArchive.Frame(event: event)); count += 1; lastTime = event.timeMs ?? lastTime }
        catch { failed = true; throw error }
    }
    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; defer { closed = true; try? handle.close() }
        guard !failed else { throw RecordingArchiveError.writeFailed }
        try writeFrame(RecordingArchive.Frame(completedCount: count)); try handle.synchronize()
    }
    private func writeFrame(_ frame: RecordingArchive.Frame) throws {
        var frame = frame; frame.legacyGeometry = legacyGeometry
        let plain = try RecordingArchive.encoder().encode(frame)
        guard plain.count <= (1536 << 10) else { throw RecordingArchiveError.capacity }
        let sealed = try protection.seal(plain, identity: RecordingArchive.identity(id), sequence: sequence)
        guard sealed.count <= 2 << 20, bytesWritten <= RecordingArchive.maximumBytes - sealed.count - 4 else { throw RecordingArchiveError.capacity }
        let size = UInt32(sealed.count).bigEndian
        let prefix = withUnsafeBytes(of: size) { Data($0) }
        try handle.write(contentsOf: prefix + sealed); sequence += 1; bytesWritten += sealed.count + 4
    }
}
