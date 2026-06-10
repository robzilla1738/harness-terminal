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
