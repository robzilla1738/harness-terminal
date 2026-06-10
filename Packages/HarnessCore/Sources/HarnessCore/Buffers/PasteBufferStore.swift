import Foundation

/// Named paste-buffer storage. The daemon owns the canonical store so buffers
/// survive `Harness.app` quitting and so all attached clients see the same
/// set. Persisted to `buffers.json` and re-read on daemon start.
///
/// The store is bounded — the oldest buffer is evicted when the limit is hit —
/// to keep a runaway `set-buffer` loop from chewing disk. The default limit
/// is generous (50 buffers, 1 MB total) and configurable via `Configuration`.
public final class PasteBufferStore: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maxBuffers: Int
        public var maxTotalBytes: Int
        public init(maxBuffers: Int = 50, maxTotalBytes: Int = 1_048_576) {
            self.maxBuffers = maxBuffers
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public struct Buffer: Codable, Sendable, Equatable {
        public var name: String
        public var data: Data
        public var createdAt: Date
        public var preview: String { String(data: data.prefix(120), encoding: .utf8) ?? "" }
        public init(name: String, data: Data, createdAt: Date = Date()) {
            self.name = name
            self.data = data
            self.createdAt = createdAt
        }
    }

    private var buffers: [Buffer] = []
    private var nextAutoIndex: Int = 0
    private let lock = NSLock()
    private let configuration: Configuration
    private let url: URL
    // Debounced write — mirrors OptionStore/HookRegistry/EnvironmentStore. Rapid set-buffer calls
    // (e.g. a script filling multiple buffers) produce one disk write at the end of the burst.
    private let saveQueue = DispatchQueue(label: "com.robert.harness.paste-buffer-store-save")
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.15

    public init(url: URL = HarnessPaths.buffersURL, configuration: Configuration = Configuration()) {
        self.url = url
        self.configuration = configuration
        self.buffers = Self.loadFromDisk(at: url)
        // Initialize nextAutoIndex so we don't collide with restored auto names.
        for buffer in buffers where buffer.name.hasPrefix("buffer") {
            if let suffix = Int(buffer.name.dropFirst("buffer".count)) {
                nextAutoIndex = max(nextAutoIndex, suffix + 1)
            }
        }
    }

    public func list() -> [Buffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    public func get(_ name: String) -> Buffer? {
        lock.lock(); defer { lock.unlock() }
        return buffers.first { $0.name == name }
    }

    /// Latest buffer (most recently set). Used by `paste-buffer` with no name.
    public func mostRecent() -> Buffer? {
        lock.lock(); defer { lock.unlock() }
        return buffers.max(by: { $0.createdAt < $1.createdAt })
    }

    /// Insert or replace a buffer. Returns the final name (auto-generated when `name` is nil), or
    /// `nil` when the payload alone exceeds the total byte budget and is refused.
    @discardableResult
    public func set(_ data: Data, name: String? = nil) -> String? {
        lock.lock()
        // Refuse a single buffer larger than the whole byte budget. Inserting it would force the
        // byte-eviction loop to drop every other buffer AND then itself, leaving an empty store
        // persisted as `[]` (silent, irreversible loss) while still returning a name as if it
        // succeeded. Reject it: existing buffers are preserved and nothing is written.
        guard data.count <= configuration.maxTotalBytes else {
            lock.unlock()
            return nil
        }
        let final: String
        if let name { final = name } else { final = "buffer\(nextAutoIndex)"; nextAutoIndex += 1 }
        // Remove any same-named buffer and append, so the just-set buffer is always the NEWEST
        // entry. Eviction drops oldest-first, so a fresh set survives a byte-cap trim even when it
        // replaced an older buffer that sat at a lower (older) position.
        if let index = buffers.firstIndex(where: { $0.name == final }) {
            buffers.remove(at: index)
        }
        buffers.append(Buffer(name: final, data: data))
        evictIfNeeded()
        let toSave = buffers
        lock.unlock()
        save(toSave)
        return final
    }

    @discardableResult
    public func delete(_ name: String) -> Bool {
        lock.lock()
        guard let index = buffers.firstIndex(where: { $0.name == name }) else {
            lock.unlock()
            return false
        }
        buffers.remove(at: index)
        let toSave = buffers
        lock.unlock()
        save(toSave)
        return true
    }

    public func clear() {
        lock.lock()
        buffers.removeAll()
        let toSave = buffers
        lock.unlock()
        save(toSave)
    }

    private func evictIfNeeded() {
        // Drop oldest until under both caps.
        while buffers.count > configuration.maxBuffers {
            buffers.removeFirst()
        }
        var total = buffers.reduce(0) { $0 + $1.data.count }
        // Keep at least the newest buffer (set() appends it last): never let the byte cap empty the
        // store. set() already rejects a lone oversized buffer; this is the defense-in-depth floor.
        while total > configuration.maxTotalBytes, buffers.count > 1 {
            total -= buffers[0].data.count
            buffers.removeFirst()
        }
    }

    private static func loadFromDisk(at url: URL) -> [Buffer] {
        guard let data = try? Data(contentsOf: url) else { return [] } // absent → empty
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let buffers = try? decoder.decode([Buffer].self, from: data) else {
            // Present but unparseable: preserve it as `.corrupt` for recovery rather than
            // silently discarding the user's buffers (mirrors the other stores) — the next
            // save() would otherwise atomically overwrite the only copy.
            HarnessPaths.backupCorruptFile(at: url, label: "HarnessDaemon")
            return []
        }
        return buffers
    }

    private func save(_ snapshot: [Buffer]) {
        // Caller already holds the pre-snapshot under the lock and passes it in — no second
        // lock acquisition needed. Enqueue onto `saveQueue` so the mutation path never blocks
        // on I/O and bursts coalesce to one write.
        saveQueue.async { [weak self] in
            self?.scheduleSave(snapshot)
        }
    }

    /// Synchronously write the current buffers to disk, bypassing the debounce. Called on daemon
    /// shutdown so the last set-buffer in the debounce window is never lost.
    public func flush() {
        saveQueue.sync { [weak self] in
            guard let self else { return }
            pendingSave?.cancel()
            pendingSave = nil
            lock.lock()
            let snapshot = buffers
            lock.unlock()
            writeToDisk(snapshot)
        }
    }

    private func scheduleSave(_ snapshot: [Buffer]) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk(snapshot) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeToDisk(_ snapshot: [Buffer]) {
        // Failures are logged to stderr — not silently swallowed — matching every other store's
        // `HarnessPaths.atomicWrite` contract.
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            fputs("HarnessDaemon: failed to encode buffers.json\n", harnessStderr)
            return
        }
        HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon")
    }
}
