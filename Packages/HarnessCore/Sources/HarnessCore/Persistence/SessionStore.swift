import Foundation

/// @unchecked Sendable: all disk reads/writes and the debounce timer are confined to `queue`.
public final class SessionStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.robert.harness.session-store")
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5

    public init() {}

    public func load() -> SessionSnapshot {
        queue.sync {
            let url = HarnessPaths.snapshotURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else {
                return SessionSnapshot() // absent → fresh install
            }
            // We write ISO-8601 dates (`writeSnapshot`), so that decoder is the primary path. The
            // plain-decoder fallback exists ONLY for a hypothetical legacy layout.json that stored
            // `savedAt` as a numeric timestamp (the default deferred-to-date strategy): try it before
            // declaring the file corrupt so an old install never loses its sessions on upgrade.
            let isoDecoder = JSONDecoder()
            isoDecoder.dateDecodingStrategy = .iso8601
            if let snapshot = (try? isoDecoder.decode(SessionSnapshot.self, from: data))
                ?? (try? JSONDecoder().decode(SessionSnapshot.self, from: data))
            {
                return snapshot
            }
            // Present but unreadable: preserve it for recovery instead of silently starting
            // empty (which would discard every session on the next save).
            HarnessPaths.backupCorruptFile(at: url, label: "HarnessDaemon")
            return SessionSnapshot()
        }
    }

    public func save(_ snapshot: SessionSnapshot) {
        // Pin the destination NOW — pure path resolution, no disk I/O, so this is cheap to call on
        // a latency-sensitive path (e.g. under the daemon's registry lock). The debounced write
        // fires up to `debounceInterval` later; re-resolving `HarnessPaths` at THAT point would
        // honor a since-changed `HARNESS_HOME` (tests reset it in tearDown) and persist the layout
        // to the wrong tree. Capturing the URL here keeps the write targeted at the intended home.
        let url = HarnessPaths.snapshotURL
        queue.async { [weak self] in
            self?.scheduleSave(snapshot, to: url)
        }
    }

    public func saveImmediately(_ snapshot: SessionSnapshot) throws {
        try queue.sync {
            // Synchronous and env-authoritative — used at init (first write) and on graceful
            // shutdown (flush the last debounce window). `ensureDirectories` materializes the full
            // owner-only tree (sessions/scrollback/logs); `writeSnapshot` then writes the layout.
            try HarnessPaths.ensureDirectories()
            try writeSnapshot(snapshot, to: HarnessPaths.snapshotURL)
        }
    }

    private func scheduleSave(_ snapshot: SessionSnapshot, to url: URL) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.writeSnapshot(snapshot, to: url)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeSnapshot(_ snapshot: SessionSnapshot, to url: URL) throws {
        // Ensure the destination directory exists from the PINNED url (never re-reading
        // `HARNESS_HOME`, which a debounced write firing after a test's tearDown would otherwise
        // resolve to the real home). Owner-only, matching `HarnessPaths.ensureDirectories`.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var copy = snapshot
        copy.savedAt = .now
        let encoder = JSONEncoder()
        // Compact (not prettyPrinted) — layout.json is machine-written/read, not hand-edited, and
        // the encode runs on every mutation. `.sortedKeys` is kept for deterministic output (stable
        // diffs / reproducible writes).
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}
