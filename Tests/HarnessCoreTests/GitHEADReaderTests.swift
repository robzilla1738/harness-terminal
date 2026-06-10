import XCTest
@testable import HarnessCore

/// `GitHEADReader` works on hand-built fixtures (a `.git` directory is just files), so no
/// `git` binary is needed — the suite runs identically on macOS and Linux CI.
final class GitHEADReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-head-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A minimal regular repository: `<name>/.git/HEAD` with the given content.
    @discardableResult
    private func makeRepository(named name: String, head: String) throws -> URL {
        let workTree = root.appendingPathComponent(name, isDirectory: true)
        let gitDir = workTree.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return workTree
    }

    // MARK: Branch parsing

    func testSymbolicRefReadsBranchName() throws {
        let repo = try makeRepository(named: "repo", head: "ref: refs/heads/main\n")
        XCTAssertEqual(GitHEADReader.currentBranch(at: repo.path), "main")
    }

    func testBranchNamesWithSlashesArePreserved() throws {
        let repo = try makeRepository(named: "repo", head: "ref: refs/heads/feature/fix-42\n")
        XCTAssertEqual(GitHEADReader.currentBranch(at: repo.path), "feature/fix-42")
    }

    func testDetachedHeadReadsShortHash() throws {
        let sha1 = "0123456789abcdef0123456789abcdef01234567"
        let repo = try makeRepository(named: "repo", head: sha1 + "\n")
        XCTAssertEqual(GitHEADReader.currentBranch(at: repo.path), "0123456")
    }

    func testDetachedHeadSHA256ReadsShortHash() throws {
        let sha256 = String(repeating: "a1b2c3d4", count: 8) // 64 hex chars
        let repo = try makeRepository(named: "repo", head: sha256)
        XCTAssertEqual(GitHEADReader.currentBranch(at: repo.path), "a1b2c3d")
    }

    func testRefOutsideHeadsIsReturnedAsWritten() throws {
        let repo = try makeRepository(named: "repo", head: "ref: refs/remotes/origin/main\n")
        XCTAssertEqual(GitHEADReader.currentBranch(at: repo.path), "refs/remotes/origin/main")
    }

    func testEmptyHeadReadsNil() throws {
        let repo = try makeRepository(named: "repo", head: "")
        XCTAssertNil(GitHEADReader.currentBranch(at: repo.path))
    }

    func testWhitespaceOnlyHeadReadsNil() throws {
        let repo = try makeRepository(named: "repo", head: "\n  \n")
        XCTAssertNil(GitHEADReader.currentBranch(at: repo.path))
    }

    func testGarbageHeadReadsNil() throws {
        // Not a ref, not a full-length hash (a torn/partial write also lands here).
        let repo = try makeRepository(named: "repo", head: "0123abc\n")
        XCTAssertNil(GitHEADReader.currentBranch(at: repo.path))
    }

    func testUnreadableHeadReadsNil() {
        let missing = root.appendingPathComponent("nope/HEAD")
        XCTAssertNil(GitHEADReader.readBranch(headFileURL: missing))
    }

    // MARK: Repository resolution

    func testResolvesFromNestedSubdirectory() throws {
        let repo = try makeRepository(named: "repo", head: "ref: refs/heads/main\n")
        let nested = repo.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(GitHEADReader.resolveRepository(startingAt: nested.path))
        XCTAssertEqual(resolved.workTree, repo.path)
        XCTAssertEqual(GitHEADReader.readBranch(headFileURL: resolved.headFileURL), "main")
    }

    func testNonRepositoryResolvesNil() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(GitHEADReader.resolveRepository(startingAt: plain.path))
    }

    func testEmptyPathResolvesNil() {
        XCTAssertNil(GitHEADReader.resolveRepository(startingAt: ""))
    }

    /// Regression: Darwin's `URL.deletingLastPathComponent()` maps "/" to "/..", which made
    /// the upward walk non-terminating for any path outside a repository (it wedged the
    /// monitor's I/O queue in production). Returning at all is the assertion here; the
    /// value depends on whether the host's root happens to be a repository, so it isn't
    /// pinned. `testNonRepositoryResolvesNil` covers the value for a real non-repo path.
    func testWalkTerminatesAtFilesystemRoot() {
        _ = GitHEADReader.resolveRepository(startingAt: "/")
    }

    func testGitDirectoryWithoutHeadResolvesNil() throws {
        let workTree = root.appendingPathComponent("broken", isDirectory: true)
        let gitDir = workTree.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        XCTAssertNil(GitHEADReader.resolveRepository(startingAt: workTree.path))
    }

    // MARK: Worktrees / submodules (`.git` file with `gitdir:`)

    /// Lay out a main repository with a linked worktree the way `git worktree add` does:
    /// the worktree's `.git` is a FILE pointing at `<main>/.git/worktrees/<name>`, which
    /// holds the per-worktree `HEAD`.
    private func makeWorktree(gitdirLine: (URL) -> String) throws -> (worktree: URL, worktreeGitDir: URL) {
        let main = try makeRepository(named: "main", head: "ref: refs/heads/main\n")
        let worktreeGitDir = main.appendingPathComponent(".git/worktrees/wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/wt-branch\n"
            .write(to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try gitdirLine(worktreeGitDir)
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return (worktree, worktreeGitDir)
    }

    func testWorktreeWithAbsoluteGitdirResolvesPerWorktreeHead() throws {
        let (worktree, worktreeGitDir) = try makeWorktree { "gitdir: \($0.path)\n" }
        let resolved = try XCTUnwrap(GitHEADReader.resolveRepository(startingAt: worktree.path))
        XCTAssertEqual(resolved.headFileURL.path, worktreeGitDir.appendingPathComponent("HEAD").path)
        XCTAssertEqual(GitHEADReader.currentBranch(at: worktree.path), "wt-branch")
    }

    func testWorktreeWithRelativeGitdirResolves() throws {
        let (worktree, _) = try makeWorktree { _ in "gitdir: ../main/.git/worktrees/wt\n" }
        XCTAssertEqual(GitHEADReader.currentBranch(at: worktree.path), "wt-branch")
    }

    func testWorktreesOfOneRepositoryResolveDistinctHeads() throws {
        let (worktree, _) = try makeWorktree { "gitdir: \($0.path)\n" }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let mainHead = try XCTUnwrap(GitHEADReader.resolveRepository(startingAt: main.path)).headFileURL.path
        let worktreeHead = try XCTUnwrap(GitHEADReader.resolveRepository(startingAt: worktree.path)).headFileURL.path
        XCTAssertNotEqual(mainHead, worktreeHead, "each worktree must be watchable independently")
    }

    func testDotGitFileWithoutGitdirMarkerResolvesNil() throws {
        let dir = root.appendingPathComponent("odd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not a gitdir pointer\n".write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitHEADReader.resolveRepository(startingAt: dir.path))
    }

    func testDotGitFileWithEmptyGitdirResolvesNil() throws {
        let dir = root.appendingPathComponent("odd2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "gitdir:   \n".write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitHEADReader.resolveRepository(startingAt: dir.path))
    }

    // MARK: Checkout transition (what the HEAD watcher observes)

    func testBranchSwitchIsVisibleThroughReread() throws {
        let repo = try makeRepository(named: "repo", head: "ref: refs/heads/main\n")
        let resolved = try XCTUnwrap(GitHEADReader.resolveRepository(startingAt: repo.path))
        XCTAssertEqual(GitHEADReader.readBranch(headFileURL: resolved.headFileURL), "main")
        // Atomic write — the same rename dance git's lockfile commit performs.
        try "ref: refs/heads/feature\n".write(to: resolved.headFileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHEADReader.readBranch(headFileURL: resolved.headFileURL), "feature")
    }
}
