import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class FanoutServiceTests: XCTestCase {
    func testPinnedPartialFailureActualOutcomesCancellationTestsAndProtectedCleanup() throws {
        guard let products = ProcessInfo.processInfo.environment["HARNESS_TEST_PRODUCTS"] else { throw XCTSkip("Supply built products for the disposable managed Git job fixture.") }
        _ = testSIGPIPEIgnored
        let root = URL(fileURLWithPath: "/tmp/hfanout-" + UUID().uuidString), repo = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws { _ = try HarnessGit.run(directory: repo.path, arguments: arguments) }
        try git(["init"])
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("base.txt"))
        try git(["add", "."]); try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "base"])
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 79, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let ledgerURL = root.appendingPathComponent("activity.sqlite"), ledger = ActivityStore(url: ledgerURL, protection: protection), hostID = UUID()
        let worktrees = WorktreeService(store: ledger, hostID: hostID, settings: WorktreeSettings(directory: root.appendingPathComponent("managed").path), settingsURL: root.appendingPathComponent("settings.json"), lockDirectory: root.appendingPathComponent("git-leases"), executable: URL(fileURLWithPath: products).appendingPathComponent("HarnessDaemon"))
        let owner = try OwnedWorkloadFixture(root: root); defer { owner.stop() }
        let workspace = UUID()
        let service = FanoutService(store: ledger, hostID: hostID, worktrees: worktrees, host: owner.client, workspace: { _ in workspace }, launch: { group, participant, specification, input in
            if input == Data("fixture-refused-before-host".utf8) || specification.arguments == ["fixture-refused-before-host"] { throw OwnedWorkloadLaunchError.notAccepted("Fixture preflight refused") }
            return try owner.launch(group, participant, specification, input)
        })
        func group(_ operation: FanoutOperation) throws -> FanoutGroup { try JSONDecoder().decode(FanoutGroup.self, from: service.handle(operation, cancelled: { false })) }
        let gate = root.appendingPathComponent("gate"), provider = root.appendingPathComponent("provider")
        let script = "#!/bin/sh\nwc -c > prompt.bytes\nprintf 'turn complete\\n'\nprintf 'changed\\n' > result.txt\nwhile [ ! -f " + ShellQuoting.quote(gate.path) + " ]; do sleep 0.05; done\nexit 7\n"
        try Data(script.utf8).write(to: provider); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        let id = UUID(), prompt = "FANOUT_PROMPT_SENTINEL $(never_execute) ' quoted · Unicode ☃\n"
        let providers = [FanoutProvider(provider: .codex, executable: provider.path), FanoutProvider(provider: .claudeCode, executable: root.appendingPathComponent("missing-provider").path)]
        let operation = FanoutOperation.start(id: id, directory: repo.path, base: nil, workspaceID: workspace, prompt: prompt, providers: providers, managedWorktrees: true)
        let started = try group(operation)
        XCTAssertEqual(started.participants.count, 2); XCTAssertEqual(started.participants[0].state, .running); XCTAssertEqual(started.participants[1].state, .failed)
        XCTAssertEqual(try group(operation).participants.map(\.id), started.participants.map(\.id))
        let first = started.participants[0], firstDirectory = try XCTUnwrap(first.directory)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: firstDirectory + "/prompt.bytes") && FileManager.default.fileExists(atPath: firstDirectory + "/result.txt") })
        XCTAssertEqual(Int(try String(contentsOfFile: firstDirectory + "/prompt.bytes", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), prompt.utf8.count)
        XCTAssertEqual(try group(.inspect(id: id)).participants[0].state, .running) // Turn-complete text does not end a process.
        for participant in started.participants { if let worktreeID = participant.worktreeID { let record = try XCTUnwrap(ledger.object(ManagedWorktree.self, kind: "managed-worktree", id: worktreeID.uuidString)); XCTAssertEqual(record.baseCommit, started.baseCommit) } }
        try Data().write(to: gate)
        XCTAssertTrue(waitUntil { (try? group(.inspect(id: id)).participants[0].state) == .exited })
        let finished = try group(.inspect(id: id)); XCTAssertEqual(finished.participants[0].outcome?.exitCode, 7)
        let testID = UUID(), testGate = root.appendingPathComponent("explicit-test-gate")
        let testArguments = ["-c", "while [ ! -f " + ShellQuoting.quote(testGate.path) + " ]; do sleep 0.05; done; exit 0"]
        let testOperation = FanoutOperation.test(id: id, participantID: first.id, operationID: testID, executable: "/bin/sh", arguments: testArguments)
        let successfulCalls = AtomicCounter(), rejectedCalls = AtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let value = try JSONDecoder().decode(FanoutGroup.self, from: service.handle(testOperation, cancelled: { false }))
                if value.participants[0].tests.count == 1 { successfulCalls.increment() } else { rejectedCalls.increment() }
            } catch { rejectedCalls.increment() }
        }
        XCTAssertEqual(successfulCalls.value, 2); XCTAssertEqual(rejectedCalls.value, 0)
        XCTAssertEqual(owner.launchCount(testID), 1)
        try Data().write(to: testGate)
        XCTAssertTrue(waitUntil { (try? group(.inspect(id: id)).participants[0].tests[0].outcome?.state) == .exited })
        XCTAssertEqual(try group(.inspect(id: id)).participants[0].tests[0].outcome?.exitCode, 0)
        XCTAssertEqual(try group(testOperation).participants[0].tests.count, 1)
        let rejectedTestID = UUID()
        let rejectedTest = try group(.test(id: id, participantID: first.id, operationID: rejectedTestID, executable: "/bin/sh", arguments: ["fixture-refused-before-host"]))
        XCTAssertTrue(rejectedTest.participants[0].tests.last?.launchRejected == true)
        XCTAssertEqual(owner.launchCount(rejectedTestID), 0)
        XCTAssertFalse(rejectedTest.participants[0].tests.last?.mayBeRunning ?? true)
        let refusedID = UUID()
        let refused = try group(.start(id: refusedID, directory: repo.path, base: nil, workspaceID: workspace, prompt: "fixture-refused-before-host", providers: [FanoutProvider(provider: .codex, executable: provider.path)], managedWorktrees: false))
        XCTAssertEqual(refused.participants[0].state, .failed)
        XCTAssertEqual(owner.launchCount(refused.participants[0].id), 0)
        let comparison = try JSONDecoder().decode(FanoutComparison.self, from: service.handle(.compare(id: id), cancelled: { false }))
        XCTAssertTrue(try XCTUnwrap(comparison.repositories[first.id.uuidString]).untrackedFiles.contains("result.txt"))
        let cleanup = try group(.cleanup(id: id))
        XCTAssertFalse(cleanup.participants[0].cleanedUp); XCTAssertNotNil(cleanup.participants[0].failure); XCTAssertTrue(cleanup.participants[1].cleanedUp)
        #if os(macOS)
        XCTAssertFalse(try Data(contentsOf: ledgerURL).range(of: Data(prompt.utf8)) != nil)
        let wal = URL(fileURLWithPath: ledgerURL.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) { XCTAssertNil(try Data(contentsOf: wal).range(of: Data(prompt.utf8))) }
        #endif
        let summary = try ledger.testSummary(from: Date().addingTimeInterval(-86400), to: Date().addingTimeInterval(1))
        XCTAssertEqual(summary.executions, 1); XCTAssertEqual(summary.passed, 1); XCTAssertEqual(summary.failed, 0); XCTAssertEqual(summary.notStarted, 1)
        let reports = try ledger.repositoryDigests(hostID: hostID, from: Date().addingTimeInterval(-86400), to: Date().addingTimeInterval(1), offset: 0, limit: 100, cancelled: { false })
        XCTAssertEqual(reports.reports.first?.tests?.passed, 1)
        try ledger.prune(now: Date().addingTimeInterval(15 * 86400))
        XCTAssertNil(try ledger.object(FanoutGroup.self, kind: "fanout", id: id.uuidString)?.prompt)
        XCTAssertNotNil(try ledger.object(FanoutGroup.self, kind: "fanout", id: id.uuidString)?.participants[0].worktreeID)
        try ledger.removeCapturedText(surfaceID: first.surfaceID)
        let privateGroup = try group(.inspect(id: id)); XCTAssertNil(privateGroup.prompt); XCTAssertNil(privateGroup.participants[0].launch); XCTAssertTrue(privateGroup.captureDisabled)
        let long = root.appendingPathComponent("long-provider")
        try Data("#!/bin/sh\ncat >/dev/null\nexec sleep 60\n".utf8).write(to: long); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: long.path)
        let cancelID = UUID()
        let active = try group(.start(id: cancelID, directory: repo.path, base: nil, workspaceID: workspace, prompt: "fixture", providers: [FanoutProvider(provider: .cursor, executable: long.path)], managedWorktrees: false))
        XCTAssertEqual(active.participants[0].state, .running)
        XCTAssertThrowsError(try group(.cleanup(id: cancelID)))
        _ = try group(.cancel(id: cancelID))
        XCTAssertTrue(waitUntil(timeout: 5) { (try? group(.inspect(id: cancelID)).participants[0].state) == .exited })
        XCTAssertEqual(try group(.inspect(id: cancelID)).participants[0].outcome?.cancellationRequested, true)
    }
}
