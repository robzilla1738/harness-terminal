import Foundation

/// Session/global environment variables injected into each pane's shell on spawn
/// (and respawn) — the `set-environment`/`show-environment` surface. A pane
/// inherits the global map overlaid with its session's map, so a value set on a
/// session wins over the same key set globally.
///
/// Persisted to `environment.json` on every mutation, mirroring `OptionStore`.
public final class EnvironmentStore: @unchecked Sendable {
    private var global: [String: String] = [:]
    private var perSession: [String: [String: String]] = [:]  // sessionID → key → value
    private let url: URL
    private let lock = NSLock()

    private struct Persisted: Codable {
        var global: [String: String]
        var perSession: [String: [String: String]]
    }

    public init(url: URL? = nil) {
        self.url = url ?? HarnessPaths.applicationSupport.appendingPathComponent("environment.json")
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            global = decoded.global
            perSession = decoded.perSession
        }
    }

    /// Set (or, with `value == nil`, unset) a variable. `sessionID == nil` targets
    /// the global map (`set-environment -g`).
    public func set(_ value: String?, key: String, sessionID: String? = nil) {
        lock.lock()
        if let sessionID {
            var map = perSession[sessionID] ?? [:]
            if let value { map[key] = value } else { map.removeValue(forKey: key) }
            if map.isEmpty { perSession.removeValue(forKey: sessionID) } else { perSession[sessionID] = map }
        } else {
            if let value { global[key] = value } else { global.removeValue(forKey: key) }
        }
        lock.unlock()
        save()
    }

    /// Drop a session's entire map (called when a session is destroyed).
    public func clearSession(_ sessionID: String) {
        lock.lock()
        let had = perSession.removeValue(forKey: sessionID) != nil
        lock.unlock()
        if had { save() }
    }

    /// The environment a pane in `sessionID` should receive: global overlaid with
    /// the session's overrides.
    public func resolved(sessionID: String?) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var merged = global
        if let sessionID, let map = perSession[sessionID] {
            for (key, value) in map { merged[key] = value }
        }
        return merged
    }

    /// `show-environment` listing: global plus (optionally) a session's entries.
    public func entries(sessionID: String?) -> [(scope: String, key: String, value: String)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(String, String, String)] = global.sorted { $0.key < $1.key }.map { ("global", $0.key, $0.value) }
        if let sessionID, let map = perSession[sessionID] {
            out += map.sorted { $0.key < $1.key }.map { ("session", $0.key, $0.value) }
        }
        return out
    }

    private func save() {
        lock.lock()
        let snapshot = Persisted(global: global, perSession: perSession)
        lock.unlock()
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
