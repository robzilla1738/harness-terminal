#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    /// On-disk safety ceiling for "unlimited" scrollback (`scrollbackLines == 0`, surfaced as a
    /// `retentionCap` of `0`). The GUI emulator keeps a truly-unbounded line history, but the
    /// persisted log — and the daemon's in-memory replay ring sized from it — stays bounded here so
    /// a runaway producer can never fill the disk or OOM the session-authority daemon. 512 MiB of
    /// raw PTY output is far more replay history than any reattach needs.
    static let unlimitedSafetyCap = 512 * 1024 * 1024

    private let url: URL
    /// Retain roughly this many bytes on disk — sized to the surface's in-memory ring cap so
    /// "what survives a restart" matches "what was on screen".
    private let retentionCap: Int
    /// Let the log grow to 2× the cap before compacting, so compaction (a read + atomic rewrite)
    /// is amortized rather than firing on nearly every flush under a sustained output flood.
    private var highWater: Int { max(retentionCap * 2, retentionCap + 64 * 1024) }

    private let queue = DispatchQueue(label: "com.robert.harness.scrollback-file")
    private let debounceInterval: TimeInterval = 0.5
    /// Hard cap on the in-RAM `pending` buffer. A gapless output flood (`yes`, `cat bigfile`)
    /// re-arms the debounce faster than the 0.5s timer can ever fire, so without this `pending`
    /// would grow in proportion to total bytes produced — gigabytes for a sustained stream —
    /// and risk OOM-ing the session-authority daemon. Crossing this forces an immediate flush
    /// instead of another re-arm, bounding RAM to ~this size per surface regardless of duration.
    private let maxPendingBytes = 256 * 1024
    /// Longest the oldest buffered byte may wait before a forced flush, so a continuous trickle
    /// that never trips the size cap still reaches disk on a bounded schedule rather than being
    /// pushed indefinitely by re-arming.
    private let maxFlushDelay: TimeInterval = 2.0
    private var pending = Data()
    private var pendingFlush: DispatchWorkItem?
    /// Anchored at the first byte of the current batch; the debounce deadline is never pushed
    /// past this, giving the re-arming timer a hard ceiling (the `maxFlushDelay` max-wait).
    private var flushDeadline: DispatchTime?
    /// Set once the surface is gone for good; stops a late debounced flush from resurrecting a file
    /// we just deleted.
    private var closed = false
    /// `persist-scrollback off`: drop appends instead of writing them (queue-confined).
    private var suspended = false
    /// Current on-disk size, seeded from the existing file so compaction accounting survives a
    /// restart that loaded a pre-existing log.
    private var fileBytes: Int

    init(url: URL, retentionCap: Int) {
        self.url = url
        // `0` = unlimited: keep effectively all history, bounded only by the large on-disk safety
        // ceiling so the log can't grow without limit. Any other value gets the normal floor.
        self.retentionCap = retentionCap == 0
            ? Self.unlimitedSafetyCap
            : max(retentionCap, Self.minimumRetentionCap)
        self.fileBytes = Self.compactExistingLogIfNeeded(url: url, retentionCap: self.retentionCap)
        // Re-assert owner-only on a pre-existing log too, so files created by builds that
        // predate the permission tightening are fixed on the first load after an upgrade.
        Self.restrictToOwner(url)
    }

    /// `.scroll` logs hold raw PTY output — potentially echoed secrets — so they are
    /// owner-only (0600), making SECURITY-POSTURE.md's at-rest claim literal rather than
    /// relying on the 0700 parent directory alone. Re-applied after every creation path
    /// because atomic writes (temp + rename) mint a fresh inode with default (0644)
    /// permissions; in-place appends inherit whatever the file was created with.
    private static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            guard let self, !self.closed, !self.suspended else { return }
            self.pending.append(data)
            // Bound RAM under a sustained flood: once buffered output crosses the cap, flush
            // synchronously rather than re-arming the debounce (which a gapless stream would
            // otherwise never let fire). Normal bursts stay batched off the hot path.
            if self.pending.count >= self.maxPendingBytes {
                self.pendingFlush?.cancel()
                self.pendingFlush = nil
                self.flushPending()
            } else {
                self.scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        // Anchor the max-wait ceiling at the first byte of this batch, then never schedule
        // later than it — so a continuous trickle that keeps re-arming still flushes within
        // `maxFlushDelay` instead of being deferred forever.
        let ceiling = flushDeadline ?? (.now() + maxFlushDelay)
        flushDeadline = ceiling
        let deadline = min(DispatchTime.now() + debounceInterval, ceiling)
        let work = DispatchWorkItem { [weak self] in self?.flushPending() }
        pendingFlush = work
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    /// Persistence opt-out (`persist-scrollback off`): stop accepting writes AND wipe what
    /// is already on disk — the intent is "no scrollback at rest for this surface", so a
    /// half-measure that stops future writes but keeps the old log would be a lie.
    /// Synchronous (like `reset`/`delete`) so the caller knows the log is gone before the
    /// option set returns, and a previously-armed debounced flush can't resurrect it.
    /// Re-enabling resumes persistence from that point; output produced while suspended is
    /// memory-only by design.
    func setSuspended(_ suspended: Bool) {
        queue.sync {
            self.suspended = suspended
            guard suspended else { return }
            self.pendingFlush?.cancel()
            self.flushDeadline = nil
            self.pending.removeAll(keepingCapacity: false)
            try? FileManager.default.removeItem(at: self.url)
            self.fileBytes = 0
        }
    }

    /// Synchronously persist any buffered output. Called on graceful shutdown so the last
    /// debounce window isn't lost when the daemon exits.
    func flush() {
        queue.sync { self.flushPending() }
    }

    /// Drop all persisted history (used by `respawn(clearHistory: true)` and `clear-history` — the
    /// user asked to start clean). The file may be written to again afterwards. **Synchronous** (like
    /// `delete()`): the caller — `clear-history` / a respawn — must know the on-disk log is gone
    /// before it returns, so a daemon restart or a reattach that races the clear can't replay the
    /// stale scrollback, and a previously-armed debounced flush can't resurrect it.
    func reset() {
        queue.sync {
            self.pendingFlush?.cancel()
            self.flushDeadline = nil
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
        // The batch is being drained (or there's nothing to drain) — re-anchor the max-wait
        // window so the next byte starts a fresh ceiling.
        flushDeadline = nil
        guard !closed, !pending.isEmpty else { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        guard appendToDisk(chunk) else { return }
        fileBytes += chunk.count
        if fileBytes > highWater { compact() }
    }

    private func appendToDisk(_ data: Data) -> Bool {
        // Concurrency note: `appendToDisk` is only ever called from `flushPending()`, which
        // is only ever dispatched onto `queue` (the serial DispatchQueue this type owns).
        // All appends are therefore serialized — the seekToEnd + write pair below is NOT
        // racy (no other writer can interleave between the two calls). pwrite is not needed.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // First write: create the (owner-only) directory + file in one shot.
            try? HarnessPaths.ensureDirectories()
            guard HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon scrollback") else { return false }
            Self.restrictToOwner(url)
            return true
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // Fall back to a full rewrite if we somehow can't open for append. The rewrite
            // must include the existing log — writing just `data` would atomically replace
            // the entire history with the latest chunk. If the existing bytes can't be read
            // either, drop this flush (the chunk stays lost, but the on-disk log survives).
            guard let existing = try? Data(contentsOf: url) else {
                fputs("HarnessDaemon scrollback: append-open and read both failed for \(url.lastPathComponent); dropping flush\n", harnessStderr)
                return false
            }
            guard HarnessPaths.atomicWrite(existing + data, to: url, label: "HarnessDaemon scrollback") else { return false }
            Self.restrictToOwner(url)
            return true
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // fsync so the appended bytes reach stable storage before we return. Using
            // plain fsync (not F_FULLFSYNC) — the extra journal-barrier cost of F_FULLFSYNC
            // is disproportionate for scrollback: the goal is crash durability (surviving a
            // daemon kill), not power-loss durability (surviving an immediate power cut).
            // fdatasync on Glibc is equivalent to fsync for our use (we don't care about
            // metadata timestamps); fsync is available on both Darwin and Glibc.
            _ = fsync(handle.fileDescriptor)
            return true
        } catch {
            fputs("HarnessDaemon scrollback: append failed for \(url.lastPathComponent): \(error)\n", harnessStderr)
            return false
        }
    }

    /// Trim the log back to the retention cap by rewriting just its tail. Atomic (temp + rename)
    /// so a crash mid-compaction leaves the previous complete log intact. The temp file is
    /// fsynced before the rename so a crash during or immediately after compaction never leaves
    /// a zero-length or partial new file — if the rename didn't complete the old log survives,
    /// and if it did the new file is fully durable.
    private func compact() {
        guard let data = try? Data(contentsOf: url), data.count > retentionCap else { return }
        let tail = Data(data.suffix(retentionCap))
        // Write to a temp file alongside the log, fsync it, then rename atomically.
        // `HarnessPaths.atomicWrite` (Data.write(options: .atomic)) does the temp+rename
        // but does not fsync the temp before renaming, so a crash in the write window
        // could leave a renamed-in file with no durable content. Do it manually here.
        let tmp = url.appendingPathExtension("compact-tmp")
        do {
            try tail.write(to: tmp)
            // Owner-only BEFORE the rename, so the log is never visible with loose perms.
            Self.restrictToOwner(tmp)
            // fsync the temp file so its content is durable before we replace the log.
            // See the comment in appendToDisk for the fsync vs F_FULLFSYNC choice.
            if let tmpHandle = try? FileHandle(forReadingFrom: tmp) {
                _ = fsync(tmpHandle.fileDescriptor)
                try? tmpHandle.close()
            }
            // POSIX rename(2), not FileManager's replace APIs: it atomically replaces the
            // destination on both Darwin and Linux, while corelibs-foundation's replaceItemAt
            // can leave the original missing when it fails partway.
            guard rename(tmp.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            fileBytes = tail.count
        } catch {
            fputs("HarnessDaemon scrollback: compaction failed for \(url.lastPathComponent): \(error)\n", harnessStderr)
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
