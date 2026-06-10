import Foundation

/// In-process replacement for `git rev-parse --abbrev-ref HEAD`: resolves the repository
/// containing a directory and reads the current branch straight from its `HEAD` file.
/// No subprocess — so there is no child to spawn per tab per tick, and no
/// `waitUntilExit()` that can hang forever on a wedged filesystem (the failure mode that
/// motivated retiring the `Process`-based reader; a slow *read* here blocks only its
/// calling queue, never an unkillable child).
///
/// Handles the three on-disk shapes of `.git`:
/// - a directory (regular repository) → `HEAD` lives inside it,
/// - a file containing `gitdir: <path>` (worktrees, submodules) → `HEAD` lives in the
///   pointed-to directory, which is **per-worktree**, so two worktrees of one repository
///   resolve to distinct `HEAD` files and can be watched independently.
public enum GitHEADReader {
    /// A resolved repository: where its working tree starts and the `HEAD` file that names
    /// the current branch. Watch `headFileURL` for branch changes — git updates it via
    /// lockfile + rename, so a vnode watcher sees a `.rename` per checkout.
    public struct Repository: Equatable, Sendable {
        /// The working-tree root (the directory whose `.git` entry resolved).
        public let workTree: String
        /// The resolved `HEAD` file for this working tree.
        public let headFileURL: URL

        public init(workTree: String, headFileURL: URL) {
            self.workTree = workTree
            self.headFileURL = headFileURL
        }
    }

    /// Walk from `path` toward the filesystem root looking for a `.git` entry, exactly like
    /// git's own discovery. Returns `nil` when no repository contains `path`, or when the
    /// `.git` entry found is unreadable/broken (a corrupt repo is treated as "no branch to
    /// show", never an error to surface).
    public static func resolveRepository(startingAt path: String) -> Repository? {
        guard !path.isEmpty else { return nil }
        // The walk is string-based: Darwin's `URL.deletingLastPathComponent()` maps "/" to
        // "/.." (and then "/../.." …), so a URL-based walk never terminates for a path
        // outside any repository. `NSString.deletingLastPathComponent` maps "/" to "/" on
        // every platform, making the reached-the-root guard actually fire.
        var directoryPath = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            if let gitDir = gitDirectory(for: directory) {
                let head = gitDir.appendingPathComponent("HEAD")
                guard FileManager.default.fileExists(atPath: head.path) else { return nil }
                return Repository(workTree: directory.path, headFileURL: head)
            }
            let parent = (directoryPath as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != directoryPath else { return nil } // reached the root
            directoryPath = parent
        }
    }

    /// Read the branch out of a resolved `HEAD` file.
    /// - `ref: refs/heads/<branch>` → `<branch>` (slashes in branch names preserved),
    /// - `ref: <other>` → the ref as written (rare; e.g. a symref outside `refs/heads/`),
    /// - a full commit hash (detached HEAD) → its 7-character short form,
    /// - unreadable / empty / unrecognized content → `nil`. Git rewrites `HEAD` atomically
    ///   (lockfile + rename), so a partial read is not expected; if one ever surfaces it
    ///   fails the hash-length check and reads as `nil` until the watcher fires again.
    public static func readBranch(headFileURL: URL) -> String? {
        guard let raw = try? String(contentsOf: headFileURL, encoding: .utf8) else { return nil }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        if content.hasPrefix("ref:") {
            let ref = content.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { return nil }
            let branchPrefix = "refs/heads/"
            if ref.hasPrefix(branchPrefix) {
                let branch = String(ref.dropFirst(branchPrefix.count))
                return branch.isEmpty ? nil : branch
            }
            return ref
        }
        // Detached HEAD stores the full object hash: 40 hex (SHA-1) or 64 hex (SHA-256).
        if (content.count == 40 || content.count == 64), content.allSatisfy(\.isHexDigit) {
            return String(content.prefix(7))
        }
        return nil
    }

    /// Convenience for one-shot callers (`GitMetadataProvider`): resolve + read in one step.
    public static func currentBranch(at path: String) -> String? {
        guard let repository = resolveRepository(startingAt: path) else { return nil }
        return readBranch(headFileURL: repository.headFileURL)
    }

    /// The git directory for `directory`, if its `.git` entry resolves: the entry itself when
    /// it is a directory, or the `gitdir: <path>` target when it is a file (worktree/submodule;
    /// relative targets resolve against `directory`).
    private static func gitDirectory(for directory: URL) -> URL? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }
        guard let raw = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = raw.split(whereSeparator: \.isNewline).first
        else { return nil }
        let marker = "gitdir:"
        guard line.hasPrefix(marker) else { return nil }
        let target = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target, isDirectory: true)
        }
        return URL(fileURLWithPath: target, isDirectory: true, relativeTo: directory).standardizedFileURL
    }
}
