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
    func testOutputSearchPaginationExpiresAfterOutputChanges() throws {
        let client = DaemonClient()
        func request(_ message: IPCRequest) throws -> IPCResponse {
            do { return try client.request(message, timeout: 10) }
            catch { XCTFail("Fixture request failed: \(message): \(error)"); throw error }
        }
        guard case let .snapshot(initial) = try request(.getSnapshot), let workspace = initial.activeWorkspaceID,
              case let .tabID(tabID) = try request(.newTab(workspaceID: workspace, cwd: "/tmp", shell: "/bin/sh")),
              case let .snapshot(fresh) = try request(.getSnapshot),
              let surfaceID = fresh.workspaces.flatMap(\.sessions).flatMap(\.tabs).first(where: { $0.id == tabID })?.rootPane.allSurfaceIDs().first?.uuidString else {
            return XCTFail("No test shell")
        }
        _ = try request(.send(surfaceID: surfaceID,
            text: "i=1; while [ \"$i\" -le 130 ]; do printf '__excel_%s\\n' \"$i\"; i=$((i+1)); done\n"))
        let ready = waitUntil {
            guard case let .text(text)? = try? request(.capturePane(surfaceID: surfaceID, includeScrollback: true)) else { return false }
            return text.contains("__excel_130")
        }
        guard ready else {
            let capture = try request(.capturePane(surfaceID: surfaceID, includeScrollback: true))
            return XCTFail("Shell did not produce fixture: \(capture)")
        }
        func page(offset: Int, generation: String?) throws -> OutputSearchPage {
            let reply = try request(.searchOutput(id: UUID(), query: "__excel_", caseSensitive: true,
                sessionID: nil, offset: offset, generation: generation))
            guard case let .text(json) = reply else { throw DaemonClientError.unexpectedResponse }
            return try JSONDecoder().decode(OutputSearchPage.self, from: Data(json.utf8))
        }
        let first = try page(offset: 0, generation: nil)
        XCTAssertEqual(first.matches.count, 100)
        XCTAssertTrue(first.hasMore)
        let token = try XCTUnwrap(first.generation)
        let second = try page(offset: 100, generation: token)
        XCTAssertFalse(second.matches.isEmpty)
        XCTAssertTrue(Set(first.matches.map(\.line)).isDisjoint(with: second.matches.map(\.line)))
        let beforeChange = try page(offset: 0, generation: nil)
        _ = try request(.send(surfaceID: surfaceID, text: "printf '__changed__\\n'\n"))
        XCTAssertTrue(waitUntil {
            guard case let .text(text)? = try? request(.capturePane(surfaceID: surfaceID, includeScrollback: true)) else { return false }
            return text.contains("__changed__")
        })
        let expired = try request(.searchOutput(id: UUID(), query: "__excel_", caseSensitive: true,
            sessionID: nil, offset: 100, generation: beforeChange.generation))
        guard case let .error(message) = expired else { return XCTFail("Expected expired generation") }
        XCTAssertTrue(message.contains("expired"))
    }

}
