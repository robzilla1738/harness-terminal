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
        queue.async { [weak self] in
            self?.scheduleSave(snapshot)
        }
    }

    public func saveImmediately(_ snapshot: SessionSnapshot) throws {
        try queue.sync {
            try writeSnapshot(snapshot)
        }
    }

    private func scheduleSave(_ snapshot: SessionSnapshot) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.writeSnapshot(snapshot)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeSnapshot(_ snapshot: SessionSnapshot) throws {
        try HarnessPaths.ensureDirectories()
        var copy = snapshot
        copy.savedAt = .now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        try data.write(to: HarnessPaths.snapshotURL, options: .atomic)
    }
}
