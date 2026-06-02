import Foundation

/// A remote machine running `HarnessDaemon`, reachable by forwarding its control socket over SSH.
public struct RemoteHost: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity = the user-chosen name (also the tunnel socket's basename).
    public var id: String { name }
    /// Display name / handle for the host (e.g. "devbox").
    public var name: String
    /// SSH destination, e.g. `user@host` or a `~/.ssh/config` host alias.
    public var sshTarget: String
    /// Path to `harness.sock` on the remote machine.
    public var remoteSocketPath: String
    /// Extra `ssh` arguments (e.g. `-p 2222`, `-i ~/.ssh/id_ed25519`, `-J jump`).
    public var sshArgs: [String]

    public init(name: String, sshTarget: String, remoteSocketPath: String, sshArgs: [String] = []) {
        self.name = name
        self.sshTarget = sshTarget
        self.remoteSocketPath = remoteSocketPath
        self.sshArgs = sshArgs
    }
}

/// Persists the list of remote hosts to `sessions/remote-hosts.json`. Small and read-rarely, so it
/// loads/saves the whole list synchronously (atomic write), reusing the shared path helpers — the
/// same corruption-preserving pattern as the other JSON stores.
public final class RemoteHostStore: @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func load() -> [RemoteHost] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    public func save(_ hosts: [RemoteHost]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveLocked(hosts)
    }

    /// Insert or replace a host by name. Returns the updated list. The load-modify-save runs under
    /// a single lock acquisition so concurrent upserts/removes can't lose each other's writes.
    @discardableResult
    public func upsert(_ host: RemoteHost) -> [RemoteHost] {
        lock.lock()
        defer { lock.unlock() }
        var hosts = loadLocked()
        if let idx = hosts.firstIndex(where: { $0.name == host.name }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        _ = saveLocked(hosts)
        return hosts
    }

    @discardableResult
    public func remove(name: String) -> [RemoteHost] {
        lock.lock()
        defer { lock.unlock() }
        var hosts = loadLocked()
        hosts.removeAll { $0.name == name }
        _ = saveLocked(hosts)
        return hosts
    }

    // MARK: - lock-held internals (caller holds `lock`)

    private func loadLocked() -> [RemoteHost] {
        let url = HarnessPaths.remoteHostsURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return [] }
        if let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            return hosts
        }
        HarnessPaths.backupCorruptFile(at: url, label: "RemoteHostStore")
        return []
    }

    private func saveLocked(_ hosts: [RemoteHost]) -> Bool {
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return false }
        return HarnessPaths.atomicWrite(data, to: HarnessPaths.remoteHostsURL, label: "RemoteHostStore")
    }

    public func host(named name: String) -> RemoteHost? {
        load().first { $0.name == name }
    }
}
