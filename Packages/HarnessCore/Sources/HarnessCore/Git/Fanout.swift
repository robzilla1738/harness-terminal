import Foundation

public struct FanoutProvider: Codable, Equatable, Sendable {
    public var provider: AgentKind
    public var executable: String?
    public var profile: String
    public var providerHome: String?
    public init(provider: AgentKind, executable: String? = nil, profile: String = "default", providerHome: String? = nil) {
        self.provider = provider; self.executable = executable; self.profile = profile; self.providerHome = providerHome
    }
    private enum CodingKeys: String, CodingKey { case provider, executable, profile, providerHome }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(AgentKind.self, forKey: .provider)
        executable = try values.decodeIfPresent(String.self, forKey: .executable)
        profile = try values.decodeIfPresent(String.self, forKey: .profile) ?? "default"
        providerHome = try values.decodeIfPresent(String.self, forKey: .providerHome)
    }
    public func specification(directory: String, path: String) throws -> AgentLaunchSpecification {
        guard [.claudeCode, .codex, .cursor].contains(provider), !profile.isEmpty, profile.utf8.count <= 256,
              !profile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw FanoutError.invalid }
        let candidates: [String]
        if let executable { candidates = [executable] }
        else {
            let names = provider == .cursor ? ["agent", "cursor-agent"] : [provider.commandToken]
            candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.flatMap { directory in names.map { String(directory) + "/" + $0 } }
        }
        guard let executable = candidates.first(where: { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 && FileManager.default.isExecutableFile(atPath: $0) }) else { throw FanoutError.executable }
        var environment: [String: String] = [:]
        if let providerHome {
            guard provider != .cursor, providerHome.hasPrefix("/"), !providerHome.contains("\0"), providerHome.utf8.count <= 4096 else { throw FanoutError.invalid }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: providerHome, isDirectory: &directory), directory.boolValue else { throw FanoutError.invalid }
            environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = providerHome
        }
        let arguments: [String]
        switch provider {
        case .codex: arguments = ["exec", "--json", "-"]
        case .claudeCode: arguments = ["--print", "--output-format", "stream-json", "--verbose"]
        default: arguments = ["--print", "--output-format", "stream-json"]
        }
        return AgentLaunchSpecification(executable: executable, arguments: arguments, directory: directory, profile: profile, environment: environment)
    }
}
public enum FanoutParticipantState: String, Codable, Sendable {
    case prepared, creatingWorktree, launching, running, exited, failed, unknown, skipped
    public var terminal: Bool { [.exited, .failed, .skipped].contains(self) }
}
public struct TrackedTest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var surfaceID: String
    public var launch: AgentLaunchSpecification?
    public var acceptedAt: Date
    public var outcome: WorkloadOutcome?
    public var failure: String?
    public var detailExpired: Bool?
    public var launchRejected: Bool?
    public var mayBeRunning: Bool { launchRejected != true && outcome?.mayBeRunning != false }
    public init(id: UUID = UUID(), surfaceID: String = UUID().uuidString, launch: AgentLaunchSpecification) {
        self.id = id; self.surfaceID = surfaceID; self.launch = launch; acceptedAt = .now
    }
}
public struct FanoutParticipant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var surfaceID: String
    public var provider: FanoutProvider
    public var worktreeID: UUID?
    public var directory: String?
    public var launch: AgentLaunchSpecification?
    public var state: FanoutParticipantState
    public var outcome: WorkloadOutcome?
    public var failure: String?
    public var tests: [TrackedTest]
    public var cleanedUp: Bool
    public var cleanupInProgress: Bool?
    public var canCleanup: Bool { state.terminal || outcome?.processAbsentObservedAt != nil }
    public init(provider: FanoutProvider, managed: Bool) {
        id = UUID(); surfaceID = UUID().uuidString; self.provider = provider
        worktreeID = managed ? UUID() : nil; state = .prepared; tests = []; cleanedUp = false
    }
}
public struct FanoutGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var repository: GitRepository
    public var baseCommit: String
    public var workspaceID: UUID
    public var prompt: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var cancellationRequested: Bool
    public var captureDisabled: Bool
    public var participants: [FanoutParticipant]
    public init(id: UUID, hostID: UUID, repository: GitRepository, baseCommit: String, workspaceID: UUID, prompt: String, providers: [FanoutProvider], managed: Bool) {
        self.id = id; self.hostID = hostID; self.repository = repository; self.baseCommit = baseCommit; self.workspaceID = workspaceID; self.prompt = prompt
        createdAt = .now; updatedAt = createdAt; cancellationRequested = false; captureDisabled = false
        participants = providers.map { FanoutParticipant(provider: $0, managed: managed) }
    }
    public mutating func removeCapturedText() {
        prompt = nil; captureDisabled = true
        for index in participants.indices {
            participants[index].launch = nil; participants[index].provider.profile = "private"
            participants[index].provider.executable = nil; participants[index].provider.providerHome = nil
            participants[index].failure = nil
            for test in participants[index].tests.indices { participants[index].tests[test].launch = nil; participants[index].tests[test].failure = nil }
        }
    }
    public var isActive: Bool { finishedAt == nil || participants.contains { !$0.canCleanup || $0.tests.contains { $0.mayBeRunning } } }
}
public struct FanoutPage: Codable, Sendable {
    public var groups: [FanoutGroup]
    public var nextOffset: Int?
    public var historyUnavailable: String?
    public init(groups: [FanoutGroup], nextOffset: Int?, historyUnavailable: String?) { self.groups = groups; self.nextOffset = nextOffset; self.historyUnavailable = historyUnavailable }
}
public struct FanoutComparison: Codable, Sendable {
    public var group: FanoutGroup
    public var repositories: [String: WorktreeComparison]
    public var failures: [String: String]
    public init(group: FanoutGroup, repositories: [String: WorktreeComparison], failures: [String: String]) { self.group = group; self.repositories = repositories; self.failures = failures }
}
public enum FanoutOperation: Codable, Sendable {
    case start(id: UUID, directory: String, base: String?, workspaceID: UUID?, prompt: String, providers: [FanoutProvider], managedWorktrees: Bool)
    case list(offset: Int, limit: Int)
    case inspect(id: UUID)
    case cancel(id: UUID)
    case compare(id: UUID)
    case cleanup(id: UUID)
    case test(id: UUID, participantID: UUID, operationID: UUID, executable: String, arguments: [String])
    public var requestTimeout: TimeInterval {
        switch self { case .start, .cleanup: 300; case .compare: 60; default: 15 }
    }
}
public enum FanoutError: Error, LocalizedError {
    case invalid, executable, history, host, missing, identity, active, budget, captureDisabled
    public var errorDescription: String? {
        switch self {
        case .invalid: "Use 1–8 Claude, Codex or Cursor participants, valid profile names, and a nonempty prompt of at most 32 KiB. Provider homes are supported for Claude and Codex only."
        case .executable: "The selected provider executable is unavailable. Install its CLI or choose an absolute executable path on this host."
        case .history: "Unlock or repair durable activity storage before fan-out. Existing work and processes are preserved."
        case .host: "Fan-out needs a session host supporting prepared stdin and durable workload outcomes. Adopt the host update after its shells close, or explicitly approve their interruption."
        case .missing: "This fan-out ID has no retained record on this host. No workload was launched or stopped."
        case .identity: "This operation ID already names different fan-out work. Inspect the existing record instead of retrying with changed arguments."
        case .active: "A workload or explicit test is still active or its outcome is unknown. Inspect or cancel it before cleanup."
        case .budget: "Fan-out reached its bounded record, launch or explicit-test budget. Existing work remains intact."
        case .captureDisabled: "Captured fan-out text was removed by persistence opt-out. Prepared workloads will not be launched from missing prompts or arguments."
        }
    }
}
