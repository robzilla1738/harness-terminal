import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Roadmap PR-9, daemon side: the `setOption` IPC handler rejects unknown option names (so every
/// front-end — CLI, `:` prompt, source-file — inherits the loud failure) while accepting
/// `@`-prefixed user options, which then resolve in `buildFormatContext` for `#{@name}`. Runs
/// against an isolated `HARNESS_HOME` like the other daemon tests.
final class OptionValidationDaemonTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-optval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSetOptionRejectsUnknownKey() {
        let registry = SurfaceRegistry()
        guard case let .error(message) = registry.handle(.setOption(scope: "global", target: nil, key: "moused", rawValue: "on")) else {
            return XCTFail("expected an error for an unknown option key")
        }
        XCTAssertTrue(message.contains("unknown option"), "error names the problem: \(message)")
        // A real option still sets fine.
        guard case .ok = registry.handle(.setOption(scope: "global", target: nil, key: "mouse", rawValue: "off")) else {
            return XCTFail("a known option must still set")
        }
    }

    func testUserOptionSetsAndRendersViaFormatContext() {
        let registry = SurfaceRegistry()
        guard case .ok = registry.handle(.setOption(scope: "global", target: nil, key: "@theme", rawValue: "dracula")) else {
            return XCTFail("a @user-option must be accepted")
        }
        let context = registry.buildFormatContext()
        XCTAssertEqual(context.userOptions["@theme"], "dracula")
        XCTAssertEqual(FormatString.evaluate("#{@theme}", context: context), "dracula")
    }

    /// End-to-end for the GUI's OSC 1337 `SetUserVar` path: the GUI stores user variables
    /// PANE-scoped, targeted by SURFACE key (the exact IPC shape `SessionCoordinator`
    /// sends). `#{@name}` must resolve them pane-first for that surface's context — the
    /// tab/session/global chain alone can never reach a pane-scoped value (broader-scope
    /// fallbacks only walk nil targets).
    func testPaneScopedUserOptionRendersForItsSurface() throws {
        let registry = SurfaceRegistry()
        let tab = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        let surfaceKey = try XCTUnwrap(tab.rootPane.allSurfaceIDs().first).uuidString
        guard case .ok = registry.handle(
            .setOption(scope: "pane", target: surfaceKey, key: "@deploy", rawValue: "staging")
        ) else {
            return XCTFail("a pane-scoped @user-option must be accepted")
        }
        let context = registry.buildFormatContext(surfaceKey: surfaceKey)
        XCTAssertEqual(context.userOptions["@deploy"], "staging")
        XCTAssertEqual(FormatString.evaluate("#{@deploy}", context: context), "staging")
        // The surface is the active pane, so the surfaceless context (status line,
        // display-message with no target) resolves it too.
        XCTAssertEqual(FormatString.evaluate("#{@deploy}", context: registry.buildFormatContext()), "staging")
    }

    /// Closing a surface for good GCs its pane-scoped options — without this, a loop of
    /// fresh user-variable names plus pane churn grows options.json without bound, and
    /// `#{@name}` would keep serving values for surfaces that no longer exist.
    func testClosingATabRemovesItsSurfacesPaneScopedOptions() throws {
        let registry = SurfaceRegistry()
        let wsID = try XCTUnwrap(registry.snapshot.activeWorkspaceID)
        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID from newTab")
        }
        let tab = try XCTUnwrap(
            registry.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).first { $0.id == tabID }
        )
        let surfaceKey = try XCTUnwrap(tab.rootPane.allSurfaceIDs().first).uuidString
        _ = registry.handle(.setOption(scope: "pane", target: surfaceKey, key: "@status", rawValue: "up"))
        XCTAssertEqual(registry.optionStore.get("@status", scope: .pane, target: surfaceKey)?.stringValue, "up")
        guard case .ok = registry.handle(.closeTab(tabID: tabID)) else {
            return XCTFail("closeTab must succeed")
        }
        XCTAssertNil(
            registry.optionStore.get("@status", scope: .pane, target: surfaceKey),
            "pane-scoped options must die with their surface"
        )
    }
}
