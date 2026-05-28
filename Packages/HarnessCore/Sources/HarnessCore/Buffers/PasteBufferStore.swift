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

    /// Insert or replace a buffer. Returns the final name (auto-generated when
    /// `name` is nil).
    @discardableResult
    public func set(_ data: Data, name: String? = nil) -> String {
        lock.lock()
        let final: String
        if let name { final = name } else { final = "buffer\(nextAutoIndex)"; nextAutoIndex += 1 }
        if let index = buffers.firstIndex(where: { $0.name == final }) {
            buffers[index] = Buffer(name: final, data: data)
        } else {
            buffers.append(Buffer(name: final, data: data))
        }
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
        while total > configuration.maxTotalBytes, let first = buffers.first {
            total -= first.data.count
            buffers.removeFirst()
        }
    }

    private static func loadFromDisk(at url: URL) -> [Buffer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Buffer].self, from: data)) ?? []
    }

    private func save(_ snapshot: [Buffer]) {
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
