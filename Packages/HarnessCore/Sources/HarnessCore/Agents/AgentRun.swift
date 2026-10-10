import Foundation

public enum RunProcessState: String, Codable, Sendable { case running, exited, unknown }
public enum RunTurnState: String, Codable, Sendable { case idle, working, completed, failed, unknown }
public enum RunAttention: String, Codable, Sendable { case none, needsInput, needsApproval, error }
public enum ActivitySource: String, Codable, Sendable {
    case hook, osc, process, exit, transcript, launch
    public var authority: Int {
        switch self { case .exit: 4; case .hook, .osc, .launch: 3; case .transcript: 2; case .process: 1 }
    }
}
public struct AgentLaunchSpecification: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var profile: String
    public var environment: [String: String]?
    public init(executable: String, arguments: [String], directory: String, profile: String, environment: [String: String]? = nil) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.profile = profile
        self.environment = environment
    }
}
/// An execution has its own identity even when it resumes an existing conversation.
public struct AgentRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var surfaceID: String
    public var paneID: String?
    public var processGeneration: String
    public var pid: Int32?
    public var provider: AgentKind
    public var profile: String
    /// Nil until the profile is established by an authoritative provider hook.
    public var profileSource: ActivitySource?
    public var conversationID: String?
    public var parentRunID: UUID?
    public var launch: AgentLaunchSpecification?
    /// The execution's recorded directory; it is not every directory later visited by a tool.
    public var directory: String?
    public var directorySource: ActivitySource?
    public var repository: GitRepository?
    public var repositoryUnavailable: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var process: RunProcessState
    public var turn: RunTurnState
    public var attention: RunAttention
    public var observedAt: Date
    public var processObservedAt: Date?
    public var source: ActivitySource
    public var lastTurnID: String?
    public var message: String?
    public init(hostID: UUID, surfaceID: String, paneID: String? = nil, processGeneration: String,
                pid: Int32?, provider: AgentKind, profile: String = "default", at: Date = .now) {
        id = UUID(); self.hostID = hostID; self.surfaceID = surfaceID; self.paneID = paneID
        self.processGeneration = processGeneration; self.pid = pid; self.provider = provider; self.profile = profile
        startedAt = at; processObservedAt = at; process = .running; turn = .unknown; attention = .none; observedAt = at; source = .process
    }
}
public enum RunEventKind: String, Codable, Sendable {
    case sessionStarted, sessionEnded, turnStarted, turnCompleted, turnFailed, attention, permissionRequested, toolStarted, toolCompleted, subagentStarted, subagentCompleted, processObserved, processExited, usage, commandStarted, commandCompleted
}
public enum TerminalAnchorAvailability: String, Codable, Sendable { case retained, evicted, streamReplaced, terminalClosed, unavailable }
public struct RunEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var kind: RunEventKind
    public var source: ActivitySource
    public var at: Date
    public var providerEventID: String?
    public var conversationID: String?
    public var turnID: String?
    public var toolID: String?
    public var toolName: String?
    public var message: String?
    public var terminalSequence: UInt64?
    public var streamIdentity: String?
    /// Populated when querying live replay state, never assumed from a pane ID.
    public var anchorAvailability: TerminalAnchorAvailability?
    public var exitCode: Int32?
    public init(runID: UUID, kind: RunEventKind, source: ActivitySource, at: Date = .now,
                providerEventID: String? = nil, conversationID: String? = nil, turnID: String? = nil, toolID: String? = nil,
                toolName: String? = nil, message: String? = nil, terminalSequence: UInt64? = nil, streamIdentity: String? = nil, exitCode: Int32? = nil) {
        id = UUID(); self.runID = runID; self.kind = kind; self.source = source; self.at = at
        self.providerEventID = providerEventID; self.turnID = turnID; self.toolID = toolID
        self.conversationID = conversationID
        self.toolName = toolName; self.message = message; self.terminalSequence = terminalSequence; self.streamIdentity = streamIdentity; self.exitCode = exitCode
    }
    public func availability(stream: String?, firstSequence: UInt64?, endSequence: UInt64?, terminalPresent: Bool) -> TerminalAnchorAvailability {
        guard terminalSequence != nil, streamIdentity != nil else { return .unavailable }
        guard terminalPresent else { return .terminalClosed }
        guard let stream, let firstSequence, let endSequence else { return .unavailable }
        guard streamIdentity == stream else { return .streamReplaced }
        guard let sequence = terminalSequence, sequence >= firstSequence, sequence <= endSequence else { return .evicted }
        return .retained
    }
    /// Only documented provider identities deduplicate observations. Repeated messages
    /// without an identity remain distinct, including events inside the same second.
    public var deduplicationID: String? {
        let scope = conversationID ?? ""
        if let providerEventID { return "\(scope):event:\(providerEventID)" }
        if let toolID { return "\(scope):tool:\(turnID ?? ""):\(toolID):\(kind.rawValue)" }
        if let turnID, kind == .turnStarted || kind == .turnCompleted || kind == .turnFailed { return "\(scope):turn:\(turnID):\(kind.rawValue)" }
        return nil
    }
}
public enum AgentRunReducer {
    public static func apply(_ event: RunEvent, to run: inout AgentRun) {
        guard event.runID == run.id else { return }
        if event.kind == .processObserved, event.at >= (run.processObservedAt ?? .distantPast) {
            run.processObservedAt = event.at
            return
        }
        guard event.at >= run.observedAt else { return }
        if event.kind == .processExited {
            run.process = .exited; run.endedAt = event.at; run.processObservedAt = event.at
        } else {
            // Process polling establishes lifetime, but never rewrites a hook's current
            // turn or attention state merely because terminal output became quiet.
            if event.source.authority < run.source.authority { return }
            switch event.kind {
            case .sessionStarted: run.process = .running
            case .turnStarted: run.turn = .working; run.attention = .none
            case .turnCompleted: run.turn = .completed; run.attention = .none
            case .turnFailed: run.turn = .failed; run.attention = .error
            case .attention: run.attention = .needsInput
            case .permissionRequested: run.attention = .needsApproval
            default: return
            }
        }
        run.observedAt = event.at; run.source = event.source
        if let turnID = event.turnID { run.lastTurnID = turnID }
        if let message = event.message { run.message = String(message.prefix(4096)) }
    }
}
public struct RunPage: Codable, Sendable {
    public var runs: [AgentRun]
    public var nextOffset: Int?
    public var observedAt: Date
    public var historyUnavailable: String?
    public init(runs: [AgentRun], nextOffset: Int?, historyUnavailable: String? = nil) {
        self.runs = runs; self.nextOffset = nextOffset; observedAt = .now; self.historyUnavailable = historyUnavailable
    }
}
public struct UsageCounters: Codable, Equatable, Sendable {
    public var input: Int64?
    public var output: Int64?
    public var cachedInput: Int64?
    public var reasoning: Int64?
    public var cacheCreation: Int64?
    public init(input: Int64? = nil, output: Int64? = nil, cachedInput: Int64? = nil, reasoning: Int64? = nil, cacheCreation: Int64? = nil) {
        self.input = input; self.output = output; self.cachedInput = cachedInput; self.reasoning = reasoning; self.cacheCreation = cacheCreation
    }
}
