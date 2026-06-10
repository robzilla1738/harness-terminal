import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Proves a `DaemonClient` built with an explicit `.unix` endpoint reaches the daemon — the exact
/// mechanism the SSH tunnel relies on (it points a client at the locally-forwarded socket). Live
/// (binds a real socket), so gated behind `HARNESS_LIVE_DAEMON_TESTS`.
final class EndpointClientTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = URL(fileURLWithPath: "/tmp/hep-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
        server = DaemonServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testExplicitUnixEndpointReachesDaemon() throws {
        let endpoint = Endpoint.unix(path: HarnessPaths.socketURL.path)
        let client = DaemonClient(endpoint: endpoint)
        let pinged = waitUntil(timeout: 10) {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return true }
            return false
        }
        XCTAssertTrue(pinged, "client with an explicit .unix endpoint should reach the daemon")
    }

    func testDefaultEndpointMatchesExplicitSocketPath() {
        // The default endpoint must resolve to the same socket the daemon binds, so a plain
        // DaemonClient() and DaemonClient(endpoint: .unix(socketPath)) are equivalent.
        XCTAssertEqual(Endpoint.localControlSocket, .unix(path: HarnessPaths.socketURL.path))
    }
}
