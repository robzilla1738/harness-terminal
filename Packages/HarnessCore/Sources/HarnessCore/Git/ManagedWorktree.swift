import Foundation

public struct WorktreeSettings: Codable, Equatable, Sendable {
    public var directory: String?
    public init(directory: String? = nil) { self.directory = directory }
    public func validate() throws {
        if let directory { guard directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4096, URL(fileURLWithPath: directory).standardizedFileURL.path == directory else { throw GitOperationError.path } }
    }
}
public enum ManagedWorktreeState: String, Codable, Sendable { case creating, ready, failed, removing, removed }
public struct ManagedWorktree: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: UUID?
    public var repository: GitRepository
    public var directory: String
    public var baseCommit: String
    public var branch: String
    public var state: ManagedWorktreeState
    public var createdAt: Date
    public var updatedAt: Date
    public var failure: String?
    public var note: String?
    public var failedDuring: ManagedWorktreeState?
    public init(id: UUID, hostID: UUID, repository: GitRepository, directory: String, baseCommit: String, branch: String) {
        self.id = id; self.hostID = hostID; self.repository = repository; self.directory = directory; self.baseCommit = baseCommit; self.branch = branch
        state = .creating; createdAt = .now; updatedAt = createdAt
    }
}
public struct WorktreeComparison: Codable, Sendable {
    public var worktree: ManagedWorktree
    public var head: String
    public var committed: GitDiffStats
    public var workingTree: GitDiffStats
    public var untrackedFiles: [String]
    public var observedAt: Date
    public var patch: String?
    public var patchUnavailable: String?
    public init(worktree: ManagedWorktree, head: String, committed: GitDiffStats, workingTree: GitDiffStats, untrackedFiles: [String], patch: String? = nil, patchUnavailable: String? = nil) {
        self.worktree = worktree; self.head = head; self.committed = committed; self.workingTree = workingTree; self.untrackedFiles = untrackedFiles; self.patch = patch; self.patchUnavailable = patchUnavailable; observedAt = .now
    }
}
public struct WorktreePage: Codable, Sendable {
    public var worktrees: [ManagedWorktree]
    public var nextOffset: Int?
    public var historyUnavailable: String?
    public init(worktrees: [ManagedWorktree], nextOffset: Int?, historyUnavailable: String?) { self.worktrees = worktrees; self.nextOffset = nextOffset; self.historyUnavailable = historyUnavailable }
}
public enum WorktreeOperation: Codable, Sendable {
    case configure(WorktreeSettings?)
    case list(offset: Int, limit: Int)
    case create(id: UUID, directory: String, base: String?)
    case inspect(id: UUID)
    case compare(id: UUID)
    case remove(id: UUID)
    case difftoolCommand(id: UUID)
}
public enum ManagedWorktreeError: Error, LocalizedError {
    case unavailableHistory, missing, identity, active, dirty, unpushed, budget, busy
    public var errorDescription: String? {
        switch self {
        case .unavailableHistory: "Unlock or repair durable activity history before changing managed worktrees. Existing shells and worktrees remain intact."
        case .missing: "This worktree has no Harness management record. An arbitrary directory cannot be adopted or removed based on its name."
        case .identity: "The worktree, Git registration or management marker no longer matches its Harness record. Files were retained for inspection."
        case .active: "Processes are still using this worktree. Stop its workload and close shells in that directory before cleanup."
        case .dirty: "This worktree has staged, working-tree or untracked changes. Commit or preserve them before cleanup."
        case .unpushed: "This worktree has commits after its pinned base that are not on an observed remote ref. Push or preserve them before cleanup."
        case .busy: "A Git mutation for this repository still owns its process lease. Wait for it to finish, then inspect the recorded operation; it will not be launched again automatically."
        case .budget: "Managed worktree records or subprocess work exceeded the bounded budget. Inspect existing work before creating more."
        }
    }
}

public extension WorktreeOperation {
    var requestTimeout: TimeInterval {
        switch self { case .create, .remove: 45; case .compare: 20; default: 10 }
    }
}
