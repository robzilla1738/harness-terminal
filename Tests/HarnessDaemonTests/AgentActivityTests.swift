import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class AgentActivityTests: XCTestCase {
    func testAuthoritativeProfilePromotesTheObservedExecutionWithoutDuplicatingIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hactivity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 76, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let store = ActivityStore(url: home.appendingPathComponent("activity.sqlite"), protection: protection)
        let service = AgentActivityService(store: store, hostID: UUID())
        defer { try? service.suspend() }
        let surface = UUID().uuidString, now = Date(), pid = ProcessInfo.processInfo.processIdentifier
        let generation = try XCTUnwrap(ProcessScan.generation(pid))
        service.observe(surfaceID: surface, paneID: nil, snapshot: AgentSnapshot(kind: .claudeCode, executable: "claude", pid: pid), at: now)
        service.drain()
        let initial = try XCTUnwrap(service.currentRun(surfaceID: surface))
        service.observeOSC(surfaceID: surface, state: "working", message: nil, sequence: 10); service.drain()
        let observation = try ProviderHookAdapter.parse(Data(#"{"hook_event_name":"Stop","session_id":"conversation","prompt_id":"turn"}"#.utf8), contract: .claude202610, at: now.addingTimeInterval(1))
        let report = HookReport(surfaceID: surface, senderPID: pid, profile: "work", observation: observation)
        let run = try service.report(report, paneID: nil, generation: generation, pid: pid, sequence: 20)
        XCTAssertEqual(run.id, initial.id); XCTAssertEqual(run.profile, "work"); XCTAssertEqual(run.profileSource, .hook)
        XCTAssertEqual(run.turn, .completed); XCTAssertEqual(run.process, .running)
        XCTAssertEqual(try store.list(activeOnly: true).runs.count, 1)
        _ = try service.report(report, paneID: nil, generation: generation, pid: pid, sequence: 20)
        XCTAssertEqual(try store.events(runID: run.id).filter { $0.kind == .turnCompleted }.count, 1)
        var conflicting = report; conflicting.profile = "different"
        XCTAssertThrowsError(try service.report(conflicting, paneID: nil, generation: generation, pid: pid, sequence: 21))
        XCTAssertEqual(try store.list(activeOnly: true).runs.count, 1)
        XCTAssertEqual(service.currentRun(surfaceID: surface)?.id, initial.id)
    }
    func testProcessExitIsRecordedAfterPaneObservationStops() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hactivity-exit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 77, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let store = ActivityStore(url: home.appendingPathComponent("activity.sqlite"), protection: protection)
        let service = AgentActivityService(store: store, hostID: UUID())
        defer { try? service.suspend() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.3; exit 7"]; try process.run()
        let surface = UUID().uuidString
        service.observe(surfaceID: surface, paneID: nil, snapshot: AgentSnapshot(kind: .codex, executable: "codex", pid: process.processIdentifier))
        service.drain(); let run = try XCTUnwrap(service.currentRun(surfaceID: surface))
        // No more pane scans, OSC events or hooks are delivered.
        process.waitUntilExit()
        let deadline = Date().addingTimeInterval(4)
        while service.currentRun(surfaceID: surface) != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertNil(service.currentRun(surfaceID: surface))
        XCTAssertEqual(try store.run(run.id)?.process, .exited)
        XCTAssertEqual(try store.events(runID: run.id).filter { $0.kind == .processExited }.count, 1)
    }

}
