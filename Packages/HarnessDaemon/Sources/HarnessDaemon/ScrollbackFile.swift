import Foundation
import HarnessCore

/// Disk persistence for a surface's raw PTY output, so scrollback survives a daemon
/// restart or crash and a reattach replays history instead of a blank screen.
///
/// The daemon owns each shell via `forkpty`; when the daemon dies the master fd dies
/// with it and the orphaned shell can't be reacquired on restart — the new daemon
/// respawns a fresh shell per persisted surface. Without this, the replayed scrollback
/// would be empty. We mirror what the in-memory ring keeps (`RealPty`'s `scrollbackBytes`
/// cap) onto disk so the reattach after restart shows the same tail the user last saw.
///
/// Format: a flat append log of the raw output bytes — the same philosophy as the binary
/// IPC frames (no JSON/base64). A torn tail from a crash mid-write just decodes lossily,
/// exactly as the in-memory ring already tolerates (`String(decoding:as:UTF8.self)`).
///
/// Append is debounced off the PTY read hot path (the `SessionStore` pattern); the file is
/// compacted to the retention cap once it grows to a high-water mark, the disk analog of the
/// ring's head-index eviction. @unchecked Sendable: all disk state is confined to `queue`.
final class ScrollbackFile: @unchecked Sendable {
    static let minimumRetentionCap = 64 * 1024

    private let url: URL
    /// Retain roughly this many bytes on disk — sized to the surface's in-memory ring cap so
    /// "what survives a restart" matches "what was on screen".
    private let retentionCap: Int
    /// Let the log grow to 2× the cap before compacting, so compaction (a read + atomic rewrite)
    /// is amortized rather than firing on nearly every flush under a sustained output flood.
    private var highWater: Int { max(retentionCap * 2, retentionCap + 64 * 1024) }

    private let queue = DispatchQueue(label: "com.robert.harness.scrollback-file")
    private let debounceInterval: TimeInterval = 0.5
    private var pending = Data()
    private var pendingFlush: DispatchWorkItem?
    /// Set once the surface is gone for good; stops a late debounced flush from resurrecting a file
    /// we just deleted.
    private var closed = false
    /// Current on-disk size, seeded from the existing file so compaction accounting survives a
    /// restart that loaded a pre-existing log.
    private var fileBytes: Int

    init(url: URL, retentionCap: Int) {
        self.url = url
        self.retentionCap = max(retentionCap, Self.minimumRetentionCap)
        self.fileBytes = Self.compactExistingLogIfNeeded(url: url, retentionCap: self.retentionCap)
    }

    /// Read the persisted tail (at most `maxBytes`) for seeding `RealPty`'s in-memory ring on
    /// startup. Returns the most recent bytes — the oldest are what the ring would have evicted.
    static func loadTail(url: URL, maxBytes: Int) -> Data {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return Data() }
        guard data.count > maxBytes else { return data }
        // `suffix` yields a slice whose indices are offset from the parent; wrap in `Data` so the
        // result is 0-indexed and safe to `subdata(in:)` against.
        return Data(data.suffix(maxBytes))
    }

    private static func compactExistingLogIfNeeded(url: URL, retentionCap: Int) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > retentionCap, let data = try? Data(contentsOf: url) else { return size }
        let tail = Data(data.suffix(retentionCap))
        guard HarnessPaths.atomicWrite(tail, to: url, label: "HarnessDaemon scrollback") else {
            return size
        }
        return tail.count
    }

    /// Queue a chunk of output for persistence. Cheap on the caller (the PTY read loop): append
    /// to the pending buffer and (re)arm the debounce. The actual disk write happens on `queue`.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.pending.append(data)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPending() }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Synchronously persist any buffered output. Called on graceful shutdown so the last
    /// debounce window isn't lost when the daemon exits.
    func flush() {
        queue.sync { self.flushPending() }
    }

    /// Drop all persisted history (used by `respawn(clearHistory: true)` — the user asked to
    /// start clean). The file may be written to again afterwards.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFlush?.cancel()
            self.pending.removeAll(keepingCapacity: true)
            try? FileManager.default.removeItem(at: self.url)
            self.fileBytes = 0
        }
    }

    /// Permanently delete the file and stop accepting writes — the surface is gone. Synchronous so
    /// the caller (surface teardown) knows no late debounced flush can resurrect the file.
    func delete() {
        queue.sync {
            self.closed = true
            self.pendingFlush?.cancel()
            self.pending.removeAll(keepingCapacity: false)
            try? FileManager.default.removeItem(at: self.url)
            self.fileBytes = 0
        }
    }

    // MARK: - queue-confined

    private func flushPending() {
        guard !closed, !pending.isEmpty else { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        guard appendToDisk(chunk) else { return }
        fileBytes += chunk.count
        if fileBytes > highWater { compact() }
    }

    private func appendToDisk(_ data: Data) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // First write: create the (owner-only) directory + file in one shot.
            try? HarnessPaths.ensureDirectories()
            return HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon scrollback")
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // Fall back to a full rewrite if we somehow can't open for append; better a slow
            // write than silently losing scrollback.
            return HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon scrollback")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            fputs("HarnessDaemon scrollback: append failed for \(url.lastPathComponent): \(error)\n", harnessStderr)
            return false
        }
    }

    /// Trim the log back to the retention cap by rewriting just its tail. Atomic (temp + rename)
    /// so a crash mid-compaction leaves the previous complete log intact.
    private func compact() {
        guard let data = try? Data(contentsOf: url), data.count > retentionCap else { return }
        let tail = data.suffix(retentionCap)
        if HarnessPaths.atomicWrite(Data(tail), to: url, label: "HarnessDaemon scrollback") {
            fileBytes = tail.count
        }
    }
}
