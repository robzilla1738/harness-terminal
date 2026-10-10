import Foundation

/// A command explicitly identified by the user as a test. Provider exit codes,
/// tool names and arbitrary OSC 133 commands cannot create this record.
public struct TestExecution: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var parentRunID: UUID
    public var sourceSurfaceID: String
    public var repository: GitRepository?
    public var test: TrackedTest
    public init(hostID: UUID, participant: FanoutParticipant, repository: GitRepository, test: TrackedTest) {
        id = test.id; self.hostID = hostID; parentRunID = participant.id; sourceSurfaceID = participant.surfaceID
        self.repository = participant.directory.map { GitRepository(worktree: $0, commonDirectory: repository.commonDirectory) }; self.test = test
    }
    public mutating func removeCapturedText() { repository = nil; test.launch = nil; test.failure = nil }
}
public struct TestExecutionSummary: Codable, Equatable, Sendable {
    public var executions = 0
    public var passed = 0
    public var failed = 0
    public var pending = 0
    public var unknown = 0
    public var notStarted: Int? = 0
    public init() {}
    public var displayText: String {
        "Explicit tests (retained observations): \(executions) executions; \(passed) passed; \(failed) failed; \(pending) pending; \(unknown) unknown; " + (notStarted.map { "\($0) did not start." } ?? "unavailable not-started count.")
    }
    public mutating func record(_ execution: TestExecution) {
        if execution.test.launchRejected == true { notStarted = (notStarted ?? 0) + 1; return }
        executions += 1
        guard let outcome = execution.test.outcome else { unknown += 1; return }
        switch outcome.state {
        case .reserved, .running: pending += 1
        case .unknown: unknown += 1
        case .exited:
            if outcome.exitCode == 0 { passed += 1 }
            else if outcome.exitCode != nil { failed += 1 }
            else { unknown += 1 }
        }
    }
}
