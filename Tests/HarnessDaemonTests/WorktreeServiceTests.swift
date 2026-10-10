import Foundation
import HarnessCore
import XCTest
@testable import HarnessDaemonCore

final class WorktreeServiceTests: XCTestCase {
    func testPinnedBaseComparisonAndCleanupProtectDirtyActiveUnpushedAndUnmanagedWork() throws {
        guard let products = ProcessInfo.processInfo.environment["HARNESS_TEST_PRODUCTS"] else { throw XCTSkip("Supply the built daemon path for the isolated Git job fixture.") }
        let executable = URL(fileURLWithPath: products).appendingPathComponent("HarnessDaemon")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hworktree-" + UUID().uuidString).resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("repository"), managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try HarnessGit.run(directory: repository.path, arguments: ["init", "-b", "main"])
        try Data("first\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        _ = try HarnessGit.run(directory: repository.path, arguments: ["add", "--", "file.txt"])
        let commitArgs = ["-c", "user.name=Harness fixture", "-c", "user.email=fixture@invalid", "commit", "--no-gpg-sign", "-m", "fixture"]
        _ = try HarnessGit.run(directory: repository.path, arguments: commitArgs)
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 19, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let store = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: protection)
        let service = WorktreeService(store: store, hostID: UUID(), settings: WorktreeSettings(directory: managed.path), settingsURL: root.appendingPathComponent("settings.json"), lockDirectory: root.appendingPathComponent("leases"), executable: executable)
        func invoke<T: Decodable>(_ operation: WorktreeOperation, _ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: service.handle(operation, cancelled: { false })) }
        let id = UUID(), worktree = try invoke(.create(id: id, directory: repository.path, base: nil), ManagedWorktree.self)
        XCTAssertEqual(worktree.state, .ready)
        XCTAssertEqual(worktree.baseCommit, try HarnessGit.commit("HEAD", in: repository.path))
        XCTAssertEqual(try invoke(.create(id: id, directory: repository.path, base: nil), ManagedWorktree.self).directory, worktree.directory)
        XCTAssertEqual(try HarnessGit.repository(at: worktree.directory).commonDirectory, try HarnessGit.repository(at: repository.path).commonDirectory)
        try Data("first\nsecond\n".utf8).write(to: URL(fileURLWithPath: worktree.directory).appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: URL(fileURLWithPath: worktree.directory).appendingPathComponent("untracked.txt"))
        let comparison = try invoke(.compare(id: id), WorktreeComparison.self)
        XCTAssertEqual(comparison.workingTree.added, 1); XCTAssertEqual(comparison.committed.files, 0)
        XCTAssertEqual(comparison.untrackedFiles, ["untracked.txt"])
        XCTAssertThrowsError(try service.handle(.remove(id: id), cancelled: { false })) { XCTAssertEqual(($0 as? ManagedWorktreeError), .dirty) }
        _ = try HarnessGit.run(directory: worktree.directory, arguments: ["add", "--", "file.txt", "untracked.txt"])
        _ = try HarnessGit.run(directory: worktree.directory, arguments: commitArgs)
        XCTAssertThrowsError(try service.handle(.remove(id: id), cancelled: { false })) { XCTAssertEqual(($0 as? ManagedWorktreeError), .unpushed) }
        // A local ref under refs/remotes supplies observed remote reachability without network.
        let head = try HarnessGit.commit("HEAD", in: worktree.directory)
        _ = try HarnessGit.run(directory: repository.path, arguments: ["update-ref", "refs/remotes/fixture/committed", head])
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["20"]
        process.currentDirectoryURL = URL(fileURLWithPath: worktree.directory)
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertTrue(waitUntil(timeout: 3) { ProcessScan.workingDirectory(process.processIdentifier).map { ProcessScan.directory($0, isWithin: worktree.directory) } == true }, "The workload has reached its requested working directory")
        do {
            XCTAssertThrowsError(try service.handle(.remove(id: id), cancelled: { false })) { XCTAssertEqual(($0 as? ManagedWorktreeError), .active) }
            process.terminate(); process.waitUntilExit()
        }
        let marker = URL(fileURLWithPath: worktree.directory).deletingLastPathComponent().appendingPathComponent(id.uuidString + ".harness-worktree.json")
        let originalMarker = try Data(contentsOf: marker)
        try Data("invalid".utf8).write(to: marker)
        XCTAssertThrowsError(try service.handle(.remove(id: id), cancelled: { false })) { XCTAssertEqual(($0 as? ManagedWorktreeError), .identity) }
        XCTAssertEqual(try invoke(.inspect(id: id), ManagedWorktree.self).state, .failed)
        try originalMarker.write(to: marker)
        XCTAssertEqual(try invoke(.inspect(id: id), ManagedWorktree.self).state, .ready)
        XCTAssertEqual(try invoke(.remove(id: id), ManagedWorktree.self).state, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.directory))
        XCTAssertEqual(try HarnessGit.commit(worktree.branch, in: repository.path), head, "Cleanup retains committed branch history")
        XCTAssertThrowsError(try service.handle(.remove(id: UUID()), cancelled: { false }))
        try Data("dirty main\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        XCTAssertThrowsError(try service.handle(.create(id: UUID(), directory: repository.path, base: nil), cancelled: { false })) { XCTAssertEqual(($0 as? GitOperationError), .dirty) }
        let explicit = try invoke(.create(id: UUID(), directory: repository.path, base: worktree.baseCommit), ManagedWorktree.self)
        XCTAssertEqual(explicit.baseCommit, worktree.baseCommit)
        XCTAssertEqual(try String(contentsOfFile: explicit.directory + "/file.txt", encoding: .utf8), "first\n")
        _ = try invoke(.remove(id: explicit.id), ManagedWorktree.self)
    }
    func testInheritedMutationLeaseBlocksReplacementAfterParentDescriptorCloses() throws {
        guard let products = ProcessInfo.processInfo.environment["HARNESS_TEST_PRODUCTS"] else { throw XCTSkip("Supply the built daemon path for the isolated Git job fixture.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgit-lease-" + UUID().uuidString).resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try HarnessGit.run(directory: repository.path, arguments: ["init", "-b", "main"])
        try Data("payload\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try Data("file.txt filter=fixture\n".utf8).write(to: repository.appendingPathComponent(".gitattributes"))
        _ = try HarnessGit.run(directory: repository.path, arguments: ["add", "--", "file.txt", ".gitattributes"])
        _ = try HarnessGit.run(directory: repository.path, arguments: ["-c", "user.name=Harness fixture", "-c", "user.email=fixture@invalid", "commit", "--no-gpg-sign", "-m", "base"])
        let started = root.appendingPathComponent("started"), release = root.appendingPathComponent("release")
        let filter = "touch " + ShellQuoting.quote(started.path) + "; while [ ! -f " + ShellQuoting.quote(release.path) + " ]; do sleep 0.02; done; cat"
        _ = try HarnessGit.run(directory: repository.path, arguments: ["config", "filter.fixture.smudge", filter])
        let id = UUID(), target = root.appendingPathComponent(id.uuidString), leaseURL = root.appendingPathComponent("leases/repository.lock")
        let lease = try ManagedGitLease(url: leaseURL, cancelled: { false })
        let worker = Process(); worker.executableURL = URL(fileURLWithPath: products).appendingPathComponent("HarnessDaemon")
        worker.arguments = ["--managed-git-worker", "add", repository.path, target.path, "harness/" + id.uuidString.lowercased(), try HarnessGit.commit("HEAD", in: repository.path)]
        worker.standardInput = lease.input; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer {
            try? Data().write(to: release)
            if worker.isRunning { worker.terminate() }
            worker.waitUntilExit()
        }
        XCTAssertTrue(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: started.path) }, "Git reached the fixture's bounded checkout gate")
        // This is the descriptor release that a daemon crash performs. The job
        // and its Git child retain the same locked open description.
        try lease.input.close()
        XCTAssertThrowsError(try ManagedGitLease(url: leaseURL, cancelled: { false })) { XCTAssertEqual($0 as? ManagedWorktreeError, .busy) }
        try Data().write(to: release)
        XCTAssertTrue(waitUntil(timeout: 5) { !worker.isRunning })
        worker.waitUntilExit(); XCTAssertEqual(worker.terminationStatus, 0)
        let replacement = try ManagedGitLease(url: leaseURL, cancelled: { false })
        withExtendedLifetime(replacement) { XCTAssertEqual(try? String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8), "payload\n") }
    }

}
