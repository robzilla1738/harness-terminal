import Foundation

/// One JSON line on `harness-cli events`. `kind` is `session`, `pane`, or `agent`.
public struct ControlEvent: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String
    public var id: String
    public var detail: String

    public init(kind: String, name: String, id: String, detail: String) {
        self.kind = kind
        self.name = name
        self.id = id
        self.detail = detail
    }

    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ControlPlane {
    public static func events(snapshot: SessionSnapshot, agents: [AgentSessionSummary]) -> [ControlEvent] {
        var lines: [ControlEvent] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                lines.append(ControlEvent(
                    kind: "session",
                    name: session.name.isEmpty ? workspace.name : session.name,
                    id: session.id.uuidString,
                    detail: workspace.name
                ))
                for tab in session.tabs {
                    for leaf in tab.rootPane.allLeaves() {
                        lines.append(ControlEvent(
                            kind: "pane",
                            name: tab.title,
                            id: leaf.surfaceID.uuidString,
                            detail: tab.cwd
                        ))
                    }
                }
            }
        }
        for agent in agents {
            lines.append(ControlEvent(
                kind: "agent",
                name: agent.kind.rawValue,
                id: agent.surfaceID,
                detail: agent.waiting ? "waiting" : agent.activity.rawValue
            ))
        }
        return lines
    }

    public static func processJSON(pid: Int, executable: String) -> String {
        let escaped = executable
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"pid\":\(pid),\"executable\":\"\(escaped)\"}"
    }

    public static func contextJSON(pid: Int, executable: String, cwd: String) -> String {
        let escapedExec = executable
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"pid\":\(pid),\"executable\":\"\(escapedExec)\",\"cwd\":\"\(escapedCwd)\"}"
    }

    public struct SurfaceContext: Codable, Equatable, Sendable {
        public var pid: Int
        public var executable: String
        public var cwd: String

        public init(pid: Int, executable: String, cwd: String) {
            self.pid = pid
            self.executable = executable
            self.cwd = cwd
        }
    }

    /// Case-insensitive substring match over directory entries. The CLI uses this
    /// for both a local listing and the lines a remote `find` returns.
    public static func lookup(query: String, entries: [String]) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.lowercased().contains(needle) }
    }

    public static func localEntries(root: URL, limit: Int = 200) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            paths.append(url.path)
            if paths.count >= limit { break }
        }
        return paths
    }

    /// Copy bytes from `read` to `write`. Local files and an SSH peer both go
    /// through this function; only the closures change.
    public static func copy(
        from source: String,
        to destination: String,
        read: (String) throws -> Data,
        write: (String, Data) throws -> Void
    ) throws {
        let data = try read(source)
        try write(destination, data)
    }

    public static func localRead(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public static func localWrite(_ path: String, _ data: Data) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// `ssh` argv that lists files under `root` on the remote host.
    public static func sshFindArguments(target: String, extra: [String], root: String) -> [String] {
        ["ssh"] + extra + [target, "find \(shellQuote(root)) -print"]
    }

    /// `ssh` argv that prints a remote file. Extra args (port, identity, jump) come first.
    public static func sshReadArguments(target: String, extra: [String], path: String) -> [String] {
        ["ssh"] + extra + [target, "cat -- \(shellQuote(path))"]
    }

    /// `ssh` argv that writes stdin to a remote file.
    public static func sshWriteArguments(target: String, extra: [String], path: String) -> [String] {
        ["ssh"] + extra + [target, "cat > \(shellQuote(path))"]
    }

    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
