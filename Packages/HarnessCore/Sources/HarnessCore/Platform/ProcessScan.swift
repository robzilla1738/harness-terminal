#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Cross-platform process-tree primitives shared by the agent scanner (HarnessCore) and the PTY
/// layer (HarnessDaemonCore). Darwin uses libproc (`proc_listpids`/`proc_pidinfo`); Linux reads
/// `/proc`. Kept in one place so the two callers can't drift apart.
public enum ProcessScan {
    /// Positive kernel evidence of termination. kill(pid, 0) still succeeds for
    /// unreaped Linux zombies, including when a container PID 1 does not reap.
    /// Failure to read process state is never treated as termination.
    public static func isZombie(_ pid: Int32) -> Bool {
        #if os(Linux)
        guard pid > 0, let record = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = record.lastIndex(of: ")") else { return false }
        let state = record[record.index(after: close)...].split(whereSeparator: \.isWhitespace).first
        return state == "Z" || state == "X"
        #else
        return false
        #endif
    }
    /// PID reuse is distinguished by the kernel's process start identity.
    public static func generation(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")"),
              let boot = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8) else { return nil }
        let fields = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, UInt64(fields[19]) != nil else { return nil }
        return "\(boot.trimmingCharacters(in: .whitespacesAndNewlines)):\(pid):\(fields[19])"
        #endif
    }
    public static func workingDirectory(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { decodeBoundedCString($0, capacity: Int(MAXPATHLEN)) }
        }
        #else
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = readlink("/proc/\(pid)/cwd", &bytes, bytes.count)
        guard count > 0, count < bytes.count else { return nil }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
        #endif
    }
    /// Kernel directory identity also handles macOS firmlink spellings and
    /// alternate mounts; string prefixes alone can miss a live process's cwd.
    public static func directory(_ directory: String, isWithin root: String) -> Bool {
        var target = stat()
        guard stat(root, &target) == 0, target.st_mode & S_IFMT == S_IFDIR else { return false }
        var current = directory
        for _ in 0..<256 {
            var info = stat()
            if stat(current, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
        return false
    }
    /// Every live PID on the system.
    public static func livePIDs() -> [Int32] {
        #if canImport(Darwin)
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        let bufferCount = Int(count) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: bufferCount)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * bufferCount))
        let actual = Int(bytes) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(actual).filter { $0 > 0 }).map { Int32($0) }
        #else
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap { Int32($0) }.filter { $0 > 0 }
        #endif
    }

    /// The whole `pid → ppid` table in a single pass. Building this once per scan and reusing it
    /// across surfaces collapses the agent scan from O(surfaces × processes) syscalls to
    /// O(processes): one `livePIDs()` enumeration plus one `parentPID` lookup per PID — work that
    /// is identical for every surface within a tick, so doing it per-surface was pure waste.
    public static func parentMap() -> [Int32: Int32] {
        let pids = livePIDs()
        var parents: [Int32: Int32] = [:]
        parents.reserveCapacity(pids.count)
        for pid in pids { parents[pid] = parentPID(pid) }
        return parents
    }

    /// Parent PID of `pid`, or 0 when it can't be determined.
    public static func parentPID(_ pid: Int32) -> Int32 {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return 0 }
        return Int32(info.pbi_ppid)
        #else
        // /proc/<pid>/stat: "pid (comm) state ppid …"; comm can contain spaces/parens, so split
        // after the last ')'. ppid is the 2nd whitespace field after that (state, then ppid).
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return 0 }
        let fields = stat[stat.index(after: close)...]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let ppid = Int32(fields[1]) else { return 0 }
        return ppid
        #endif
    }
}
