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
    /// What `scan` last reported as a change, per surface (guarded by `snapshotsLock`). Change
    /// detection diffs against this, not `lastSurfaceSnapshots`, because `recordActivity` flips
    /// that one to `.working` between scans and would otherwise hide the idle → working edge.
    nonisolated(unsafe) private static var publishedSnapshots: [String: AgentSnapshot] = [:]
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
        publishedSnapshots.removeValue(forKey: key)
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
    /// caller can post a single batched IPC update). `parents` lets the caller share
    /// one tick's `ProcessScan.parentMap()` with its other process walks.
    @discardableResult
    public static func scan(
        table: AgentTable = .default,
        workingWindow: TimeInterval = AgentDetector.workingWindow,
        parents: [Int32: Int32]? = nil
    ) -> [String: AgentSnapshot?] {
        rootsLock.lock()
        let roots = surfaceRoots
        rootsLock.unlock()
        // The `pid → ppid` map is identical for every surface this tick, so build it ONCE and
        // reuse it across all roots — collapsing the per-tick cost from O(surfaces × processes)
        // syscalls to O(processes). Previously each `detect` rebuilt the whole map from scratch.
        let parents = parents ?? ProcessScan.parentMap()
        var changes: [String: AgentSnapshot?] = [:]
        for (key, rootPID) in roots {
            let detected = detect(pid: rootPID, table: table, parents: parents)
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
            if !isSameState(resolved, publishedSnapshots[key]) {
                changes[key] = resolved
                publishedSnapshots[key] = resolved
            }
            lastSurfaceSnapshots[key] = resolved
            snapshotsLock.unlock()
        }
        return changes
    }

    /// Equal for change reporting. While an agent stays `.working`, `lastActivityAt` tracks the
    /// latest output and moves on nearly every scan; reporting that would commit a revision and
    /// push a full snapshot to every client each ~1.5s of steady streaming. Activity transitions
    /// (and the timestamp they carry) still compare exactly, so they report immediately.
    private static func isSameState(_ lhs: AgentSnapshot?, _ rhs: AgentSnapshot?) -> Bool {
        guard var lhs, let rhs else { return lhs == nil && rhs == nil }
        if lhs.activity == .working, rhs.activity == .working { lhs.lastActivityAt = rhs.lastActivityAt }
        return lhs == rhs
    }

    /// Walks descendants of `pid` looking for a process whose resolved binary,
    /// argv[0], or wrapper-launched executable matches any agent in `table`.
    /// Returns the deepest match so a real child agent wins over its shell.
    public static func detect(pid: Int32, table: AgentTable) -> AgentSnapshot? {
        // On-demand single-surface path: build a private map. The per-tick `scan()` uses the
        // map-sharing overload below so it doesn't rebuild once per surface.
        detect(pid: pid, table: table, parents: ProcessScan.parentMap())
    }

    /// As `detect(pid:table:)` but against a precomputed `pid → ppid` map, so a multi-surface
    /// scan can build the (per-tick invariant) map once and share it across every root.
    public static func detect(pid: Int32, table: AgentTable, parents: [Int32: Int32]) -> AgentSnapshot? {
        var best: AgentSnapshot?
        for descendant in descendantPIDs(of: pid, parents: parents) {
            guard let path = pidPath(descendant) else { continue }
            let arguments = processArguments(descendant) ?? []
            for entry in table.entries where entry.matchesProcess(resolvedExecutable: path, arguments: arguments) {
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

    private static func descendantPIDs(of pid: Int32, parents: [Int32: Int32]) -> [Int32] {
        guard !parents.isEmpty else { return [] }
        var result: [Int32] = []
        for candidate in parents.keys where candidate != pid {
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

    public static func ancestorAgent(pid: Int32, root: Int32, provider: AgentKind,
                                     table: AgentTable, parents: [Int32: Int32], allowRoot: Bool = false) -> Int32? {
        var cursor = pid
        for _ in 0..<64 {
            guard cursor > 0, cursor != root || allowRoot else { return nil }
            if let path = pidPath(cursor), let arguments = processArguments(cursor),
               table.entries.contains(where: { $0.kind == provider && $0.matchesProcess(resolvedExecutable: path, arguments: arguments) }) { return cursor }
            guard cursor != root, let parent = parents[cursor], parent != cursor else { return nil }; cursor = parent
        }
        return nil
    }
    public static func launchSpecification(pid: Int32, provider: AgentKind, generation: String,
                                           directory: String, profile: String, environment: [String: String]) -> AgentLaunchSpecification? {
        guard ProcessScan.generation(pid) == generation, let executable = pidPath(pid), let arguments = processArguments(pid),
              ProcessScan.generation(pid) == generation else { return nil }
        return AgentResume.launch(executable: executable, arguments: arguments, provider: provider,
            directory: directory, profile: profile, environment: environment)
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
        let len = buffer.withUnsafeMutableBufferPointer { bytes in
            readlink("/proc/\(pid)/exe", bytes.baseAddress!, bytes.count - 1)
        }
        guard len > 0 else { return nil }
        return String(decoding: buffer[0 ..< len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    /// Full argv for `pid`, preserving argv[0] as invoked. Darwin exposes this
    /// via KERN_PROCARGS2 after `exec_path`; Linux uses `/proc/<pid>/cmdline`.
    /// The parser is argc-bounded on Darwin so environment bytes after argv are
    /// never interpreted as command arguments.
    private static func processArguments(_ pid: Int32) -> [String]? {
        #if canImport(Darwin)
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 1 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBufferPointer({ ptr -> Int32 in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        let argc: Int32 = buffer.withUnsafeBytes { rawPtr in
            rawPtr.loadUnaligned(as: Int32.self)
        }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size, buffer[cursor] != 0 { cursor += 1 } // skip exec_path
        while cursor < size, buffer[cursor] == 0 { cursor += 1 } // skip NUL padding
        var args: [String] = []
        var read: Int32 = 0
        while read < argc, cursor < size {
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            if cursor > start {
                args.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
            }
            cursor += 1
            read += 1
        }
        return args.isEmpty ? nil : args
        #else
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              !data.isEmpty else { return nil }
        let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return args.isEmpty ? nil : args
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

    public func matchesProcess(resolvedExecutable: String, arguments: [String]) -> Bool {
        matchesAny(Self.matchableProcessNames(resolvedExecutable: resolvedExecutable, arguments: arguments))
    }

    /// Builds every basename that can identify a process as an agent: resolved
    /// executable, argv[0], and the launcher target when argv0/resolved is a
    /// known wrapper. Non-wrapper commands do not scan arbitrary arguments, so
    /// `vim hermes-notes.txt` cannot become a false Hermes match. `env` gets
    /// one nested-wrapper pass (`env FOO=1 python3 hermes --tui`) to cover the
    /// common env→runtime shape without turning this into an unbounded parser.
    private static func matchableProcessNames(resolvedExecutable: String, arguments: [String]) -> Set<String> {
        var names: Set<String> = []
        insertProcessName(resolvedExecutable, into: &names)
        let invokedName: String?
        if let invoked = arguments.first {
            insertProcessName(invoked, into: &names)
            invokedName = processName(invoked)
        } else {
            invokedName = nil
        }

        let resolvedName = processName(resolvedExecutable)
        if let wrapperName = [invokedName, resolvedName].compactMap({ $0 }).first(where: isWrapperExecutable),
           let launchSearchStart = launchArgumentSearchStart(arguments: arguments, wrapperName: wrapperName),
           let launchIndex = firstLaunchArgumentIndex(in: arguments, startIndex: launchSearchStart, wrapperName: wrapperName)
        {
            insertLaunchTarget(arguments[launchIndex], into: &names)
            if wrapperName == "env",
               let nestedName = processName(arguments[launchIndex]),
               isWrapperExecutable(nestedName),
               let nestedIndex = firstLaunchArgumentIndex(in: arguments, startIndex: launchIndex + 1, wrapperName: nestedName)
            {
                insertLaunchTarget(arguments[nestedIndex], into: &names)
            }
        }

        return names
    }

    /// Match only published package entry points, not arbitrary package files or
    /// user arguments. Node resolves npm symlinks before exposing its argv.
    private static let packageEntrypoints: [String: String] = [
        "@github/copilot/npm-loader.js": "copilot",
        "@github/copilot/index.js": "copilot",
        "@qwen-code/qwen-code/cli-entry.js": "qwen",
        "@qwen-code/qwen-code/dist/index.js": "qwen",
        "@augmentcode/auggie/augment.mjs": "auggie",
        "@moonshot-ai/kimi-code/dist/main.mjs": "kimi",
        "@google/gemini-cli/bundle/gemini.js": "gemini",
        "@google/gemini-cli/dist/index.js": "gemini",
        "@earendil-works/pi-coding-agent/dist/bundle/cli.js": "pi",
        "@mariozechner/pi-coding-agent/dist/cli.js": "pi",
        "@anthropic-ai/claude-code/cli.js": "claude",
        "@abacus-ai/cli/scripts/npm-wrapper/shim.cjs": "abacusai",
        "@minimax-ai/code/cli.js": "mcode",
        "codebuff/index.js": "codebuff",
        "command-code/dist/index.mjs": "command-code",
        "@tencent-ai/codebuddy-code/bin/codebuddy": "codebuddy",
        "@tencent-ai/codebuddy-code/bin/codebuddy-lowmem": "codebuddy",
        "@qoder-ai/qodercli/bundle/qoder-npm-dispatcher.cjs": "qoder",
        "@qoder-ai/qodercli/bundle/qodercli.js": "qoder",
    ]

    private static func insertLaunchTarget(_ raw: String, into names: inout Set<String>) {
        insertProcessName(raw, into: &names)
        for (suffix, executable) in packageEntrypoints where raw.hasSuffix("/node_modules/" + suffix) {
            names.insert(executable)
        }
    }

    /// Returns where wrapper-target scanning should begin. When argv[0] is the
    /// wrapper, scan after it; when only the resolved executable is the wrapper,
    /// argv[0] may be the launcher target name and must remain searchable.
    private static func launchArgumentSearchStart(arguments: [String], wrapperName: String) -> Int? {
        guard let argv0 = arguments.first else { return nil }
        return processName(argv0) == wrapperName ? 1 : 0
    }

    /// Finds the first argv element that represents the wrapper's launched
    /// executable, skipping known wrapper flags and their operands.
    private static func firstLaunchArgumentIndex(in arguments: [String], startIndex: Int, wrapperName: String) -> Int? {
        var index = startIndex
        while index < arguments.count {
            let argument = arguments[index]
            if shouldSkipLauncherSubcommand(argument, at: index, startIndex: startIndex, wrapperName: wrapperName) {
                index += 1
                continue
            }
            if wrapperName == "env", isEnvironmentAssignment(argument) {
                index += 1
                continue
            }
            if argument == "--" {
                let next = index + 1
                return next < arguments.count ? next : nil
            }
            if argument.hasPrefix("-") {
                switch optionBehavior(argument, wrapperName: wrapperName) {
                case .keepScanning:
                    index += 1
                case .skipValue:
                    index += 2
                case .matchValue:
                    let next = index + 1
                    return next < arguments.count ? next : nil
                case .stopScanning:
                    return nil
                }
                continue
            }
            return index
        }
        return nil
    }

    private static func shouldSkipLauncherSubcommand(_ argument: String, at index: Int, startIndex: Int, wrapperName: String) -> Bool {
        index == startIndex && ["bun", "deno"].contains(wrapperName) && argument == "run"
    }

    private enum WrapperOptionBehavior {
        case keepScanning
        case skipValue
        case matchValue
        case stopScanning
    }

    /// Classifies wrapper flags by how they affect executable discovery. `-c`
    /// and eval-style flags stop the scan because their next value is code, not
    /// an executable argv token; any spawned child is detected by the descendant
    /// process walk instead.
    private static func optionBehavior(_ option: String, wrapperName: String) -> WrapperOptionBehavior {
        if option.contains("=") { return .keepScanning }
        switch wrapperName {
        case "env":
            return ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"].contains(option) ? .skipValue : .keepScanning
        case "node", "bun", "deno":
            if ["-e", "--eval"].contains(option) { return .stopScanning }
            return ["-r", "--require", "--loader", "--import"].contains(option) ? .skipValue : .keepScanning
        case "bash", "sh", "zsh", "fish":
            if option == "-c" { return .stopScanning }
            return option == "-o" ? .skipValue : .keepScanning
        default:
            guard isPythonExecutable(wrapperName) else { return .keepScanning }
            if option == "-m" { return .matchValue }
            if option == "-c" { return .stopScanning }
            return ["-W", "-X"].contains(option) ? .skipValue : .keepScanning
        }
    }

    private static func isEnvironmentAssignment(_ argument: String) -> Bool {
        guard let equals = argument.firstIndex(of: "=") else { return false }
        return equals != argument.startIndex
    }

    private static func isWrapperExecutable(_ name: String) -> Bool {
        isPythonExecutable(name) || ["node", "deno", "bun", "bash", "sh", "zsh", "fish", "env", "tsx"].contains(name)
    }

    private static func isPythonExecutable(_ name: String) -> Bool {
        name == "python" || name == "python3" || name.hasPrefix("python3.")
    }

    private static func insertProcessName(_ raw: String, into names: inout Set<String>) {
        guard let name = processName(raw) else { return }
        names.insert(name)
        // Muse's official launcher execs a versioned native binary, replacing
        // argv[0]. Match its published release grammar, never a loose prefix.
        if name.hasPrefix("muse-bin-"),
           name.range(of: #"^muse-bin-[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            names.insert("muse")
        }
    }

    private static func processName(_ raw: String) -> String? {
        let name = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty || name == "." || name == "/" ? nil : name
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
        AgentTableEntry(kind: .copilot, executables: ["copilot"]),
        AgentTableEntry(kind: .cline, executables: ["cline"]),
        AgentTableEntry(kind: .kilo, executables: ["kilo", "kilocode"]),
        AgentTableEntry(kind: .qwen, executables: ["qwen"]),
        AgentTableEntry(kind: .amp, executables: ["amp"]),
        AgentTableEntry(kind: .droid, executables: ["droid"]),
        AgentTableEntry(kind: .crush, executables: ["crush"]),
        AgentTableEntry(kind: .kiro, executables: ["kiro", "kiro-cli", "kiro-cli-chat"]),
        AgentTableEntry(kind: .vibe, executables: ["vibe"]),
        AgentTableEntry(kind: .openhands, executables: ["openhands"]),
        AgentTableEntry(kind: .auggie, executables: ["auggie"]),
        AgentTableEntry(kind: .kimi, executables: ["kimi", "kimi-cli", "kimi-code"]),
        AgentTableEntry(kind: .devin, executables: ["devin"]),
        AgentTableEntry(kind: .codebuff, executables: ["codebuff", "cb"]),
        AgentTableEntry(kind: .commandCode, executables: ["command-code", "commandcode", "cmd", "cmdc"]),
        AgentTableEntry(kind: .qoder, executables: ["qoder", "qodercli"]),
        AgentTableEntry(kind: .coderabbit, executables: ["coderabbit", "cr"]),
        AgentTableEntry(kind: .bob, executables: ["bob"]),
        AgentTableEntry(kind: .muse, executables: ["muse"]),
        AgentTableEntry(kind: .antigravity, executables: ["agy"]),
        AgentTableEntry(kind: .junie, executables: ["junie"]),
        AgentTableEntry(kind: .codebuddy, executables: ["codebuddy", "codebuddy-code", "cbc", "codebuddy-lowmem"]),
        AgentTableEntry(kind: .oz, executables: ["oz", "oz-preview", "warp-cli"]),
        AgentTableEntry(kind: .abacus, executables: ["abacusai"]),
        AgentTableEntry(kind: .minimax, executables: ["mcode"]),
        AgentTableEntry(kind: .trae, executables: ["traecli"]),
    ])

    /// Last decoded `agents.json`, keyed by its modification date, so the ~1.5s scan
    /// re-reads and re-decodes the file only when it actually changes.
    nonisolated(unsafe) private static var cached: (modified: Date, table: AgentTable)?
    private static let cacheLock = NSLock()

    public static func loadFromDisk() -> AgentTable {
        let path = HarnessPaths.applicationSupport.appendingPathComponent("agents.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attributes[.modificationDate] as? Date
        else { return .default }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.modified == modified { return cached.table }
        let table = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(AgentTable.self, from: $0) } ?? .default
        cached = (modified, table)
        return table
    }
}
