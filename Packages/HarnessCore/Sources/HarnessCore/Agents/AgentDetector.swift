import Darwin
import Foundation

/// Runs in the daemon. Walks the descendant process tree of each pane's shell
/// to find a known agent CLI. Cheap (one `proc_listpids` + a few `proc_pidpath`
/// calls per surface, ~1.5s cadence). Configurable via `agents.json` so users
/// can teach it new tools without recompiling.
public enum AgentDetector {
    /// Process-table snapshot updated on each scan.
    nonisolated(unsafe) private static var lastSurfaceSnapshots: [String: AgentSnapshot] = [:]
    private static let snapshotsLock = NSLock()

    /// PID of the shell that owns each surface (set by the daemon when it
    /// spawns the PTY). We walk the PID tree starting here.
    nonisolated(unsafe) private static var surfaceRoots: [String: Int32] = [:]
    private static let rootsLock = NSLock()

    /// Manually inject a hint (used by harness-cli hooks that know which agent
    /// is starting). Hints take precedence over the proc-tree scan.
    nonisolated(unsafe) private static var hints: [String: AgentSnapshot] = [:]
    private static let hintsLock = NSLock()

    public static func registerRootPID(_ pid: Int32, forSurfaceKey key: String) {
        rootsLock.lock()
        surfaceRoots[key] = pid
        rootsLock.unlock()
    }

    public static func registerHint(_ snapshot: AgentSnapshot, forSurfaceKey key: String) {
        hintsLock.lock()
        hints[key] = snapshot
        hintsLock.unlock()
    }

    public static func snapshot(forSurfaceKey key: String) -> AgentSnapshot? {
        snapshotsLock.lock()
        let stored = lastSurfaceSnapshots[key]
        snapshotsLock.unlock()
        if let stored { return stored }
        hintsLock.lock()
        let hint = hints[key]
        hintsLock.unlock()
        return hint
    }

    public static func recordActivity(forSurfaceKey key: String) {
        snapshotsLock.lock()
        if var snap = lastSurfaceSnapshots[key] {
            snap.activity = .working
            snap.lastActivityAt = .now
            lastSurfaceSnapshots[key] = snap
        }
        snapshotsLock.unlock()
    }

    /// Run a scan of every surface's child process tree. The daemon calls this
    /// every ~1.5s. Returns the surfaces whose agent detection changed (so the
    /// caller can post a single batched IPC update).
    @discardableResult
    public static func scan(table: AgentTable = .default) -> [String: AgentSnapshot?] {
        rootsLock.lock()
        let roots = surfaceRoots
        rootsLock.unlock()
        var changes: [String: AgentSnapshot?] = [:]
        for (key, rootPID) in roots {
            let detected = detect(pid: rootPID, table: table)
            snapshotsLock.lock()
            let prior = lastSurfaceSnapshots[key]
            // Decay an old "working" state to "idle" after 3 seconds quiet.
            var resolved = detected
            if var r = resolved, r.activity == .working,
               Date().timeIntervalSince(r.lastActivityAt) > 3
            {
                r.activity = .idle
                resolved = r
            }
            if resolved?.kind != prior?.kind || resolved?.activity != prior?.activity {
                changes[key] = resolved
            }
            lastSurfaceSnapshots[key] = resolved
            snapshotsLock.unlock()
        }
        return changes
    }

    /// Walks descendants of `pid` looking for a process whose argv[0] matches
    /// any agent in `table`. Returns the deepest match (so a wrapper script
    /// like `bash -c "claude --foo"` resolves to `claude`).
    public static func detect(pid: Int32, table: AgentTable) -> AgentSnapshot? {
        var best: AgentSnapshot?
        for descendant in descendantPIDs(of: pid) {
            guard let path = pidPath(descendant) else { continue }
            let exe = (path as NSString).lastPathComponent.lowercased()
            for entry in table.entries {
                if entry.matches(executable: exe) {
                    best = AgentSnapshot(
                        kind: entry.kind,
                        executable: path,
                        pid: descendant,
                        activity: .idle,
                        lastActivityAt: best?.lastActivityAt ?? .now
                    )
                }
            }
        }
        return best
    }

    private static func descendantPIDs(of pid: Int32) -> [Int32] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        let bufferCount = Int(count) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: bufferCount)
        let bytesUsed = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(MemoryLayout<pid_t>.size * bufferCount)
        )
        let actual = Int(bytesUsed) / MemoryLayout<pid_t>.size
        let allPIDs = pids.prefix(actual).filter { $0 > 0 }

        var parents: [Int32: Int32] = [:]
        for candidate in allPIDs {
            parents[candidate] = parentPID(candidate)
        }
        var result: [Int32] = []
        for candidate in allPIDs where candidate != pid {
            var cursor: Int32 = candidate
            var depth = 0
            while let parent = parents[cursor], parent != 0, depth < 32 {
                if parent == pid {
                    result.append(candidate)
                    break
                }
                cursor = parent
                depth += 1
            }
        }
        return result
    }

    private static func parentPID(_ pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return 0 }
        return Int32(info.pbi_ppid)
    }

    private static func pidPath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(MAXPATHLEN))
        }
        guard length > 0 else { return nil }
        let prefix = buffer.prefix(Int(length))
        return String(decoding: prefix, as: UTF8.self)
    }
}

public struct AgentTableEntry: Codable, Sendable {
    public let kind: AgentKind
    public let executables: [String]

    public init(kind: AgentKind, executables: [String]) {
        self.kind = kind
        self.executables = executables.map { $0.lowercased() }
    }

    public func matches(executable: String) -> Bool {
        executables.contains(executable)
    }
}

public struct AgentTable: Codable, Sendable {
    public let entries: [AgentTableEntry]

    public init(entries: [AgentTableEntry]) {
        self.entries = entries
    }

    public static let `default` = AgentTable(entries: [
        AgentTableEntry(kind: .codex, executables: ["codex", "codex-cli"]),
        AgentTableEntry(kind: .claudeCode, executables: ["claude", "claude-code", "claude-cli"]),
        AgentTableEntry(kind: .cursor, executables: ["cursor-agent", "cursor", "cursor-cli"]),
        AgentTableEntry(kind: .pi, executables: ["pi", "pi-cli"]),
        AgentTableEntry(kind: .hermes, executables: ["hermes"]),
        AgentTableEntry(kind: .openClaw, executables: ["openclaw", "openclaude"]),
        AgentTableEntry(kind: .aider, executables: ["aider"]),
        AgentTableEntry(kind: .gemini, executables: ["gemini", "gemini-cli"]),
        AgentTableEntry(kind: .goose, executables: ["goose"]),
    ])

    public static func loadFromDisk() -> AgentTable {
        let path = HarnessPaths.applicationSupport.appendingPathComponent("agents.json")
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let table = try? JSONDecoder().decode(AgentTable.self, from: data)
        else { return .default }
        return table
    }
}
