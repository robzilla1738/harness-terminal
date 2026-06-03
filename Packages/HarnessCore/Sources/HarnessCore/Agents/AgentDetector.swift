#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    nonisolated(unsafe) private static var lastOutputAt: [String: Date] = [:]
    private static let outputLock = NSLock()

    public static func registerRootPID(_ pid: Int32, forSurfaceKey key: String) {
        rootsLock.lock()
        surfaceRoots[key] = pid
        rootsLock.unlock()
    }

    public static func unregisterRootPID(forSurfaceKey key: String) {
        rootsLock.lock()
        surfaceRoots.removeValue(forKey: key)
        rootsLock.unlock()

        snapshotsLock.lock()
        lastSurfaceSnapshots.removeValue(forKey: key)
        snapshotsLock.unlock()

        hintsLock.lock()
        hints.removeValue(forKey: key)
        hintsLock.unlock()

        outputLock.lock()
        lastOutputAt.removeValue(forKey: key)
        outputLock.unlock()
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
        let now = Date()
        outputLock.lock()
        lastOutputAt[key] = now
        outputLock.unlock()

        snapshotsLock.lock()
        if var snap = lastSurfaceSnapshots[key] {
            snap.activity = .working
            snap.lastActivityAt = now
            lastSurfaceSnapshots[key] = snap
        }
        snapshotsLock.unlock()
    }

    /// How long after the last PTY output an agent still counts as `.working`. Deliberately
    /// generous: agents go quiet for long stretches mid-task (API first-token latency, extended
    /// thinking, silent tool runs), and a tight window made the working indicator drop out while
    /// Claude was merely thinking. The cost is a short working linger after the final answer —
    /// and hook-equipped agents cancel even that, because their stop hook marks the tab `waiting`
    /// (the UI treats a waiting tab as not-working regardless of this window).
    public static let workingWindow: TimeInterval = 15

    /// Run a scan of every surface's child process tree. The daemon calls this
    /// every ~1.5s. Returns the surfaces whose agent detection changed (so the
    /// caller can post a single batched IPC update).
    @discardableResult
    public static func scan(
        table: AgentTable = .default,
        workingWindow: TimeInterval = AgentDetector.workingWindow
    ) -> [String: AgentSnapshot?] {
        rootsLock.lock()
        let roots = surfaceRoots
        rootsLock.unlock()
        var changes: [String: AgentSnapshot?] = [:]
        for (key, rootPID) in roots {
            let detected = detect(pid: rootPID, table: table)
            outputLock.lock()
            let lastOutput = lastOutputAt[key]
            outputLock.unlock()

            snapshotsLock.lock()
            let prior = lastSurfaceSnapshots[key]
            var resolved = detected
            if var r = resolved {
                if let lastOutput, Date().timeIntervalSince(lastOutput) <= workingWindow {
                    r.activity = .working
                    r.lastActivityAt = lastOutput
                } else {
                    r.activity = .idle
                    if let prior,
                       prior.kind == r.kind,
                       prior.executable == r.executable,
                       prior.pid == r.pid
                    {
                        r.lastActivityAt = prior.lastActivityAt
                    }
                }
                resolved = r
            }
            if resolved != prior {
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
            // Match the resolved binary basename AND the name the process was invoked
            // as (argv[0]). Native installers symlink the launcher to a version-numbered
            // binary — e.g. ~/.local/bin/claude -> .../versions/2.1.152 — so proc_pidpath
            // resolves the "claude" name away and only argv[0] still carries it.
            var names: Set<String> = [(path as NSString).lastPathComponent.lowercased()]
            if let invoked = argv0Name(descendant) { names.insert(invoked) }
            for entry in table.entries where entry.matchesAny(names) {
                best = AgentSnapshot(
                    kind: entry.kind,
                    executable: path,
                    pid: descendant,
                    activity: .idle,
                    lastActivityAt: best?.lastActivityAt ?? .now
                )
            }
        }
        return best
    }

    private static func descendantPIDs(of pid: Int32) -> [Int32] {
        let allPIDs = ProcessScan.livePIDs()
        guard !allPIDs.isEmpty else { return [] }
        var parents: [Int32: Int32] = [:]
        for candidate in allPIDs {
            parents[candidate] = ProcessScan.parentPID(candidate)
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

    private static func pidPath(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(MAXPATHLEN))
        }
        guard length > 0 else { return nil }
        let prefix = buffer.prefix(Int(length))
        return String(decoding: prefix, as: UTF8.self)
        #else
        // /proc/<pid>/exe is a symlink to the running binary. readlink doesn't NUL-terminate, so
        // decode exactly the `len` bytes it wrote.
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard len > 0 else { return nil }
        return String(decoding: buffer[0 ..< len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    /// Lowercased basename of `pid`'s argv[0] (how it was invoked). Darwin: KERN_PROCARGS2. Linux:
    /// the first NUL-separated token of /proc/<pid>/cmdline. Catches launchers that exec a
    /// renamed/versioned binary.
    private static func argv0Name(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBufferPointer({ ptr -> Int32 in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        // Layout: int argc, exec_path\0, padding NULs, then argv[0]\0 argv[1]\0 ...
        var cursor = MemoryLayout<Int32>.size
        while cursor < size, buffer[cursor] != 0 { cursor += 1 } // skip exec_path
        while cursor < size, buffer[cursor] == 0 { cursor += 1 } // skip NUL padding
        let start = cursor
        while cursor < size, buffer[cursor] != 0 { cursor += 1 } // read argv[0]
        guard cursor > start else { return nil }
        let argv0 = String(decoding: buffer[start..<cursor], as: UTF8.self)
        return (argv0 as NSString).lastPathComponent.lowercased()
        #else
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              !data.isEmpty else { return nil }
        let first = data.prefix { $0 != 0 } // argv[0] up to the first NUL
        guard !first.isEmpty else { return nil }
        let argv0 = String(decoding: first, as: UTF8.self)
        return (argv0 as NSString).lastPathComponent.lowercased()
        #endif
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

    /// True if any of `names` (e.g. resolved binary basename + argv[0] name) matches.
    public func matchesAny(_ names: Set<String>) -> Bool {
        executables.contains { names.contains($0) }
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
        AgentTableEntry(kind: .grok, executables: ["grok", "grok-build", "grok-cli"]),
        AgentTableEntry(kind: .pi, executables: ["pi", "pi-cli"]),
        AgentTableEntry(kind: .hermes, executables: ["hermes"]),
        AgentTableEntry(kind: .openClaw, executables: ["openclaw", "openclaude"]),
        AgentTableEntry(kind: .openCode, executables: ["opencode"]),
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
