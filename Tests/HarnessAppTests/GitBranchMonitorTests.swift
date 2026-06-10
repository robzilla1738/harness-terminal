import Foundation
import XCTest
@testable import HarnessApp
import HarnessCore

/// `GitBranchMonitor` against hand-built `.git` fixtures (no `git` binary needed — the
/// reader only parses files). The monitor's I/O is async (background queue → main hop) and
/// its watcher events are debounced, so assertions use deadline polling on the main run
/// loop rather than fixed sleeps; "nothing fired" assertions use a short bounded window.
///
/// Fixtures are built per test by the @MainActor `makeFixture` helper (XCTestCase's
/// setUp/tearDown overrides are nonisolated by signature, so the class-level @MainActor
/// can't cover them — per-test construction sidesteps the isolation seam entirely).
@MainActor
final class GitBranchMonitorTests: XCTestCase {
    /// Change collector. @unchecked Sendable so closures can hold it without dragging
    /// `self` across isolation; every touch happens on the main thread (the monitor calls
    /// back on main, and XCTest drives these @MainActor tests on main).
    private final class Recorder: @unchecked Sendable {
        var changes: [(workspaceID: WorkspaceID, tabID: TabID, branch: String?)] = []
    }

    private struct Fixture {
        let monitor: GitBranchMonitor
        let root: URL
        let recorder: Recorder
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-branch-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let monitor = GitBranchMonitor()
        monitor.onBranchChange = { workspaceID, tabID, branch in
            recorder.changes.append((workspaceID, tabID, branch))
        }
        return Fixture(monitor: monitor, root: root, recorder: recorder)
    }

    private func makeRepository(in root: URL, named name: String, branch: String) throws -> URL {
        let workTree = root.appendingPathComponent(name, isDirectory: true)
        let gitDir = workTree.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n"
            .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return workTree
    }

    private func record(
        workspaceID: WorkspaceID = UUID(),
        tabID: TabID = UUID(),
        cwd: String,
        snapshotBranch: String? = nil
    ) -> GitBranchMonitor.TabRecord {
        GitBranchMonitor.TabRecord(
            workspaceID: workspaceID, tabID: tabID, cwd: cwd, snapshotBranch: snapshotBranch
        )
    }

    /// Spin the main run loop until `condition` holds (the monitor's I/O completions hop to
    /// main, so the loop must turn for them to land). Fails the test on deadline.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: @autoclosure () -> String,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for: \(message())")
    }

    /// Give async work a bounded window to (wrongly) fire, then assert it didn't.
    private func assertNoChanges(_ recorder: Recorder, within window: TimeInterval = 0.7, _ message: String) {
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if !recorder.changes.isEmpty { break }
        }
        XCTAssertTrue(recorder.changes.isEmpty, "\(message) — got \(recorder.changes)")
    }

    func testStaleSnapshotBranchIsPushed() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let tab = record(cwd: repo.path, snapshotBranch: nil)
        fixture.monitor.update(tabs: [tab])
        waitUntil("branch push for stale snapshot") { !fixture.recorder.changes.isEmpty }
        XCTAssertEqual(fixture.recorder.changes.first?.tabID, tab.tabID)
        XCTAssertEqual(fixture.recorder.changes.first?.branch, "main")
    }

    func testMatchingSnapshotProducesZeroIPC() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        fixture.monitor.update(tabs: [record(cwd: repo.path, snapshotBranch: "main")])
        assertNoChanges(fixture.recorder, within: 1.0, "steady state must not send updateTabGitBranch")
    }

    func testLeavingRepositoryClearsStaleLabel() throws {
        let fixture = try makeFixture()
        let plain = fixture.root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let tab = record(cwd: plain.path, snapshotBranch: "main")
        fixture.monitor.update(tabs: [tab])
        waitUntil(
            "clear push for non-repo cwd; resolver sees \(String(describing: GitHEADReader.resolveRepository(startingAt: plain.path))); changes \(fixture.recorder.changes)"
        ) { !fixture.recorder.changes.isEmpty }
        let change = try XCTUnwrap(fixture.recorder.changes.first)
        XCTAssertEqual(change.tabID, tab.tabID)
        XCTAssertEqual(fixture.recorder.changes.count, 1)
        XCTAssertNil(change.branch)
    }

    func testDuplicateSendIsSuppressedWhileSnapshotLags() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let tab = record(cwd: repo.path, snapshotBranch: nil)
        fixture.monitor.update(tabs: [tab])
        waitUntil("first push") { fixture.recorder.changes.count == 1 }
        // The daemon hasn't echoed the new value back yet (snapshotBranch still nil):
        // re-reconciling must not re-send.
        fixture.recorder.changes = []
        fixture.monitor.update(tabs: [tab])
        assertNoChanges(fixture.recorder, within: 1.0, "in-flight value must not be re-sent")
    }

    func testCheckoutFiresWatcherAndPushesNewBranch() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let tab = record(cwd: repo.path, snapshotBranch: "main")
        fixture.monitor.update(tabs: [tab])
        // Let the initial resolve land (no change expected — snapshot matches).
        assertNoChanges(fixture.recorder, within: 0.5, "no push before the checkout")

        // Same atomic rewrite a real `git checkout` performs on HEAD.
        let head = repo.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/feature\n".write(to: head, atomically: true, encoding: .utf8)
        waitUntil("push after checkout") { !fixture.recorder.changes.isEmpty }
        XCTAssertEqual(fixture.recorder.changes.first?.branch, "feature")
    }

    func testTwoTabsInOneRepositoryShareOneWatcherAndBothUpdate() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let sub = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let tabA = record(cwd: repo.path, snapshotBranch: "main")
        let tabB = record(cwd: sub.path, snapshotBranch: "main")
        fixture.monitor.update(tabs: [tabA, tabB])
        assertNoChanges(fixture.recorder, within: 0.5, "no push before the checkout")

        try "ref: refs/heads/release\n"
            .write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        waitUntil("both tabs pushed") { fixture.recorder.changes.count == 2 }
        XCTAssertEqual(Set(fixture.recorder.changes.map(\.tabID)), [tabA.tabID, tabB.tabID])
        XCTAssertTrue(fixture.recorder.changes.allSatisfy { $0.branch == "release" })
    }

    func testPausedMonitorStaysSilentAndResumeCatchesUp() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let tab = record(cwd: repo.path, snapshotBranch: "main")
        fixture.monitor.update(tabs: [tab])
        assertNoChanges(fixture.recorder, within: 0.5, "steady state")

        fixture.monitor.pause()
        try "ref: refs/heads/away\n"
            .write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        assertNoChanges(fixture.recorder, within: 0.7, "paused monitor must not push")

        fixture.monitor.resume()
        waitUntil("resume catches up on the missed checkout") { !fixture.recorder.changes.isEmpty }
        XCTAssertEqual(fixture.recorder.changes.first?.branch, "away")
    }

    func testResumeReSendsBranchTheDaemonNeverEchoed() throws {
        let fixture = try makeFixture()
        let repo = try makeRepository(in: fixture.root, named: "repo", branch: "main")
        let tab = record(cwd: repo.path, snapshotBranch: nil)
        fixture.monitor.update(tabs: [tab])
        waitUntil("first push") { fixture.recorder.changes.count == 1 }

        // The send's IPC failed (daemon down at send time): the snapshot never echoes
        // "main" back, so `snapshotBranch` stays nil and the in-flight suppression alone
        // would block every future identical read. Pause/resume (app re-activate) must
        // self-heal by re-sending.
        fixture.recorder.changes = []
        fixture.monitor.pause()
        fixture.monitor.resume()
        waitUntil("resume re-sends the never-echoed branch") { !fixture.recorder.changes.isEmpty }
        XCTAssertEqual(fixture.recorder.changes.first?.tabID, tab.tabID)
        XCTAssertEqual(fixture.recorder.changes.first?.branch, "main")
    }

    func testNewTabIntoNegativeCachedDirectoryReChecks() throws {
        let fixture = try makeFixture()
        let dir = fixture.root.appendingPathComponent("becomes-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // First tab visits: cached as not-a-repository. It stays open so the negative
        // entry survives the prune pass.
        let first = record(cwd: dir.path)
        fixture.monitor.update(tabs: [first])
        assertNoChanges(fixture.recorder, within: 0.5, "non-repo with nil snapshot stays silent")

        // The directory becomes a repository, then a *brand-new* tab opens into it.
        let gitDir = dir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/fresh\n"
            .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let second = record(cwd: dir.path)
        fixture.monitor.update(tabs: [first, second])
        waitUntil(
            "new tab re-resolves the negative-cached cwd; changes \(fixture.recorder.changes)"
        ) { fixture.recorder.changes.contains { $0.tabID == second.tabID } }
        let change = try XCTUnwrap(fixture.recorder.changes.first { $0.tabID == second.tabID })
        XCTAssertEqual(change.branch, "fresh")
    }

    func testCwdMoveIntoFreshRepositoryReChecksNegativeCache() throws {
        let fixture = try makeFixture()
        let dir = fixture.root.appendingPathComponent("becomes-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        // First visit: cached as not-a-repository.
        let tabID = UUID()
        let workspaceID = UUID()
        fixture.monitor.update(tabs: [record(workspaceID: workspaceID, tabID: tabID, cwd: dir.path)])
        assertNoChanges(fixture.recorder, within: 0.5, "non-repo with nil snapshot stays silent")

        // The directory becomes a repository while the tab is elsewhere…
        let gitDir = dir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/fresh\n"
            .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        fixture.monitor.update(tabs: [record(workspaceID: workspaceID, tabID: tabID, cwd: elsewhere.path)])

        // …and moving back in re-resolves instead of trusting the stale negative entry.
        fixture.monitor.update(tabs: [record(workspaceID: workspaceID, tabID: tabID, cwd: dir.path)])
        waitUntil(
            "re-check after cwd moves into a fresh repo; resolver sees \(String(describing: GitHEADReader.resolveRepository(startingAt: dir.path))); changes \(fixture.recorder.changes)"
        ) { !fixture.recorder.changes.isEmpty }
        XCTAssertEqual(fixture.recorder.changes.first?.branch, "fresh")
    }
}
