import XCTest
import HarnessCore
@testable import HarnessDaemonCore

private final class Fixture: @unchecked Sendable {
    let store: WorkloadOutcomeStore
    let queue = DispatchQueue(label: "outcomes.fixture")
    init(store: WorkloadOutcomeStore) { self.store = store }
    func reaped(_ id: UUID, stream: String, generation: UInt64, status: Int32?) {
        queue.sync { store.reaped(id, stream: stream, generation: generation, status: status) }
    }
}
final class WorkloadOutcomeTests: XCTestCase {
    func testFastChildrenAlwaysProduceTheirActualExitOutcome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hfast-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var children: [RealPty] = []
        defer { for child in children { child.close() } }
        let completed = expectation(description: "Fast children reaped across watcher registration")
        completed.expectedFulfillmentCount = 16
        for index in 0..<16 {
            let child = try RealPty(id: UUID().uuidString, cwd: home.path, shell: "/bin/sh", rows: 24, cols: 80,
                scrollbackBytes: 65536, launchArgumentsOverride: ["-c", index.isMultiple(of: 2) ? "exit 7" : "sleep 0.001; exit 7"], initialStandardInput: Data())
            child.onReaped = { _, status in
                XCTAssertEqual(status, 7)
                completed.fulfill()
            }
            children.append(child)
            child.start()
        }
        wait(for: [completed], timeout: 15)
        for child in children { XCTAssertEqual(child.ownedChildCount, 0) }
    }

    func testActualExitReceiptAndHostInterruptionNeverRelaunch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("houtcomes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("outcomes.json"), surface = UUID().uuidString, id = UUID()
        let store = WorkloadOutcomeStore(url: url)
        try store.reserve(id, surfaceID: surface)
        let pty = try RealPty(id: surface, cwd: home.path, shell: "/bin/sh", rows: 24, cols: 80,
                             scrollbackBytes: 65536, launchArgumentsOverride: ["-c", "sleep 0.4; exit 7"], initialStandardInput: Data())
        defer { pty.close() }
        let stream = pty.streamIdentity
        store.launched(id, pty: pty)
        XCTAssertEqual(store.read(id)?.state, .running)
        // Loading a fresh owner cannot infer that a recorded process survived.
        let interrupted = WorkloadOutcomeStore(url: url)
        XCTAssertEqual(interrupted.read(id)?.state, .unknown)
        XCTAssertThrowsError(try interrupted.reserve(id, surfaceID: surface))
        let liveURL = home.appendingPathComponent("live.json")
        let live = WorkloadOutcomeStore(url: liveURL)
        try live.reserve(id, surfaceID: surface); live.launched(id, pty: pty)
        let fixture = Fixture(store: live)
        let reaped = expectation(description: "Owned workload actually reaped")
        pty.onReaped = { gen, status in fixture.reaped(id, stream: stream, generation: gen, status: status); reaped.fulfill() }
        pty.start(); wait(for: [reaped], timeout: 4)
        XCTAssertEqual(live.read(id)?.state, .exited); XCTAssertEqual(live.read(id)?.exitCode, 7)
        interrupted.maintain()
        XCTAssertEqual(interrupted.read(id)?.state, .unknown)
        XCTAssertNotNil(interrupted.read(id)?.processAbsentObservedAt)
        XCTAssertNil(interrupted.read(id)?.exitCode, "Proven absence does not invent an exit result")
        XCTAssertFalse(interrupted.read(id)?.mayBeRunning ?? true)
        let parked = home.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: home, to: parked)
        live.reaped(id, stream: stream, generation: try XCTUnwrap(live.read(id)?.processGeneration), status: 7)
        XCTAssertTrue(live.read(id)?.storageUnavailable == true)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
        try FileManager.default.moveItem(at: parked, to: home)
        live.maintain()
        XCTAssertFalse(live.read(id)?.storageUnavailable ?? true, "A transient write failure recovers only against the unchanged owned catalog")
        let recovered = WorkloadOutcomeStore(url: liveURL)
        XCTAssertEqual(recovered.read(id)?.exitCode, 7)
        XCTAssertThrowsError(try recovered.reserve(id, surfaceID: surface))
        let unrelated = UUID()
        XCTAssertThrowsError(try recovered.requestCancellation(unrelated))
        XCTAssertThrowsError(try recovered.reserve(id, surfaceID: UUID().uuidString))
    }
}
