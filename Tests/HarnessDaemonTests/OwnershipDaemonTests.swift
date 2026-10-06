import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Owner sizing through a real daemon socket. A one-shot `take-surface` names a
/// client that stays subscribed; the calling socket has no vote and must fail.
final class OwnershipDaemonTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        _ = testSIGPIPEIgnored
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = URL(fileURLWithPath: "/tmp/hrt-own-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
        server = DaemonServer()
        try server.start()
        let client = DaemonClient()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? client.request(.ping)).map { if case .pong = $0 { return true } else { return false } } ?? false
        })
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTakeNamesAConnectedClientAndAFreshSocketDoesNot() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID
        _ = try client.request(.setSurfaceSizeMode(.owner))

        let output = OutputAccumulator()
        let wide = try client.subscribeSurfaceOutput(surfaceID: sid, label: "wide") { data, _ in
            _ = output.appendAndContains(String(decoding: data, as: UTF8.self), marker: "")
        }
        let narrow = try client.subscribeSurfaceOutput(surfaceID: sid, label: "narrow") { _, _ in }
        defer { wide.cancel(); narrow.cancel() }
        usleep(200_000)

        wide.resize(sid, rows: 40, cols: 120)
        narrow.resize(sid, rows: 24, cols: 80)
        usleep(300_000)
        var size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 40)
        XCTAssertEqual(size?.cols, 120)

        let denied = try DaemonClient().request(.takeSurface(surfaceID: sid, clientID: nil))
        guard case .error = denied else {
            return XCTFail("a socket with no vote must not take ownership: \(denied)")
        }

        guard case let .clients(rows) = try client.request(.listClients),
              let narrowClient = rows.first(where: { $0.label == "narrow" })
        else { return XCTFail("narrow subscriber was not registered") }

        let taken = try DaemonClient().request(.takeSurface(surfaceID: sid, clientID: narrowClient.id))
        guard case .ok = taken else { return XCTFail("take by the connected client failed: \(taken)") }
        usleep(300_000)
        size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 24, "ownership moves the PTY to the named client's size")
        XCTAssertEqual(size?.cols, 80)

        narrow.cancel()
        usleep(300_000)
        size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 40, "when the owner disconnects, the other client takes over")
        XCTAssertEqual(size?.cols, 120)
    }

    private func queryPTYSize(
        _ client: DaemonClient,
        surfaceID: String,
        output: OutputAccumulator,
        timeout: TimeInterval = 8
    ) throws -> (rows: Int, cols: Int)? {
        let nonce = "SZQ\(UUID().uuidString.prefix(8))"
        _ = try client.request(.sendData(surfaceID: surfaceID, data: Data("echo \(nonce); stty size\n".utf8)))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = output.snapshot
            if let nonceRange = text.range(of: "\(nonce)\r\n") ?? text.range(of: "\(nonce)\n") {
                let after = text[nonceRange.upperBound...]
                for line in after.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                    let parts = line.split(separator: " ")
                    if parts.count == 2, let rows = Int(parts[0]), let cols = Int(parts[1]) {
                        return (rows, cols)
                    }
                }
            }
            usleep(100_000)
        }
        XCTFail("stty size did not arrive: \(output.snapshot.suffix(400))")
        return nil
    }
}
