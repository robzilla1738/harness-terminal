import Foundation

public struct GitRepository: Codable, Equatable, Sendable {
    public var worktree: String
    public var commonDirectory: String
    public init(worktree: String, commonDirectory: String) { self.worktree = worktree; self.commonDirectory = commonDirectory }
}
public struct GitDiffStats: Codable, Equatable, Sendable {
    public var files: Int
    public var added: Int64
    public var removed: Int64
    public var binaryFiles: Int
    public init(files: Int = 0, added: Int64 = 0, removed: Int64 = 0, binaryFiles: Int = 0) { self.files = files; self.added = added; self.removed = removed; self.binaryFiles = binaryFiles }
}
public struct GitCheckoutState: Codable, Sendable {
    public var directory: String
    public var head: String?
    public var tracked: GitDiffStats?
    public var untrackedFiles: Int?
    public var observedAt: Date
    public var unavailable: String?
    public init(directory: String, head: String?, tracked: GitDiffStats?, untrackedFiles: Int?, unavailable: String? = nil) {
        self.directory = directory; self.head = head; self.tracked = tracked; self.untrackedFiles = untrackedFiles; self.unavailable = unavailable; observedAt = .now
    }
}
/// Argument-array Git commands with bounded pipes and deadlines. Read operations
/// disable external diff/text conversion, hooks and filesystem-monitor commands.
/// Neither ambient GIT_* overrides nor global/system config can redirect a target.
public enum HarnessGit {
    public static func run(directory: String, arguments: [String], timeout: TimeInterval = 3, limit: Int = 2 << 20, inputHandle: FileHandle? = nil, cancelled: () -> Bool = { false }) throws -> Data {
        guard directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4096 else { throw GitOperationError.path }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_OPTIONAL_LOCKS"] = "0"
        let flags = ["git", "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=", "-C", directory]
        let result = try ProcessCapture.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: flags + arguments, environment: environment, timeout: timeout, inputHandle: inputHandle, maxOutputBytes: limit, cancelled: cancelled)
        guard result.status == 0 else { throw GitOperationError.command }
        return result.stdout
    }
    private static func path(_ data: Data) throws -> String {
        var bytes = data; if bytes.last == 10 { bytes.removeLast() }
        guard let value = String(data: bytes, encoding: .utf8), value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 4096 else { throw GitOperationError.path }
        return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
    }
    public static func repository(at directory: String, cancelled: () -> Bool = { false }) throws -> GitRepository {
        let root = try path(run(directory: directory, arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel"], limit: 8192, cancelled: cancelled))
        let common = try path(run(directory: root, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], limit: 8192, cancelled: cancelled))
        return GitRepository(worktree: root, commonDirectory: common)
    }
    public static func commit(_ reference: String, in directory: String, cancelled: () -> Bool = { false }) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 512, !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw GitOperationError.reference }
        let bytes = try run(directory: directory, arguments: ["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], limit: 4096, cancelled: cancelled)
        let hash = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else { throw GitOperationError.reference }
        return hash.lowercased()
    }
    public static func clean(_ directory: String, cancelled: () -> Bool = { false }) throws -> Bool {
        try run(directory: directory, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"], cancelled: cancelled).isEmpty
    }
    public static func stats(_ data: Data) throws -> GitDiffStats {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0, result = GitDiffStats()
        while index < fields.count {
            if fields[index].isEmpty { guard index == fields.count - 1 else { throw GitOperationError.output }; break }
            let record = fields[index].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard record.count == 3 else { throw GitOperationError.output }
            result.files += 1
            if record[0] == Data([45]) && record[1] == Data([45]) { result.binaryFiles += 1 }
            else {
                guard let added = Int64(String(decoding: record[0], as: UTF8.self)), let removed = Int64(String(decoding: record[1], as: UTF8.self)), added >= 0, removed >= 0 else { throw GitOperationError.output }
                let (totalAdded, overflowAdded) = result.added.addingReportingOverflow(added), (totalRemoved, overflowRemoved) = result.removed.addingReportingOverflow(removed)
                guard !overflowAdded, !overflowRemoved else { throw GitOperationError.output }
                result.added = totalAdded; result.removed = totalRemoved
            }
            if record[2].isEmpty {
                guard index + 2 < fields.count, !fields[index + 1].isEmpty, !fields[index + 2].isEmpty else { throw GitOperationError.output }
                index += 3 // NUL-separated old and new paths of a rename.
            } else { index += 1 }
        }
        return result
    }
    public static func checkoutState(_ directory: String, cancelled: () -> Bool = { false }) -> GitCheckoutState {
        do {
            let head = try commit("HEAD", in: directory, cancelled: cancelled)
            let tracked = try stats(run(directory: directory, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", head, "--"], cancelled: cancelled))
            let untracked = try run(directory: directory, arguments: ["ls-files", "--others", "--exclude-standard", "-z"], cancelled: cancelled).split(separator: 0).count
            return GitCheckoutState(directory: directory, head: head, tracked: tracked, untrackedFiles: untracked)
        } catch { return GitCheckoutState(directory: directory, head: nil, tracked: nil, untrackedFiles: nil, unavailable: error.localizedDescription) }
    }
}
public enum GitOperationError: Error, LocalizedError {
    case path, reference, command, output, dirty, changed
    public var errorDescription: String? {
        switch self {
        case .path: "The Git target is not an absolute valid working-tree path."
        case .reference: "The selected Git reference does not resolve to one committed object."
        case .command: "Git could not complete this operation. Check that Git is installed and the repository, reference and permissions are valid. No external diff, text-conversion, hook or filesystem-monitor commands were enabled."
        case .output: "Git returned invalid or over-budget structured output; counts are unavailable."
        case .dirty: "The current checkout contains staged, working-tree or untracked changes. Select an explicit committed base or make the checkout clean; uncommitted changes are never copied implicitly."
        case .changed: "The checkout changed while its base was being selected. Choose an explicit committed base and retry."
        }
    }
}
