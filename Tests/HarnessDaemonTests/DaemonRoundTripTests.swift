import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// End-to-end IPC: a real `DaemonServer` on a temp-`HARNESS_HOME` socket, driven by a
/// real `DaemonClient`. Proves the full request/response + output-streaming path.
final class DaemonRoundTripTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Short root: the Unix socket path must fit in sun_path (104 chars), which the
        // long /var/folders temp dir would overflow.
        let dir = URL(fileURLWithPath: "/tmp/hrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()

        server = DaemonServer()
        // start() resumes the accept DispatchSource on the server's own GCD queue, so
        // the server handles connections without runLoop(). (runLoop() calls
        // dispatchMain(), which would trap inside the XCTest process.)
        try server.start()
        try waitForDaemonReady()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitForDaemonReady() throws {
        let client = DaemonClient()
        for _ in 0 ..< 50 {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return }
            usleep(100_000)
        }
        XCTFail("daemon did not become ready")
    }

    func testPingMutationAndSnapshotRoundTrip() throws {
        let client = DaemonClient()
        guard case .pong = try client.request(.ping) else { return XCTFail("expected pong") }

        guard case let .workspaceID(wsID) = try client.request(.newWorkspace(name: "round-trip")) else {
            return XCTFail("expected workspaceID")
        }
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertTrue(snapshot.workspaces.contains { $0.id == wsID && $0.name == "round-trip" })
    }

    func testSubscribeReceivesSurfaceOutput() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }

        let marker = "HARNESS_STREAM_OK"
        let streamed = expectation(description: "subscriber received marker")
        streamed.assertForOverFulfill = false
        let accumulator = OutputAccumulator()
        let subscription = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { data, _ in
            if accumulator.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) {
                streamed.fulfill()
            }
        }
        defer { subscription.cancel() }

        // Give the subscription socket a moment to register, then drive output.
        usleep(200_000)
        _ = try client.request(.sendData(surfaceID: target.surfaceID, data: Data("echo \(marker)\n".utf8)))
        wait(for: [streamed], timeout: 8)
    }
}
