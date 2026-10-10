import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class ActivityStoreTests: XCTestCase {
    private func protection() throws -> HistoryProtection {
        #if os(macOS)
        return try HistoryProtection(keyMaterial: Data(repeating: 83, count: 32))
        #else
        return .system()
        #endif
    }
    func testDurableTurnsDeduplicationEncryptionAndLeaseHandover() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("activity.sqlite"), key = try protection()
        let store = ActivityStore(url: url, protection: key)
        XCTAssertNil(store.availability)
        var run = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "pid:start1", pid: 123, provider: .claudeCode)
        run.conversationID = "private-conversation-identifier"
        try store.save(run)
        let turn = RunEvent(runID: run.id, kind: .turnCompleted, source: .hook, turnID: "private-turn", message: "confidential captured output")
        XCTAssertTrue(try store.record(turn, reducing: &run))
        XCTAssertFalse(try store.record(turn, reducing: &run))
        XCTAssertEqual(run.process, .running)
        XCTAssertEqual(run.turn, .completed)
        var heuristic = RunEvent(runID: run.id, kind: .turnStarted, source: .process)
        heuristic.at = turn.at.addingTimeInterval(1)
        XCTAssertTrue(try store.record(heuristic, reducing: &run))
        XCTAssertEqual(run.turn, .completed)
        var attention = RunEvent(runID: run.id, kind: .attention, source: .hook, message: "same message")
        attention.at = heuristic.at.addingTimeInterval(1)
        XCTAssertTrue(try store.record(attention, reducing: &run))
        attention.id = UUID()
        XCTAssertTrue(try store.record(attention, reducing: &run))
        XCTAssertEqual(try store.events(runID: run.id).count, 4)
        try store.flush()
        #if os(macOS)
        for file in try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("confidential captured output".utf8)))
            XCTAssertNil(bytes.range(of: Data("private-conversation-identifier".utf8)))
            XCTAssertNil(bytes.range(of: Data("private-turn".utf8)))
        }
        #endif
        let candidate = ActivityStore(url: url, protection: key, writable: false)
        XCTAssertEqual(try candidate.run(run.id)?.turn, .completed)
        XCTAssertThrowsError(try candidate.save(run))
        try store.suspend(); try candidate.activate()
        XCTAssertThrowsError(try store.save(run))
        var exit = RunEvent(runID: run.id, kind: .processExited, source: .exit)
        exit.at = attention.at.addingTimeInterval(1)
        XCTAssertTrue(try candidate.record(exit, reducing: &run))
        XCTAssertEqual(try candidate.run(run.id)?.process, .exited)
        try candidate.removeCapturedText(surfaceID: run.surfaceID)
        XCTAssertNil(try candidate.run(run.id)?.conversationID)
        XCTAssertEqual(try candidate.events(runID: run.id).count, 0)
    }
    #if os(macOS)
    func testRecoveryRefusesWrongKeyBeforeImportingAndPreservesMemory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("activity.sqlite")
        let original = ActivityStore(url: url, protection: try protection())
        let old = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "old", pid: 2, provider: .codex)
        try original.save(old); try original.suspend()
        let locked = ActivityStore(url: url, protection: .unavailable("Locked"))
        let new = AgentRun(hostID: old.hostID, surfaceID: UUID().uuidString, processGeneration: "new", pid: 3, provider: .codex)
        try locked.save(new)
        XCTAssertThrowsError(try locked.recover(protection: HistoryProtection(keyMaterial: Data(repeating: 98, count: 32))))
        XCTAssertNotNil(try locked.run(new.id))
        let untouched = ActivityStore(url: url, protection: try protection(), writable: false)
        XCTAssertNotNil(try untouched.run(old.id)); XCTAssertNil(try untouched.run(new.id))
        try locked.recover(protection: try protection())
        XCTAssertNotNil(try locked.run(old.id)); XCTAssertNotNil(try locked.run(new.id))
    }
    #endif

    func testAtomicCountersCursorsRetentionAndUnavailableKey() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("activity.sqlite")
        let store = ActivityStore(url: url, protection: try protection())
        let cursor = try LedgerObject(kind: "cursor", id: "file", value: 32)
        var invalid = try LedgerObject(kind: "usage", id: "account", value: 100)
        invalid.data = Data(repeating: 65, count: (64 << 20) + 1)
        XCTAssertThrowsError(try store.saveObjects([cursor, invalid]))
        XCTAssertNil(try store.object(Int.self, kind: "cursor", id: "file"))
        try store.saveObjects([cursor, LedgerObject(kind: "usage", id: "account", value: 100)])
        XCTAssertEqual(try store.object(Int.self, kind: "cursor", id: "file"), 32)
        let now = Date()
        let active = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "active", pid: 2, provider: .codex, at: now.addingTimeInterval(-30 * 86400))
        var closed = active; closed.id = UUID(); closed.endedAt = now.addingTimeInterval(-15 * 86400); closed.process = .exited
        try store.save(active); try store.save(closed); try store.prune(now: now)
        XCTAssertNotNil(try store.run(active.id)); XCTAssertNil(try store.run(closed.id))
        let unavailableURL = home.appendingPathComponent("locked.sqlite")
        let unavailable = ActivityStore(url: unavailableURL, protection: .unavailable("Locked"))
        try unavailable.save(active)
        XCTAssertNotNil(unavailable.availability)
        XCTAssertNotNil(try unavailable.run(active.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailableURL.path))
    }
}
