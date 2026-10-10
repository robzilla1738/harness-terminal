import Foundation
import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class ScheduleServiceTests: XCTestCase {
    func testDurableOccurrenceDeduplicationOverlapMissedRecoveryAndActualOutcome() throws {
        _ = testSIGPIPEIgnored
        let root = URL(fileURLWithPath: "/tmp/hsched-" + UUID().uuidString.prefix(8)); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 36, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let ledger = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: protection), owner = try OwnedWorkloadFixture(root: root); defer { owner.stop() }
        let hostID = UUID(), workspace = UUID(), base = Date(), gate = root.appendingPathComponent("gate")
        let launch = AgentLaunchSpecification(executable: "/bin/sh", arguments: ["-c", "while [ ! -f " + ShellQuoting.quote(gate.path) + " ]; do sleep 0.05; done; exit 7"], directory: root.path, profile: "fixture")
        func service() -> ScheduleService { ScheduleService(store: ledger, host: owner.client, limits: { now in UsageSummary(hostID: hostID, from: now, to: now, profiles: [], historyUnavailable: nil) }, launch: { record, occurrence in try owner.launch(record, occurrence) }) }
        let scheduler = service()
        func save(_ definition: ScheduleDefinition, revision: Int? = nil) throws -> ScheduleRecord { try JSONDecoder().decode(ScheduleRecord.self, from: scheduler.handle(.save(definition: definition, expectedRevision: revision))) }
        func occurrences(_ id: UUID) throws -> [ScheduleOccurrence] { try JSONDecoder().decode(SchedulePage.self, from: scheduler.handle(.occurrences(id: id, offset: 0, limit: 100))).occurrences }
        let once = try save(ScheduleDefinition(name: "Once", enabled: true, timezone: "America/Chicago", trigger: .once(at: base.addingTimeInterval(10)), workspaceID: workspace, launch: launch, input: "SCHEDULE_PRIVATE_STDIN_SENTINEL"))
        scheduler.tick(now: base); scheduler.tick(now: base.addingTimeInterval(10)); scheduler.tick(now: base.addingTimeInterval(10))
        let first = try XCTUnwrap(occurrences(once.id).first); XCTAssertEqual(first.state, .running); XCTAssertEqual(owner.launchCount(first.id), 1)
        let replacement = service(); replacement.tick(now: base.addingTimeInterval(11)); XCTAssertEqual(owner.launchCount(first.id), 1, "Replacement never replays accepted work")
        XCTAssertThrowsError(try save(once.definition), "Duplicate create requires a reviewed revision")
        let event = try save(ScheduleDefinition(name: "Turn", enabled: true, timezone: "America/Chicago", trigger: .agentEvent(kind: .turnCompleted, surfaceID: nil, provider: .codex, profile: nil), workspaceID: workspace, launch: launch))
        var run = AgentRun(hostID: hostID, surfaceID: UUID().uuidString, processGeneration: "fixture", pid: nil, provider: .codex, at: base); try ledger.save(run)
        let completed = RunEvent(runID: run.id, kind: .turnCompleted, source: .hook, at: base.addingTimeInterval(12), turnID: "turn1")
        XCTAssertTrue(try ledger.record(completed, reducing: &run)); scheduler.tick(now: base.addingTimeInterval(12))
        let eventFirst = try XCTUnwrap(occurrences(event.id).first); XCTAssertEqual(eventFirst.state, .running)
        XCTAssertFalse(try ledger.record(completed, reducing: &run)); scheduler.tick(now: base.addingTimeInterval(13)); XCTAssertEqual(try occurrences(event.id).count, 1)
        _ = try ledger.record(RunEvent(runID: run.id, kind: .turnCompleted, source: .hook, at: base.addingTimeInterval(14), turnID: "turn2"), reducing: &run)
        scheduler.tick(now: base.addingTimeInterval(14)); XCTAssertTrue(try occurrences(event.id).contains { $0.state == .skippedOverlap }); XCTAssertEqual(owner.launchCount(eventFirst.id), 1)
        let missed = try save(ScheduleDefinition(name: "Missed", enabled: true, timezone: "UTC", trigger: .once(at: base.addingTimeInterval(20)), workspaceID: workspace, launch: launch))
        scheduler.tick(now: base.addingTimeInterval(100)); XCTAssertEqual(try occurrences(missed.id).first?.state, .missed)
        let missedID = try XCTUnwrap(occurrences(missed.id).first?.id); XCTAssertEqual(owner.launchCount(missedID), 0)
        try Data().write(to: gate)
        XCTAssertTrue(waitUntil { if case let .workloadOutcome(outcome) = try? owner.client.request(.workloadOutcome(first.id)) { return outcome?.state == .exited }; return false })
        scheduler.tick(now: base.addingTimeInterval(101)); XCTAssertEqual(try occurrences(once.id).first?.state, .exited); XCTAssertEqual(try occurrences(once.id).first?.outcome?.exitCode, 7)
        let disk = try Data(contentsOf: root.appendingPathComponent("activity.sqlite")) + ((try? Data(contentsOf: root.appendingPathComponent("activity.sqlite-wal"))) ?? Data())
        #if os(macOS)
        XCTAssertNil(String(decoding: disk, as: UTF8.self).range(of: "SCHEDULE_PRIVATE_STDIN_SENTINEL"))
        #endif
        var reset = once.definition; reset.id = UUID(); reset.trigger = .limitReset(profileID: UUID(), window: "primary", acceptPredictedTime: false)
        XCTAssertThrowsError(try save(reset), "Predicted reset execution requires explicit consent")
        let unavailable = ActivityStore(url: root.appendingPathComponent("locked.sqlite"), protection: .unavailable("Fixture key unavailable"))
        let blocked = ScheduleService(store: unavailable, host: owner.client, limits: { _ in throw ScheduleError.unavailable("Fixture") }, launch: { _, _ in XCTFail("Unavailable history must not execute"); return nil })
        XCTAssertThrowsError(try blocked.handle(.save(definition: once.definition, expectedRevision: nil))); blocked.tick(now: base)
    }
}
