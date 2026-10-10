import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Append-oriented, bounded history. Every sensitive record is protected before any
/// file operation, including conversion and compaction temporary files. Resize records
/// are embedded with output, so a crash cannot separate bytes from their geometry.
final class ScrollbackFile: @unchecked Sendable {
    static let minimumRetentionCap = 64 * 1024
    static let unlimitedSafetyCap = ScrollbackBudget.unlimitedSafetyCapBytes
    private static let magic = Data("HARNSCR1".utf8)
    private static let headerBytes = 52
    private let url: URL
    private var activeProtection: HistoryProtection
    var protection: HistoryProtection { queue.sync { activeProtection } }
    private let queue = DispatchQueue(label: "com.harness.history.append")
    private let budget = ObservationBudget()
    private let overflowLock = NSLock()
    private var overflowReported = false
    private var retentionCap: Int
    private var pending = Data()
    private var size: ReplaySize?
    private var identifier = UUID().uuidString
    private var nextIndex: UInt64 = 1, position: UInt64 = 0
    private var closed = false, suspended = false
    private var pendingFlush: DispatchWorkItem?
    private var flushDeadline: Date?
    private var failure: String?
    private var memorySegments: [Segment] = []
    private var memoryBytes = 0
    private var memoryGap = false
    private var warning: String?
    var unavailableReason: String? { queue.sync { failure ?? activeProtection.unavailableReason ?? warning } }
    private var highWater: Int { max(retentionCap * 2, retentionCap + 64 * 1024) }

    init(url: URL, retentionCap: Int, protection: HistoryProtection = .system()) {
        self.url = url; self.activeProtection = protection
        self.retentionCap = Self.normalizedCap(retentionCap)
        guard protection.kind != .keyUnavailable else {
            // A locked key prevents conversion, not owner-only protection of the
            // existing original. Preserve its bytes until authenticated migration.
            if FileManager.default.fileExists(atPath: url.path) {
                do { let handle = try Self.readHandle(url); try handle.close() }
                catch { failure = "Existing history permissions could not be protected; conversion is pending and new output stays in bounded memory." }
            }
            return
        }
        do {
            removeAbandonedConversions()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let handle = try Self.readHandle(url); defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            if prefix != Self.magic {
                // Retain the original until encrypted staging has been authenticated.
                let tail = try Self.legacyTail(url: url, maxBytes: self.retentionCap)
                try replace(with: tail)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("sizes"))
            } else {
                let tail: Tail
                do { tail = try Self.protectedTail(url: url, maxBytes: self.retentionCap, protection: protection) }
                catch {
                    try Self.recoverInterruptedAppend(url: url, protection: protection)
                    tail = try Self.protectedTail(url: url, maxBytes: self.retentionCap, protection: protection)
                }
                identifier = tail.identifier; nextIndex = tail.lastIndex + 1; position = tail.logicalEnd
                size = tail.sizes.last
                if tail.logicalEnd > UInt64(self.retentionCap) { try replace(with: tail) }
            }
        } catch { failure = "History could not be authenticated or migrated; running output remains in bounded memory." }
    }
    private static func normalizedCap(_ bytes: Int) -> Int { bytes <= 0 ? unlimitedSafetyCap : min(max(bytes, minimumRetentionCap), unlimitedSafetyCap) }
    func setRetentionCap(_ bytes: Int) {
        queue.async { [self] in
            retentionCap = Self.normalizedCap(bytes)
            flushPending()
            if position > UInt64(highWater) { compact() }
        }
    }
    static func loadTail(url: URL, maxBytes: Int, protection: HistoryProtection = .system()) -> Data {
        guard protection.kind != .keyUnavailable, maxBytes > 0 else { return Data() }
        do { return try protectedTail(url: url, maxBytes: maxBytes, protection: protection).bytes }
        catch { return Data() }
    }
    var bufferedBytes: Int { queue.sync { memoryBytes } }
    var captureEnabled: Bool { queue.sync { !suspended && !closed } }
    func loadTail(maxBytes: Int) -> Data {
        queue.sync {
            if activeProtection.kind == .keyUnavailable {
                return memoryTail(maxBytes: maxBytes).bytes
            }
            return Self.loadTail(url: url, maxBytes: maxBytes, protection: activeProtection)
        }
    }
    func replaySizesForTail(maxBytes: Int) -> [ReplaySize] {
        queue.sync {
            guard failure == nil else { return [] }
            if activeProtection.kind == .keyUnavailable { return memoryTail(maxBytes: maxBytes).sizes }
            return (try? Self.protectedTail(url: url, maxBytes: maxBytes, protection: activeProtection).sizes) ?? []
        }
    }
    private func memoryTail(maxBytes: Int) -> Tail {
        var bytes = Data(), sizes: [ReplaySize] = []
        for segment in memorySegments {
            if let cols = segment.cols, let rows = segment.rows,
               sizes.last?.cols != cols || sizes.last?.rows != rows {
                sizes.append(ReplaySize(sequence: UInt64(bytes.count) + 1, cols: cols, rows: rows))
            }
            bytes.append(segment.bytes)
        }
        let drop = max(0, bytes.count - max(0, maxBytes))
        let base = sizes.last { $0.sequence <= UInt64(drop) + 1 }
        sizes = sizes.filter { $0.sequence > UInt64(drop) + 1 }.map { ReplaySize(sequence: $0.sequence - UInt64(drop), cols: $0.cols, rows: $0.rows) }
        if let base { sizes.insert(ReplaySize(sequence: 1, cols: base.cols, rows: base.rows), at: 0) }
        return Tail(bytes: Data(bytes.dropFirst(drop)), sizes: sizes, identifier: identifier, lastIndex: 0, logicalEnd: UInt64(bytes.count))
    }
    func recordSize(cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard !closed, !suspended, failure == nil else { return }
            guard size?.cols != cols || size?.rows != rows else { return }
            if activeProtection.kind == .keyUnavailable {
                size = ReplaySize(sequence: position, cols: cols, rows: rows)
                retainInMemory(Data(), size: size); return
            }
            flushPending()
            size = ReplaySize(sequence: position, cols: cols, rows: rows)
            do { try appendRecord(Data(), size: size) }
            catch { fail() }
        }
    }
    func append(_ data: Data, size: ReplaySize? = nil) {
        guard !data.isEmpty else { return }
        guard budget.reserve(data.count) else {
            overflowLock.lock()
            let report = !overflowReported; overflowReported = true
            overflowLock.unlock()
            if report { queue.async { [self] in failure = "History capture exceeded its bounded queue; live programs were preserved." } }
            return
        }
        queue.async { [self] in
            defer { budget.release(data.count) }
            guard !closed, !suspended, failure == nil else { return }
            if activeProtection.kind == .keyUnavailable { retainInMemory(data, size: size ?? self.size); return }
            if let size, self.size?.cols != size.cols || self.size?.rows != size.rows {
                flushPending(); self.size = size
            }
            pending.append(data)
            if pending.count >= 256 * 1024 { flushPending() }
            else { scheduleFlush() }
        }
    }
    private func retainInMemory(_ data: Data, size: ReplaySize?) {
        let cap = min(retentionCap, 32 << 20)
        let retained = Data(data.suffix(cap))
        if retained.count < data.count { memoryGap = true }
        memorySegments.append(Segment(position: 0, bytes: retained, cols: size?.cols, rows: size?.rows))
        memoryBytes += retained.count
        while memoryBytes > cap || memorySegments.count > 32768 {
            memoryBytes -= memorySegments.removeFirst().bytes.count; memoryGap = true
        }
    }
    /// Queue ordering keeps output received during recovery after the imported prefix.
    /// Only key-unavailable stores are resumed; corruption never authorizes replacement.
    func recover(protection next: HistoryProtection) throws {
        guard next.kind != .keyUnavailable else { throw HistoryProtectionError.keyUnavailable(next.unavailableReason ?? "History key is unavailable.") }
        try queue.sync {
            guard !closed else { throw HistoryProtectionError.keyUnavailable("This history store is closed.") }
            guard activeProtection.kind == .keyUnavailable else {
                if let failure { throw HistoryProtectionError.keyUnavailable(failure) }; return
            }
            let candidate = ScrollbackFile(url: url, retentionCap: retentionCap, protection: next)
            guard candidate.failure == nil else { throw HistoryProtectionError.corruptRecord }
            var tail = FileManager.default.fileExists(atPath: url.path)
                ? try Self.protectedTail(url: url, maxBytes: retentionCap, protection: next)
                : Tail(bytes: Data(), sizes: [], identifier: candidate.identifier, lastIndex: 0, logicalEnd: 0)
            if !suspended {
                for segment in memorySegments {
                    if let cols = segment.cols, let rows = segment.rows,
                       tail.sizes.last?.cols != cols || tail.sizes.last?.rows != rows {
                        tail.sizes.append(ReplaySize(sequence: UInt64(tail.bytes.count) + 1, cols: cols, rows: rows))
                    }
                    tail.bytes.append(segment.bytes)
                }
                // Compaction re-bases sequence/resize records and authenticates staging.
                if tail.bytes.count > retentionCap {
                    let drop = tail.bytes.count - retentionCap
                    let baseSize = tail.sizes.last { $0.sequence <= UInt64(drop) + 1 }
                    tail.bytes = Data(tail.bytes.dropFirst(drop))
                    tail.sizes = tail.sizes.filter { $0.sequence > UInt64(drop) + 1 }.map { ReplaySize(sequence: $0.sequence - UInt64(drop), cols: $0.cols, rows: $0.rows) }
                    if let baseSize { tail.sizes.insert(ReplaySize(sequence: 1, cols: baseSize.cols, rows: baseSize.rows), at: 0) }
                }
                try candidate.replace(with: tail)
            }
            activeProtection = next; identifier = candidate.identifier; nextIndex = candidate.nextIndex
            position = candidate.position; size = candidate.size; failure = nil
            if memoryGap { warning = "Some history was evicted while the key was unavailable; encrypted capture has resumed." }
            memorySegments.removeAll(); memoryBytes = 0
        }
    }
    private func scheduleFlush() {
        let now = Date(), deadline = flushDeadline ?? now.addingTimeInterval(2)
        flushDeadline = deadline
        pendingFlush?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPending() }
        pendingFlush = item
        queue.asyncAfter(deadline: .now() + max(0, min(0.5, deadline.timeIntervalSince(now))), execute: item)
    }
    func setSuspended(_ value: Bool) {
        queue.sync { suspended = value; if value { resetOnQueue() } }
    }
    func flush() { queue.sync { flushPending(); synchronize() } }
    func reset() { queue.sync { resetOnQueue() } }
    func delete() { queue.sync { closed = true; resetOnQueue() } }
    private func resetOnQueue() {
        pendingFlush?.cancel(); pendingFlush = nil; flushDeadline = nil; pending.removeAll()
        for path in [url, url.appendingPathExtension("sizes")] { try? FileManager.default.removeItem(at: path) }
        identifier = UUID().uuidString; nextIndex = 1; position = 0; size = nil; failure = nil
        memorySegments.removeAll(); memoryBytes = 0; memoryGap = false; warning = nil
    }
    private func flushPending() {
        pendingFlush?.cancel(); pendingFlush = nil; flushDeadline = nil
        guard !closed, !suspended, failure == nil, activeProtection.kind != .keyUnavailable, !pending.isEmpty else { return }
        let bytes = pending; pending = Data()
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 32 * 1024, bytes.count)
                try appendRecord(bytes.subdata(in: offset..<end), size: size); offset = end
            }
            if position > UInt64(highWater) { compact() }
            synchronize()
        } catch { fail() }
    }
    private func fail() { failure = "History storage is unavailable; captured output remains in bounded memory."; pending.removeAll() }
    private func synchronize() {
        guard failure == nil, activeProtection.kind != .keyUnavailable, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let handle = try Self.readHandle(url); defer { try? handle.close() }
            try handle.synchronize()
        } catch { fail() }
    }
    private func appendRecord(_ bytes: Data, size: ReplaySize?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0, let ownerHandle = try? Self.readHandle(url) {
            // readHandle validates the inode's owner and restores private permissions.
            try? ownerHandle.close()
            fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var information = stat()
        guard fstat(fd, &information) == 0, information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid() else { throw POSIXError(.EPERM) }
        guard fchmod(fd, 0o600) == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        if information.st_size == 0 { try handle.write(contentsOf: Self.header(identifier)) }
        let segment = Segment(position: position, bytes: bytes, cols: size?.cols, rows: size?.rows)
        try handle.write(contentsOf: frame(segment, index: nextIndex, identifier: identifier))
        nextIndex += 1; position += UInt64(bytes.count)
    }
    private func frame(_ segment: Segment, index: UInt64, identifier: String) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let sealed = try activeProtection.seal(encoder.encode(segment), identity: Self.identity(url, identifier), sequence: index)
        var frame = Data()
        let count = UInt32(sealed.count + 8)
        withUnsafeBytes(of: count.bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: index.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(sealed)
        withUnsafeBytes(of: count.bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }
    private func compact() {
        do { try replace(with: Self.protectedTail(url: url, maxBytes: retentionCap, protection: activeProtection)) }
        catch { fail() }
    }
    private func removeAbandonedConversions() {
        let prefix = ".\(url.lastPathComponent).convert-"
        guard let candidates = try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return }
        for candidate in candidates where candidate.lastPathComponent.hasPrefix(prefix) {
            guard UUID(uuidString: String(candidate.lastPathComponent.dropFirst(prefix.count))) != nil,
                  let handle = try? Self.readHandle(candidate) else { continue }
            defer { try? handle.close() }
            // Conversion stages contain ciphertext only. Authenticate completed stages;
            // incomplete stages still have the private, versioned file header.
            guard let header = try? Self.readExact(handle, count: Self.headerBytes), header.starts(with: Self.magic),
                  let identifier = String(data: header.subdata(in: 8..<44), encoding: .utf8), UUID(uuidString: identifier) != nil else { continue }
            var held = stat(), current = stat()
            guard fstat(handle.fileDescriptor, &held) == 0, lstat(candidate.path, &current) == 0,
                  held.st_ino == current.st_ino, held.st_dev == current.st_dev else { continue }
            _ = unlink(candidate.path)
        }
    }
    private func replace(with tail: Tail) throws {
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).convert-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let fresh = UUID().uuidString
        let fd = open(staged.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.header(fresh))
        var cursor = 0, index: UInt64 = 1
        var currentSize: ReplaySize?
        func writeUntil(_ target: Int) throws {
            while cursor < target {
                let end = min(cursor + 32 * 1024, target)
                let segment = Segment(position: UInt64(cursor), bytes: tail.bytes.subdata(in: cursor..<end), cols: currentSize?.cols, rows: currentSize?.rows)
                try handle.write(contentsOf: frame(segment, index: index, identifier: fresh)); index += 1; cursor = end
            }
        }
        for resize in tail.sizes {
            let target = min(Int(resize.sequence - 1), tail.bytes.count)
            try writeUntil(target); currentSize = resize
            try handle.write(contentsOf: frame(Segment(position: UInt64(cursor), bytes: Data(), cols: resize.cols, rows: resize.rows), index: index, identifier: fresh)); index += 1
        }
        try writeUntil(tail.bytes.count)
        try handle.synchronize(); try handle.close()
        let verified = try Self.protectedTail(url: staged, maxBytes: max(1, tail.bytes.count), protection: activeProtection, identityURL: url)
        guard verified.bytes == tail.bytes, verified.sizes == tail.sizes else { throw HistoryProtectionError.corruptRecord }
        guard rename(staged.path, url.path) == 0 else { throw POSIXError(.EIO) }
        identifier = fresh; nextIndex = index; position = UInt64(tail.bytes.count); size = currentSize
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
    private struct Segment: Codable { var position: UInt64; var bytes: Data; var cols: UInt16?; var rows: UInt16? }
    private struct Tail { var bytes: Data; var sizes: [ReplaySize]; var identifier: String; var lastIndex: UInt64; var logicalEnd: UInt64 }
    private static func header(_ identifier: String) -> Data {
        var data = magic + Data(identifier.utf8)
        withUnsafeBytes(of: UInt64(1).bigEndian) { data.append(contentsOf: $0) }
        return data
    }
    private static func identity(_ url: URL, _ identifier: String) -> String { "scrollback:\(url.lastPathComponent):\(identifier)" }
    private static func readHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var information = stat()
        guard fstat(fd, &information) == 0, information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid() else { close(fd); throw POSIXError(.EPERM) }
        guard fchmod(fd, 0o600) == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func readExact(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { throw HistoryProtectionError.corruptRecord }
            data.append(chunk)
        }
        return data
    }
    /// Only an incomplete final frame may be discarded. Authenticate the complete
    /// prefix first; malformed or unauthenticated complete records are never repaired.
    private static func recoverInterruptedAppend(url: URL, protection: HistoryProtection) throws {
        let handle = try readHandle(url); defer { try? handle.close() }
        let header = try readExact(handle, count: headerBytes)
        guard header.starts(with: magic),
              let identifier = String(data: header.subdata(in: 8..<44), encoding: .utf8),
              UUID(uuidString: identifier) != nil,
              header.suffix(8) == Data([0, 0, 0, 0, 0, 0, 0, 1]) else { throw HistoryProtectionError.corruptRecord }
        let end = try handle.seekToEnd()
        guard end <= UInt64(unlimitedSafetyCap * 2 + 16 * 1024 * 1024) else { throw HistoryProtectionError.corruptRecord }
        var cursor = UInt64(headerBytes), index: UInt64 = 1, position: UInt64 = 0
        while cursor < end {
            guard end - cursor >= 4 else { break }
            try handle.seek(toOffset: cursor)
            let length = try readExact(handle, count: 4).reduce(0) { $0 << 8 | Int($1) }
            guard (8...128 * 1024).contains(length) else { throw HistoryProtectionError.corruptRecord }
            guard end - cursor >= UInt64(length + 8) else { break }
            let record = try readExact(handle, count: length + 4)
            guard record.suffix(4).reduce(0, { $0 << 8 | Int($1) }) == length,
                  record.prefix(8).reduce(UInt64(0), { $0 << 8 | UInt64($1) }) == index else { throw HistoryProtectionError.corruptRecord }
            let plain = try protection.open(record.subdata(in: 8..<length), identity: identity(url, identifier), sequence: index)
            let segment = try PropertyListDecoder().decode(Segment.self, from: plain)
            guard segment.position == position, segment.bytes.count <= 32 * 1024,
                  (segment.cols == nil && segment.rows == nil) || (segment.cols != nil && segment.rows != nil && ReplaySize(sequence: 1, cols: segment.cols!, rows: segment.rows!).isValid) else { throw HistoryProtectionError.corruptRecord }
            position += UInt64(segment.bytes.count); index += 1; cursor += UInt64(length + 8)
        }
        guard cursor < end else { throw HistoryProtectionError.corruptRecord }
        let fd = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var original = stat(), writable = stat()
        guard fstat(handle.fileDescriptor, &original) == 0, fstat(fd, &writable) == 0,
              original.st_ino == writable.st_ino, original.st_dev == writable.st_dev,
              original.st_size == writable.st_size, writable.st_uid == getuid(),
              ftruncate(fd, off_t(cursor)) == 0, fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    private static func protectedTail(url: URL, maxBytes: Int, protection: HistoryProtection, identityURL: URL? = nil) throws -> Tail {
        let handle = try readHandle(url); defer { try? handle.close() }
        let header = try readExact(handle, count: headerBytes)
        guard header.starts(with: magic), header.suffix(8) == Data([0, 0, 0, 0, 0, 0, 0, 1]), let identifier = String(data: header.subdata(in: 8..<44), encoding: .utf8), UUID(uuidString: identifier) != nil else { throw HistoryProtectionError.corruptRecord }
        var offset = try handle.seekToEnd()
        guard offset >= UInt64(headerBytes) else { throw HistoryProtectionError.corruptRecord }
        var records: [(Segment, UInt64)] = [], retained = 0
        var lastIndex: UInt64 = 0, logicalEnd: UInt64 = 0, expectedIndex: UInt64?, expectedPosition: UInt64?
        while offset > UInt64(headerBytes), retained < max(1, maxBytes) {
            try handle.seek(toOffset: offset - 4)
            let length = try readExact(handle, count: 4).reduce(0) { $0 << 8 | Int($1) }
            guard (8...128 * 1024).contains(length), UInt64(length + 8) <= offset - UInt64(headerBytes) else { throw HistoryProtectionError.corruptRecord }
            let start = offset - UInt64(length + 8)
            try handle.seek(toOffset: start)
            let frame = try readExact(handle, count: length + 8)
            guard frame.prefix(4) == frame.suffix(4) else { throw HistoryProtectionError.corruptRecord }
            let index = frame[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard index > 0, expectedIndex == nil || index == expectedIndex else { throw HistoryProtectionError.corruptRecord }
            let plain = try protection.open(frame.subdata(in: 12..<(length + 4)), identity: identity(identityURL ?? url, identifier), sequence: index)
            let segment = try PropertyListDecoder().decode(Segment.self, from: plain)
            guard segment.bytes.count <= 32 * 1024,
                  segment.position <= UInt64.max - UInt64(segment.bytes.count),
                  expectedPosition == nil || segment.position + UInt64(segment.bytes.count) == expectedPosition,
                  (segment.cols == nil && segment.rows == nil) || (segment.cols != nil && segment.rows != nil && ReplaySize(sequence: 1, cols: segment.cols!, rows: segment.rows!).isValid) else { throw HistoryProtectionError.corruptRecord }
            if expectedIndex == nil { lastIndex = index; logicalEnd = segment.position + UInt64(segment.bytes.count) }
            expectedIndex = index - 1; expectedPosition = segment.position
            records.append((segment, index)); retained += segment.bytes.count; offset = start
        }
        if offset == UInt64(headerBytes), let expectedIndex, expectedIndex != 0 { throw HistoryProtectionError.corruptRecord }
        let startPosition = logicalEnd - UInt64(min(retained, max(0, maxBytes)))
        var bytes = Data(), sizes: [ReplaySize] = []
        for (segment, _) in records.reversed() {
            if let cols = segment.cols, let rows = segment.rows {
                let seq = max(segment.position, startPosition) - startPosition + 1
                if sizes.last?.cols != cols || sizes.last?.rows != rows {
                    if sizes.last?.sequence == seq { sizes.removeLast() }
                    sizes.append(ReplaySize(sequence: seq, cols: cols, rows: rows))
                }
            }
            let skip = startPosition > segment.position ? min(UInt64(segment.bytes.count), startPosition - segment.position) : 0
            bytes.append(segment.bytes.dropFirst(Int(skip)))
        }
        return Tail(bytes: bytes, sizes: sizes, identifier: identifier, lastIndex: lastIndex, logicalEnd: logicalEnd)
    }
    private static func legacyTail(url: URL, maxBytes: Int) throws -> Tail {
        let handle = try readHandle(url); defer { try? handle.close() }
        let end = try handle.seekToEnd(), count = min(end, UInt64(maxBytes)), start = end - count
        try handle.seek(toOffset: start)
        let bytes = count == 0 ? Data() : try readExact(handle, count: Int(count))
        struct LegacySizes: Decodable { var inode: UInt64; var bytes: Int; var sizes: [ReplaySize] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var sizes: [ReplaySize] = []
        if let data = try? Data(contentsOf: url.appendingPathExtension("sizes")), data.count <= 4 << 20,
           let index = try? JSONDecoder().decode(LegacySizes.self, from: data),
           index.inode == (attributes[.systemFileNumber] as? NSNumber)?.uint64Value, index.bytes <= end {
            let first = index.sizes.lastIndex { $0.sequence <= start } ?? 0
            sizes = index.sizes.dropFirst(first).map { ReplaySize(sequence: max($0.sequence, start) - start + 1, cols: $0.cols, rows: $0.rows) }
        }
        return Tail(bytes: bytes, sizes: ReplaySize.validated(sizes), identifier: UUID().uuidString, lastIndex: 0, logicalEnd: count)
    }
}
