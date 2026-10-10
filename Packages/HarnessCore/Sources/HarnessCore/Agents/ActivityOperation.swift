import Foundation

public enum ActivityOperation: Codable, Sendable {
    case list(hostID: UUID?, surfaceID: String?, activeOnly: Bool, offset: Int, limit: Int, responseCapabilities: [String]? = nil)
    case session(hostID: UUID?, runID: UUID, offset: Int, limit: Int, responseCapabilities: [String]? = nil)
    case hook(HookReport)
    case power(PowerOperation)
    case notifications(NotificationOperation)
    case configure(ActivitySettings?)
    case hookPolicy(HookPolicyOperation)
    case aiSummaries(AISummaryOperation)
    case schedules(requestID: UUID, operation: ScheduleOperation)
    case fanout(requestID: UUID, operation: FanoutOperation)
    case worktrees(requestID: UUID, operation: WorktreeOperation)
    case resumePolicy(surfaceID: String, runID: UUID?, automatic: Bool)
    case resume(runID: UUID, surfaceID: String, freshShellIdentity: String?)
    case commandOutput(surfaceID: String, maximumBytes: Int)
    case explain(sourceSurfaceID: String, targetSurfaceID: String, targetRunID: UUID)
    case resources(surfaceID: String)
    case terminateTree(surfaceID: String, rootGeneration: String)
    case usage(from: Date, to: Date)
    case digest(from: Date, to: Date, surfaceID: String?, responseCapabilities: [String]? = nil)
    case repositoryDigest(requestID: UUID, from: Date, to: Date, offset: Int, limit: Int)
}
public struct AgentRunSession: Codable, Sendable {
    public var run: AgentRun
    public var events: [RunEvent]
    public var nextOffset: Int?
    public var historyUnavailable: String?
    public init(run: AgentRun, events: [RunEvent], nextOffset: Int?, historyUnavailable: String?) {
        self.run = run; self.events = events; self.nextOffset = nextOffset; self.historyUnavailable = historyUnavailable
    }
}
