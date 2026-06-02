import Darwin
import Foundation
import HarnessCore

/// Live mapping of surface UUID → shell PID + current working directory.
///
/// Why this exists: the renderer only fires `terminalDidChangeWorkingDirectory`
/// when the shell emits OSC 7. Many shells (notably fish without explicit
/// integration) never do this, leaving the sidebar stuck on the launch cwd.
///
/// Industry-standard fix (used by iTerm2, Alacritty's hooks, Warp): poll the
/// shell process's actual cwd via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` every
/// 500ms. We discover each surface's shell PID by scanning the Harness app's
/// descendants and reading their `HARNESS_SURFACE` env var via `sysctl`.
@MainActor
final class SurfaceShellTracker {
    static let shared = SurfaceShellTracker()

    private var timer: DispatchSourceTimer?
    private var lastReportedCwd: [String: String] = [:]
    /// Set while a background scan is in flight so ticks don't pile up — a proc-tree walk on a
    /// loaded machine can exceed the 500ms interval, and stacking scans just wastes CPU.
    private var scanning = false
    /// Serial queue for the blocking `proc_listpids` / `sysctl(KERN_PROCARGS2)` / `proc_pidinfo`
    /// syscalls. Kept off the main thread: scanning every process on a busy machine can take
    /// many milliseconds, and doing it on `.main` every 500ms drops frames.
    private static let scanQueue = DispatchQueue(label: "com.robert.harness.shell-tracker")

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force a re-scan immediately (call after creating a new tab/surface so
    /// we don't wait up to 500ms for the first cwd to land).
    func bumpScan() {
        tick()
    }

    private func tick() {
        guard !scanning else { return }
        scanning = true
        Self.scanQueue.async { [weak self] in
            let cwds = Self.computeSurfaceCwds() // all blocking syscalls happen here, off-main
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    self.applyCwds(cwds)
                }
            }
        }
    }

    /// Apply a fresh surface→cwd scan on the main actor: forget dead surfaces and push every
    /// changed cwd to the coordinator. Pure dictionary work — no syscalls, so it's cheap.
    private func applyCwds(_ cwds: [String: String]) {
        let live = Set(cwds.keys)
        for surface in lastReportedCwd.keys where !live.contains(surface) {
            lastReportedCwd.removeValue(forKey: surface)
        }
        let coordinator = SessionCoordinator.shared
        for (surfaceID, cwd) in cwds where lastReportedCwd[surfaceID] != cwd {
            lastReportedCwd[surfaceID] = cwd
            guard let uuid = UUID(uuidString: surfaceID) else { continue }
            coordinator.surfaceShellTrackerDidUpdateCwd(uuid, cwd: cwd)
        }
    }

    // MARK: - Process introspection (pure syscalls; run off the main actor)

    /// Walk the app's process subtree, map each `HARNESS_SURFACE` to the deepest readable shell
    /// PID, and read that PID's cwd. Returns surface-id → cwd for every live surface.
    ///
    /// `HARNESS_SURFACE` propagates through `/usr/bin/login` → `/usr/bin/env` → the user's shell,
    /// so multiple PIDs in the chain carry the same surface ID. We want the *deepest* one: the
    /// outer wrappers are typically setuid `login` processes whose cwds macOS won't expose to a
    /// user-owned reader.
    private nonisolated static func computeSurfaceCwds() -> [String: String] {
        let tree = processTree(rootedAt: getpid())
        var candidates: [String: [(pid: pid_t, depth: Int)]] = [:]
        for entry in tree {
            guard let env = environment(of: entry.pid),
                  let surface = env["HARNESS_SURFACE"], !surface.isEmpty
            else { continue }
            candidates[surface, default: []].append((entry.pid, entry.depth))
        }
        var result: [String: String] = [:]
        for (surface, list) in candidates {
            let sorted = list.sorted { $0.depth > $1.depth }
            // Deepest PID that yields a readable cwd (skip wrappers we can't introspect).
            if let cwd = sorted.lazy.compactMap({ cwd(for: $0.pid) }).first {
                result[surface] = cwd
            }
        }
        return result
    }


    /// Returns every descendant of `root` along with its depth in the tree
    /// (root would be depth 0, immediate children depth 1, …). Used so we can
    /// prefer deeper PIDs when picking which process represents a surface.
    private nonisolated static func processTree(rootedAt root: pid_t) -> [(pid: pid_t, depth: Int)] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        let bufferCount = Int(count) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: bufferCount)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(MemoryLayout<pid_t>.size * bufferCount)
        )
        let actual = Int(bytes) / MemoryLayout<pid_t>.size
        let all = pids.prefix(actual).filter { $0 > 0 }

        var parents: [pid_t: pid_t] = [:]
        for pid in all { parents[pid] = parentPID(pid) }

        var result: [(pid: pid_t, depth: Int)] = []
        for candidate in all where candidate != root {
            var cursor = candidate
            var depth = 0
            while let parent = parents[cursor], parent != 0, depth < 32 {
                depth += 1
                if parent == root {
                    result.append((candidate, depth))
                    break
                }
                cursor = parent
            }
        }
        return result
    }

    private nonisolated static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    /// Read another process's working directory via `proc_pidinfo`.
    nonisolated static func cwd(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard bytes == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                decodeBoundedCString($0, capacity: Int(MAXPATHLEN))
            }
        }
    }

    /// Read another process's argv + envp via `sysctl(KERN_PROCARGS2)`.
    /// Returns the env dictionary (or `nil` on failure / permission denial).
    nonisolated static func environment(of pid: pid_t) -> [String: String]? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBufferPointer({ ptr -> Int32 in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        // KERN_PROCARGS2 layout:
        //   int argc
        //   exec_path\0
        //   argv[0]\0 argv[1]\0 ... argv[argc-1]\0
        //   envp[0]\0 envp[1]\0 ... \0
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argc: Int32 = buffer.withUnsafeBytes { rawPtr in
            rawPtr.load(as: Int32.self)
        }
        var cursor = MemoryLayout<Int32>.size

        // Skip the exec path (NUL-terminated) and any padding NULs.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        // Skip argc strings (the argv array).
        var skipped: Int32 = 0
        while skipped < argc, cursor < size {
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            cursor += 1
            skipped += 1
        }

        // Now we're at envp; each entry is "KEY=VALUE\0".
        var env: [String: String] = [:]
        while cursor < size {
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            if cursor == start { break }
            let slice = buffer[start..<cursor]
            if let entry = String(bytes: slice, encoding: .utf8),
               let eq = entry.firstIndex(of: "=")
            {
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                env[key] = value
            }
            cursor += 1
        }
        return env
    }
}
