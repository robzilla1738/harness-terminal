import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// The daemon keeps the grid after the client leaves. A second read-only attach
/// can see it and cannot write to the child.
final class OneGridSessionTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = URL(fileURLWithPath: "/tmp/hrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
        server = DaemonServer()
        try server.start()
        let client = DaemonClient()
        let ready = waitUntil(timeout: 10) {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return true }
            return false
        }
        if !ready { XCTFail("daemon did not become ready") }
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReplaySurvivesDropAndReadOnlyAttachCannotWrite() throws {
        let marker = "HARNESS_GRID_\(UUID().uuidString.prefix(8))"
        let cwd = "/tmp"
        let client = DaemonClient()
        guard case let .snapshot(initial) = try client.request(.getSnapshot),
              let surface = initial.workspaces.flatMap(\.sessions).flatMap(\.tabs).first?.rootPane.allSurfaceIDs().first
        else { return XCTFail("no surface") }
        let surfaceID = surface.uuidString

        guard case .ok = try client.request(.updateTabCwd(surfaceID: surfaceID, path: cwd)) else {
            return XCTFail("cwd update failed")
        }
        guard case let .snapshot(seeded) = try client.request(.getSnapshot) else {
            return XCTFail("no seeded snapshot")
        }
        let seededTab = seeded.workspaces.flatMap(\.sessions).flatMap(\.tabs).first { tab in
            tab.rootPane.allSurfaceIDs().contains(surface)
        }
        guard case .hookID = try client.request(.bindHook(event: "pane-exited", source: "display-message grid-hook", condition: nil)) else {
            return XCTFail("hook bind failed")
        }

        let writer = try client.attachReplayingSurfaceOutput(
            surfaceID: surfaceID,
            label: "writer",
            onReplay: { _ in },
            onData: { _, _ in }
        )
        XCTAssertTrue(writer.sendInput(Data("printf '\(marker)\\n'\n".utf8), surfaceID: surfaceID))
        let saw = waitUntil(timeout: 8) {
            guard case let .text(text) = try? DaemonClient().request(.replayScrollback(surfaceID: surfaceID, fromSequence: nil)) else {
                return false
            }
            return text.contains(marker)
        }
        XCTAssertTrue(saw, "daemon replay should keep the line")
        writer.cancel()

        guard case .pong = try DaemonClient().request(.ping) else { return XCTFail("daemon died with the client") }

        guard case let .text(replay) = try DaemonClient().request(.replayScrollback(surfaceID: surfaceID, fromSequence: nil)) else {
            return XCTFail("no replay")
        }
        XCTAssertTrue(replay.contains(marker))

        let secret = "HARNESS_READONLY_\(UUID().uuidString.prefix(8))"
        let reader = try DaemonClient().attachReplayingSurfaceOutput(
            surfaceID: surfaceID,
            label: "reader",
            readOnly: true,
            onReplay: { text in XCTAssertTrue(text.contains(marker)) },
            onData: { _, _ in }
        )
        XCTAssertTrue(reader.sendInput(Data("printf '\(secret)\\n'\n".utf8), surfaceID: surfaceID))
        usleep(400_000)
        guard case let .text(afterWrite) = try DaemonClient().request(.replayScrollback(surfaceID: surfaceID, fromSequence: nil)) else {
            return XCTFail("no replay after read-only write")
        }
        XCTAssertFalse(afterWrite.contains(secret), "read-only attach must not reach the child")
        reader.cancel()

        guard case let .snapshot(restored) = try DaemonClient().request(.getSnapshot) else {
            return XCTFail("no snapshot")
        }
        let tab = restored.workspaces.flatMap(\.sessions).flatMap(\.tabs).first { tab in
            tab.rootPane.allSurfaceIDs().contains(surface)
        }
        XCTAssertEqual(tab?.cwd, seededTab?.cwd)
        XCTAssertEqual(tab?.currentCommand, seededTab?.currentCommand)
        guard case let .hooks(hooks) = try DaemonClient().request(.listHooks(event: nil)) else {
            return XCTFail("no hooks")
        }
        XCTAssertTrue(hooks.contains { $0.commandSource.contains("grid-hook") })
    }
}
