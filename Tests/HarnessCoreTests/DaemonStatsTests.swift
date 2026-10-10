import XCTest
@testable import HarnessCore

final class DaemonStatsTests: XCTestCase {
    func testProtocolCompatibilityDoesNotDependOnBuildOrder() throws {
        XCTAssertEqual(DaemonOwnership.normalizeLinuxExecutablePath("/opt/harness/HarnessDaemon (deleted)"), "/opt/harness/HarnessDaemon")
        XCTAssertEqual(DaemonOwnership.normalizeLinuxExecutablePath("/opt/harness/HarnessDaemon"), "/opt/harness/HarnessDaemon")
        func stats(build: Int?, protocolLevel: Int?, capabilities: [String]? = nil) -> DaemonStats {
            DaemonStats(pid: 1, uptimeSeconds: 0, surfaceCount: 2, totalScrollbackBytes: 0,
                        clientCount: 0, subscriberCount: 0, snapshotRevision: 0,
                        build: build, capabilities: capabilities, protocolLevel: protocolLevel)
        }
        for build in [1, HarnessVersion.build, 99999] {
            XCTAssertEqual(stats(build: build, protocolLevel: 1).compatibility, .compatible)
            XCTAssertEqual(stats(build: build, protocolLevel: 0).compatibility, .incompatible)
            XCTAssertEqual(stats(build: build, protocolLevel: 2).compatibility, .incompatible)
        }
        XCTAssertEqual(stats(build: nil, protocolLevel: nil).compatibility, .unknown)
        XCTAssertEqual(stats(build: 99999, protocolLevel: nil).compatibility, .unknown)
        XCTAssertEqual(stats(build: 132, protocolLevel: nil,
                             capabilities: [DaemonStats.attachStream]).compatibility, .compatible)
        XCTAssertEqual(stats(build: 133, protocolLevel: nil,
                             capabilities: [DaemonStats.attachStream]).compatibility, .unknown)
        XCTAssertTrue(stats(build: HarnessVersion.build, protocolLevel: 1,
                            capabilities: [DaemonStats.attachStream]).updateAvailable,
                      "a same-build daemon missing capabilities must show the pending update")
        XCTAssertFalse(stats(build: HarnessVersion.build, protocolLevel: 1,
                             capabilities: DaemonStats.currentCapabilities).updateAvailable)
        let roundTrip = try JSONDecoder().decode(DaemonStats.self, from: JSONEncoder().encode(stats(build: 1, protocolLevel: 1)))
        XCTAssertEqual(roundTrip.protocolLevel, 1)
        var owner = stats(build: HarnessVersion.build, protocolLevel: 1, capabilities: DaemonStats.currentCapabilities)
        owner.sessionHostPID = 2; owner.sessionHostBuild = HarnessVersion.build
        XCTAssertTrue(owner.sessionHostUpdateAvailable, "An old host with unknown worker protocol needs an owner update even at the same build")
        owner.sessionHostProtocolLevel = DaemonStats.currentSessionHostProtocolLevel
        XCTAssertFalse(owner.sessionHostUpdateAvailable)
        owner.sessionHostProtocolLevel = DaemonStats.currentSessionHostProtocolLevel - 1
        XCTAssertTrue(owner.sessionHostUpdateAvailable)
        owner.surfaceCount = 0; owner.pipeConsumerCount = 1
        XCTAssertFalse(owner.mayRestartWithoutInterruption, "A pending pipe drain is still owned work")
        owner.pipeConsumerCount = 0; XCTAssertTrue(owner.mayRestartWithoutInterruption)
    }
    // MARK: - Codable compatibility across daemon/client version skew

    /// A pre-handshake daemon omits `version`/`build` — the new client must decode that
    /// payload with nil fields, not fail (issue #60: old daemon, updated app/CLI).
    func testDecodingPreHandshakePayloadYieldsNilVersion() throws {
        let legacy = """
        {"pid":123,"uptimeSeconds":4.5,"surfaceCount":2,"totalScrollbackBytes":1024,
         "clientCount":1,"subscriberCount":3,"snapshotRevision":7}
        """
        let stats = try JSONDecoder().decode(DaemonStats.self, from: Data(legacy.utf8))
        XCTAssertEqual(stats.pid, 123)
        XCTAssertNil(stats.version)
        XCTAssertNil(stats.build)
    }

    /// An old client decoding a new daemon's payload ignores keys it doesn't know — the
    /// forward direction of the same skew. Simulated with an extra unknown key.
    func testDecodingToleratesUnknownKeys() throws {
        let future = """
        {"pid":1,"uptimeSeconds":0,"surfaceCount":0,"totalScrollbackBytes":0,
         "clientCount":0,"subscriberCount":0,"snapshotRevision":0,
         "version":"9.9.9","build":999,"someFutureField":true}
        """
        let stats = try JSONDecoder().decode(DaemonStats.self, from: Data(future.utf8))
        XCTAssertEqual(stats.version, "9.9.9")
        XCTAssertEqual(stats.build, 999)
    }

    func testRoundTripPreservesVersionHandshake() throws {
        let original = DaemonStats(
            pid: 42, uptimeSeconds: 10, surfaceCount: 1, totalScrollbackBytes: 2,
            clientCount: 3, subscriberCount: 4, snapshotRevision: 5,
            version: HarnessVersion.short, build: HarnessVersion.build
        )
        let decoded = try JSONDecoder().decode(DaemonStats.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.version, HarnessVersion.short)
        XCTAssertEqual(decoded.build, HarnessVersion.build)
    }

    // MARK: - Staleness predicate

    func testNilBuildIsStale() {
        let stats = DaemonStats(pid: 1, uptimeSeconds: 0, surfaceCount: 0,
                                totalScrollbackBytes: 0, clientCount: 0,
                                subscriberCount: 0, snapshotRevision: 0)
        XCTAssertTrue(stats.isStale(comparedTo: HarnessVersion.build),
                      "a daemon too old to report a build cannot be trusted to be current")
    }

    func testMatchingBuildIsFresh() {
        let stats = DaemonStats(pid: 1, uptimeSeconds: 0, surfaceCount: 0,
                                totalScrollbackBytes: 0, clientCount: 0,
                                subscriberCount: 0, snapshotRevision: 0,
                                version: "x", build: 200)
        XCTAssertFalse(stats.isStale(comparedTo: 200))
    }

    func testMismatchedBuildIsStaleInBothDirections() {
        func stats(build: Int) -> DaemonStats {
            DaemonStats(pid: 1, uptimeSeconds: 0, surfaceCount: 0,
                        totalScrollbackBytes: 0, clientCount: 0,
                        subscriberCount: 0, snapshotRevision: 0,
                        version: "x", build: build)
        }
        XCTAssertTrue(stats(build: 199).isStale(comparedTo: 200), "older daemon is stale")
        XCTAssertTrue(stats(build: 201).isStale(comparedTo: 200),
                      "newer daemon is also a mismatch — a rollback should heal to the app's build")
    }
}

extension DaemonStatsTests {
    func testWarmAndOrphanWritersAreFencedByTheProcessLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hmutator-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try DaemonMutationLease(directory: root, initiallyActive: true)
        let candidate = try DaemonMutationLease(directory: root, initiallyActive: false)
        XCTAssertTrue(active.isHeld); XCTAssertFalse(candidate.isHeld)
        XCTAssertThrowsError(try candidate.activate())
        XCTAssertThrowsError(try DaemonMutationLease(directory: root, initiallyActive: true))
        active.suspend(); try candidate.activate()
        XCTAssertThrowsError(try active.activate())
        candidate.suspend(); try active.activate()
        XCTAssertTrue(active.isHeld)
    }
}
