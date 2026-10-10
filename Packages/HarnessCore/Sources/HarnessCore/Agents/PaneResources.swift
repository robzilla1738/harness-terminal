import Foundation

public struct ProcessResource: Codable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32
    public var generation: String
    public var executable: String?
    public var residentBytes: UInt64
    public var cpuPercent: Double?
    public init(pid: Int32, parentPID: Int32, generation: String, executable: String?, residentBytes: UInt64, cpuPercent: Double?) {
        self.pid = pid; self.parentPID = parentPID; self.generation = generation; self.executable = executable
        self.residentBytes = residentBytes; self.cpuPercent = cpuPercent
    }
}
public struct PaneResources: Codable, Sendable {
    public var surfaceID: String
    public var rootPID: Int32
    public var rootGeneration: String
    public var sampledAt: Date
    public var intervalSeconds: Double?
    public var processes: [ProcessResource]
    public var unavailableCount: Int
    public var residentBytes: UInt64 { processes.reduce(0) { $0 + $1.residentBytes } }
    public var cpuPercent: Double? {
        guard !processes.isEmpty, processes.allSatisfy({ $0.cpuPercent != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }
    public init(surfaceID: String, rootPID: Int32, rootGeneration: String, sampledAt: Date, intervalSeconds: Double?, processes: [ProcessResource], unavailableCount: Int) {
        self.surfaceID = surfaceID; self.rootPID = rootPID; self.rootGeneration = rootGeneration
        self.sampledAt = sampledAt; self.intervalSeconds = intervalSeconds; self.processes = processes; self.unavailableCount = unavailableCount
    }
}
