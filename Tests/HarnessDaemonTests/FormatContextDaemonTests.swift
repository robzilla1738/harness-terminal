import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Daemon-side extended format-context fields: the PTY-backed values (`pane_pid`,
/// `pane_current_command`, `pane_width/height`, `history_bytes`) and the metadata scan's
/// `currentCommand` commit. Runs against an isolated `HARNESS_HOME` like `SurfaceRegistryTests`.
final class FormatContextDaemonTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-fmtctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testBuildFormatContextFillsPTYBackedFields() throws {
        try skipUnlessLiveDaemonTests()
        let registry = SurfaceRegistry()
        guard case let .surfaces(list) = registry.handle(.listSurfaces), let surface = list.first else {
            return XCTFail("expected a seeded surface")
        }
        // Give the spawned shell a beat to come up so the foreground pgrp exists.
        usleep(300_000)
        let context = registry.buildFormatContext(surfaceKey: surface.surfaceID)

        XCTAssertGreaterThan(context.panePID ?? 0, 0, "pane_pid must be the live shell PID")
        XCTAssertFalse(
            context.paneCurrentCommand?.isEmpty ?? true,
            "pane_current_command must name the foreground process"
        )
        // Spawn size is the 24×80 placeholder until a client votes.
        XCTAssertEqual(context.paneWidth, 80)
        XCTAssertEqual(context.paneHeight, 24)
        XCTAssertEqual(context.paneDead, false)
        XCTAssertNotNil(context.historyBytes)
        XCTAssertNotNil(context.sessionID)
        XCTAssertNotNil(context.windowID)
        XCTAssertEqual(context.windowPanes, 1)
        XCTAssertEqual(context.sessionWindows, 1)
        XCTAssertEqual(context.serverPID, Int(getpid()))
        // Rendered IDs carry the target-grammar prefixes.
        let rendered = FormatString.evaluate("#{session_id}", context: context)
        XCTAssertTrue(rendered.hasPrefix("$"))
    }

    func testMetadataScanCommitsCurrentCommand() throws {
        try skipUnlessLiveDaemonTests()
        let registry = SurfaceRegistry()
        guard case let .surfaces(list) = registry.handle(.listSurfaces), let surface = list.first else {
            return XCTFail("expected a seeded surface")
        }
        // The scan only commits when the probe succeeds — poll a few cycles like the
        // daemon's own ~1.5s timer would.
        var command: String?
        waitUntil(timeout: 8) {
            registry.refreshSurfaceMetadata()
            command = registry.snapshot.workspaces
                .flatMap(\.sessions).flatMap(\.tabs)
                .first { $0.rootPane.allSurfaceIDs().map(\.uuidString).contains(surface.surfaceID) }?
                .currentCommand
            return command?.isEmpty == false
        }
        XCTAssertFalse(command?.isEmpty ?? true, "scan never committed a foreground command")
    }

    /// `#{pane_active}` must reflect whether the named surface IS its tab's active pane —
    /// not merely that a surface was named. Hooks routinely build a context around a
    /// BACKGROUND pane (alert/bell, agent-state, pane-exited), where the pre-fix
    /// `surfaceKey != nil` wrongly rendered "1" for every one of them.
    func testPaneActiveReflectsActivePaneNotMerePresence() throws {
        let registry = SurfaceRegistry()
        let tab = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        let firstPaneID = try XCTUnwrap(tab.rootPane.allPaneIDs().first)

        guard case let .paneID(newPaneID) = registry.handle(
            .newSplit(tabID: tab.id, paneID: firstPaneID, direction: .vertical)
        ) else {
            return XCTFail("expected paneID from split")
        }

        // Re-read the tab and let it name whichever pane the split left active — the test
        // must not assume the split's focus policy, only that exactly one pane is active.
        let split = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(split.rootPane.allPaneIDs().count, 2)
        let activePaneID = try XCTUnwrap(split.activePaneID)
        let backgroundPaneID = try XCTUnwrap(split.rootPane.allPaneIDs().first { $0 != activePaneID })
        XCTAssertTrue([firstPaneID, newPaneID].contains(activePaneID))

        let activeSurface = try XCTUnwrap(surfaceID(forPaneID: activePaneID, in: registry.snapshot))
        let backgroundSurface = try XCTUnwrap(surfaceID(forPaneID: backgroundPaneID, in: registry.snapshot))

        let activeCtx = registry.buildFormatContext(surfaceKey: activeSurface.uuidString)
        let backgroundCtx = registry.buildFormatContext(surfaceKey: backgroundSurface.uuidString)

        XCTAssertEqual(FormatString.evaluate("#{pane_active}", context: activeCtx), "1")
        XCTAssertEqual(
            FormatString.evaluate("#{pane_active}", context: backgroundCtx), "0",
            "a background pane must not report pane_active=1"
        )
    }

    private func surfaceID(forPaneID paneID: PaneID, in snapshot: SessionSnapshot) -> SurfaceID? {
        snapshot.workspaces
            .flatMap { $0.sessions.flatMap(\.tabs) }
            .flatMap { $0.rootPane.allLeaves() }
            .first { $0.id == paneID }?
            .surfaceID
    }
}
