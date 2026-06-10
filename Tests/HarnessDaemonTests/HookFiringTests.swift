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

    // MARK: - Session/window lifecycle events (tmux parity P4)

    func testSessionLifecycleHooksFire() throws {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!

        let created = "HOOK_SESSION_CREATED_\(UUID().uuidString.prefix(8))"
        let (createdExp, createdToken) = expectNotification(containing: created)
        defer { NotificationCenter.default.removeObserver(createdToken) }
        _ = registry.handle(.bindHook(event: "session-created", source: "display-message \"\(created)\"", condition: nil))

        guard case let .sessionID(sessionID) = registry.handle(.newSession(workspaceID: wsID, cwd: "/tmp", name: "p4")) else {
            return XCTFail("expected sessionID")
        }
        wait(for: [createdExp], timeout: 5)

        let renamed = "HOOK_SESSION_RENAMED_\(UUID().uuidString.prefix(8))"
        let (renamedExp, renamedToken) = expectNotification(containing: renamed)
        defer { NotificationCenter.default.removeObserver(renamedToken) }
        _ = registry.handle(.bindHook(event: "session-renamed", source: "display-message \"\(renamed)\"", condition: nil))
        _ = registry.handle(.renameSession(sessionID: sessionID, name: "p4-renamed"))
        wait(for: [renamedExp], timeout: 5)

        let closed = "HOOK_SESSION_CLOSED_\(UUID().uuidString.prefix(8))"
        let (closedExp, closedToken) = expectNotification(containing: closed)
        defer { NotificationCenter.default.removeObserver(closedToken) }
        _ = registry.handle(.bindHook(event: "session-closed", source: "display-message \"\(closed)\"", condition: nil))
        _ = registry.handle(.closeSession(sessionID: sessionID))
        wait(for: [closedExp], timeout: 5)
    }

    func testWindowRenameAndLayoutHooksFire() throws {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }

        let renamed = "HOOK_WINDOW_RENAMED_\(UUID().uuidString.prefix(8))"
        let (renamedExp, renamedToken) = expectNotification(containing: renamed)
        defer { NotificationCenter.default.removeObserver(renamedToken) }
        _ = registry.handle(.bindHook(event: "window-renamed", source: "display-message \"\(renamed)\"", condition: nil))
        _ = registry.handle(.renameTab(tabID: tabID, name: "p4-tab"))
        wait(for: [renamedExp], timeout: 5)

        // Layout change needs ≥2 panes.
        let tab = registry.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).first { $0.id == tabID }!
        let paneID = tab.rootPane.allPaneIDs().first!
        _ = registry.handle(.newSplit(tabID: tabID, paneID: paneID, direction: .horizontal, shell: nil))

        let layout = "HOOK_LAYOUT_CHANGED_\(UUID().uuidString.prefix(8))"
        let (layoutExp, layoutToken) = expectNotification(containing: layout)
        defer { NotificationCenter.default.removeObserver(layoutToken) }
        _ = registry.handle(.bindHook(event: "window-layout-changed", source: "display-message \"\(layout)\"", condition: nil))
        _ = registry.handle(.applyLayout(tabID: tabID, layout: "even-horizontal", mainPaneID: nil))
        wait(for: [layoutExp], timeout: 5)
    }

    /// `#{session_name}` in a session-closed hook must describe the session that
    /// CLOSED (context captured pre-mutation), not whatever survives it.
    func testSessionClosedHookFormatsClosedSessionName() throws {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        guard case let .sessionID(doomed) = registry.handle(.newSession(workspaceID: wsID, cwd: "/tmp", name: "doomed-session")) else {
            return XCTFail("expected sessionID")
        }
        // Another session takes focus, so the active chain differs from the subject.
        guard case .sessionID = registry.handle(.newSession(workspaceID: wsID, cwd: "/tmp", name: "survivor")) else {
            return XCTFail("expected sessionID")
        }

        let marker = "HOOK_CLOSED_NAME_\(UUID().uuidString.prefix(8))"
        let exp = expectation(description: "session-closed formats the closed session")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            guard let n = note.userInfo?["notification"] as? AgentNotification,
                  n.body.contains(marker) else { return }
            XCTAssertTrue(n.body.contains("doomed-session"),
                          "hook context must be the closed session, got: \(n.body)")
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = registry.handle(.bindHook(
            event: "session-closed", source: "display-message \"\(marker):#{session_name}\"", condition: nil
        ))
        _ = registry.handle(.closeSession(sessionID: doomed))
        wait(for: [exp], timeout: 5)
    }

    /// Targeted renames (`rename-window -t <non-active>`) must format against the
    /// RENAMED tab — the resolving() focus-fallback misroute class.
    func testWindowRenamedHookFormatsRenamedTab() throws {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        guard case let .tabID(background) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }
        // Focus moves to a NEWER tab; `background` is no longer active.
        guard case .tabID = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }

        let marker = "HOOK_RENAMED_NAME_\(UUID().uuidString.prefix(8))"
        let exp = expectation(description: "window-renamed formats the renamed tab")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            guard let n = note.userInfo?["notification"] as? AgentNotification,
                  n.body.contains(marker) else { return }
            XCTAssertTrue(n.body.contains("background-renamed"),
                          "hook context must be the renamed tab, got: \(n.body)")
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = registry.handle(.bindHook(
            event: "window-renamed", source: "display-message \"\(marker):#{window_name}\"", condition: nil
        ))
        _ = registry.handle(.renameTab(tabID: background, name: "background-renamed"))
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

    // MARK: - Focus / active-pane events (roadmap PR-17)

    func testActivePaneChangeFiresFocusHooks() throws {
        let registry = SurfaceRegistry()
        guard let tab = registry.snapshot.activeWorkspace?.activeTab,
              let first = tab.rootPane.allPaneIDs().first else { return XCTFail("no tab/pane") }
        // Split so there are two panes (the new split becomes active); selecting `first` then
        // changes the active pane and should fire the focus-out / changed / focus-in trio.
        _ = registry.handle(.newSplit(tabID: tab.id, paneID: first, direction: .horizontal, shell: nil))

        let changed = "HOOK_PANE_CHANGED_\(UUID().uuidString.prefix(8))"
        let focusIn = "HOOK_FOCUS_IN_\(UUID().uuidString.prefix(8))"
        let focusOut = "HOOK_FOCUS_OUT_\(UUID().uuidString.prefix(8))"
        let (cExp, cTok) = expectNotification(containing: changed)
        let (iExp, iTok) = expectNotification(containing: focusIn)
        let (oExp, oTok) = expectNotification(containing: focusOut)
        defer { [cTok, iTok, oTok].forEach(NotificationCenter.default.removeObserver) }
        _ = registry.handle(.bindHook(event: "window-pane-changed", source: "display-message \"\(changed)\"", condition: nil))
        _ = registry.handle(.bindHook(event: "pane-focus-in", source: "display-message \"\(focusIn)\"", condition: nil))
        _ = registry.handle(.bindHook(event: "pane-focus-out", source: "display-message \"\(focusOut)\"", condition: nil))

        _ = registry.handle(.selectPane(tabID: tab.id, paneID: first))
        wait(for: [cExp, iExp, oExp], timeout: 5)
    }

    // MARK: - command-error (roadmap PR-17)

    func testCommandErrorHookFiresOnUnresolvedHookCommand() throws {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        let marker = "HOOK_CMD_ERROR_\(UUID().uuidString.prefix(8))"
        let (exp, tok) = expectNotification(containing: marker)
        defer { NotificationCenter.default.removeObserver(tok) }
        // The command-error hook surfaces the failing command via `#{hook}`.
        _ = registry.handle(.bindHook(event: "command-error", source: "display-message \"\(marker) #{hook}\"", condition: nil))
        // An after-new-tab hook whose command targets a non-existent pane → unresolved → fires command-error.
        _ = registry.handle(.bindHook(
            event: "after-new-tab",
            source: "kill-pane -t %00000000-0000-0000-0000-000000000000", condition: nil
        ))
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        wait(for: [exp], timeout: 5)
    }

    /// Tripwire: every `HookEvent` must have a firing test in the suite. Adding an event without a
    /// test trips this assertion (the events fired only by timing — alert-* — are exercised by the
    /// monitoring tests and listed here as covered).
    func testEveryHookEventHasAFiringTest() {
        let covered: Set<HookEvent> = [
            .afterNewTab, .afterNewSession, .afterKillTab, .afterSplitPane, .afterKillPane,
            .afterResizePane, .paneExited, .clientAttached, .clientDetached, .agentStateChanged,
            .notificationPosted, .paneActivity, .paneSilence, .paneBell, .sessionCreated,
            .sessionRenamed, .sessionClosed, .windowRenamed, .windowLinked, .windowUnlinked,
            .windowLayoutChanged, .commandError, .paneFocusIn, .paneFocusOut, .windowPaneChanged,
        ]
        XCTAssertEqual(Set(HookEvent.allCases), covered,
                       "a new HookEvent was added — give it a firing test and list it here")
    }
}
