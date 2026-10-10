import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Process sampling is independent of terminal capture and the registry lock.
final class ProcessResourceService: @unchecked Sendable {
    private struct Observation { var generation: String, cpuSeconds: Double, at: UInt64 }
    private let queue = DispatchQueue(label: "com.harness.process-resources", qos: .utility)
    private var previous: [Int32: Observation] = [:]
    func sample(surfaceID: String, rootPID: Int32) throws -> PaneResources {
        try queue.sync {
            guard let rootGeneration = ProcessScan.generation(rootPID) else { throw ResourceError.unavailable }
            let parents = ProcessScan.parentMap(), pids = descendants(rootPID, parents: parents)
            guard pids.count <= 4096 else { throw ResourceError.limit }
            let now = DispatchTime.now().uptimeNanoseconds
            var records: [ProcessResource] = [], intervals: [Double] = [], unavailable = 0
            for pid in pids {
                guard let generation = ProcessScan.generation(pid), let usage = Self.read(pid), ProcessScan.generation(pid) == generation else { unavailable += 1; continue }
                let old = previous[pid], interval = old.map { Double(now - $0.at) / 1e9 }
                var cpu: Double?
                if let old, old.generation == generation, let interval, interval >= 0.05, usage.cpu >= old.cpuSeconds {
                    cpu = (usage.cpu - old.cpuSeconds) / interval * 100
                    intervals.append(interval)
                }
                previous[pid] = Observation(generation: generation, cpuSeconds: usage.cpu, at: now)
                records.append(ProcessResource(pid: pid, parentPID: parents[pid] ?? 0, generation: generation,
                    executable: DaemonOwnership.executablePath(pid: pid), residentBytes: usage.rss, cpuPercent: cpu))
            }
            previous = previous.filter { now >= $0.value.at && now - $0.value.at < 60 * 1_000_000_000 }
            if previous.count > 8192 {
                let retained = Set(previous.sorted { $0.value.at > $1.value.at }.prefix(8192).map(\.key))
                previous = previous.filter { retained.contains($0.key) }
            }
            guard ProcessScan.generation(rootPID) == rootGeneration else { throw ResourceError.changed }
            return PaneResources(surfaceID: surfaceID, rootPID: rootPID, rootGeneration: rootGeneration, sampledAt: .now,
                intervalSeconds: intervals.min(), processes: records, unavailableCount: unavailable)
        }
    }
    func terminate(rootPID: Int32, expectedGeneration: String) throws {
        try queue.sync {
            guard rootPID > 1, ProcessScan.generation(rootPID) == expectedGeneration else { throw ResourceError.changed }
            let parents = ProcessScan.parentMap(), pids = descendants(rootPID, parents: parents)
            guard pids.count <= 4096 else { throw ResourceError.limit }
            let identities = pids.compactMap { pid in ProcessScan.generation(pid).map { (pid, $0) } }
            // Validate every identity before the first signal. Signal deepest descendants
            // first; each signal rechecks PID generation to reject reuse.
            guard identities.count == pids.count, ProcessScan.generation(rootPID) == expectedGeneration else { throw ResourceError.changed }
            for (pid, generation) in identities.reversed() {
                guard ProcessScan.generation(pid) == generation else { throw ResourceError.changed }
                guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw ResourceError.signal }
            }
        }
    }
    private func descendants(_ root: Int32, parents: [Int32: Int32]) -> [Int32] {
        var result = [root], frontier = [root], seen: Set<Int32> = [root]
        let children = Dictionary(grouping: parents.keys, by: { parents[$0] ?? 0 })
        var index = 0
        while index < frontier.count {
            let pid = frontier[index]; index += 1
            for child in children[pid] ?? [] where seen.insert(child).inserted {
                result.append(child); frontier.append(child)
                if result.count > 4096 { return result }
            }
        }
        return result
    }
    private static func read(_ pid: Int32) -> (cpu: Double, rss: UInt64)? {
        #if os(macOS)
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size else { return nil }
        return (Double(info.pti_total_user + info.pti_total_system) / 1e9, info.pti_resident_size)
        #else
        guard let raw = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let closing = raw.lastIndex(of: ")") else { return nil }
        let fields = raw[raw.index(after: closing)...].split(separator: " ")
        guard fields.count > 21, let user = UInt64(fields[11]), let system = UInt64(fields[12]), let pages = UInt64(fields[21]) else { return nil }
        let ticks = sysconf(Int32(_SC_CLK_TCK)), pageSize = sysconf(Int32(_SC_PAGESIZE))
        guard ticks > 0, pageSize > 0 else { return nil }
        return (Double(user + system) / Double(ticks), pages * UInt64(pageSize))
        #endif
    }
}
private enum ResourceError: Error, LocalizedError {
    case unavailable, changed, limit, signal
    var errorDescription: String? {
        switch self {
        case .unavailable: "The shell's process identity is unavailable."
        case .changed: "Process identity changed; refresh resources before taking action."
        case .limit: "The process tree exceeds the resource sampling limit."
        case .signal: "A process could not be signaled; refresh to see the remaining tree."
        }
    }
}
