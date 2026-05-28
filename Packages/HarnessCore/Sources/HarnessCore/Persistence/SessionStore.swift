import Foundation

/// @unchecked Sendable: all disk reads/writes and the debounce timer are confined to `queue`.
public final class SessionStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.robert.harness.session-store")
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5

    public init() {}

    public func load() -> SessionSnapshot {
        queue.sync {
            guard FileManager.default.fileExists(atPath: HarnessPaths.snapshotURL.path),
                  let data = try? Data(contentsOf: HarnessPaths.snapshotURL)
            else {
                return SessionSnapshot()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(SessionSnapshot.self, from: data) {
                return snapshot
            }
            if let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
                return snapshot
            }
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
