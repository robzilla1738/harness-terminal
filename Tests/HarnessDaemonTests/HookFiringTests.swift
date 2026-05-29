import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Hooks were previously inert (`fire()`/`setExecutor` had no call sites). These drive
/// `SurfaceRegistry.handle` and assert that bound hooks actually fire their commands.
/// Each test uses an isolated `HARNESS_HOME` and a unique marker so the shared
/// `NotificationBus` can't bleed between tests. Creating a registry forks the default
/// snapshot's shell (same as `SurfaceRegistryTests`).
final class HookFiringTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Observe the notification bus for a `display-message` whose body contains `marker`.
    private func expectNotification(containing marker: String) -> (XCTestExpectation, NSObjectProtocol) {
        let exp = expectation(description: "hook display-message \(marker)")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            if let n = note.userInfo?["notification"] as? AgentNotification, n.body.contains(marker) {
                exp.fulfill()
            }
        }
        return (exp, token)
    }

    func testAfterNewTabHookFiresDisplayMessage() throws {
        let registry = SurfaceRegistry()
        let marker = "HOOK_AFTER_NEW_TAB_\(UUID().uuidString.prefix(8))"
        let (exp, token) = expectNotification(containing: marker)
        defer { NotificationCenter.default.removeObserver(token) }

        guard case .hookID = registry.handle(.bindHook(
            event: "after-new-tab", source: "display-message \"\(marker)\"", condition: nil
        )) else { return XCTFail("expected hookID") }

        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        wait(for: [exp], timeout: 5)
    }

    func testHookConditionTrueFires() throws {
        let registry = SurfaceRegistry()
        let marker = "HOOK_COND_TRUE_\(UUID().uuidString.prefix(8))"
        let (exp, token) = expectNotification(containing: marker)
        defer { NotificationCenter.default.removeObserver(token) }

        _ = registry.handle(.bindHook(
            event: "after-new-tab", source: "display-message \"\(marker)\"", condition: "1"
        ))
        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        wait(for: [exp], timeout: 5)
    }

    func testHookConditionFalseDoesNotFire() throws {
        let registry = SurfaceRegistry()
        let marker = "HOOK_COND_FALSE_\(UUID().uuidString.prefix(8))"
        let exp = expectation(description: "no notification with \(marker)")
        exp.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            if let n = note.userInfo?["notification"] as? AgentNotification, n.body.contains(marker) {
                exp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Condition "0" is falsey → command must be skipped.
        _ = registry.handle(.bindHook(
            event: "after-new-tab", source: "display-message \"\(marker)\"", condition: "0"
        ))
        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        wait(for: [exp], timeout: 1.5)
    }

    func testUnboundHookDoesNotFire() throws {
        let registry = SurfaceRegistry()
        let marker = "HOOK_UNBOUND_\(UUID().uuidString.prefix(8))"
        let exp = expectation(description: "no notification after unbind \(marker)")
        exp.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            if let n = note.userInfo?["notification"] as? AgentNotification, n.body.contains(marker) {
                exp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard case let .hookID(id) = registry.handle(.bindHook(
            event: "after-new-tab", source: "display-message \"\(marker)\"", condition: nil
        )) else { return XCTFail("expected hookID") }
        guard case .ok = registry.handle(.unbindHook(id: id)) else { return XCTFail("expected ok") }

        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        wait(for: [exp], timeout: 1.5)
    }
}
