import XCTest
@testable import HarnessCore

final class SessionPersistenceTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        // Isolate HARNESS_HOME so the disk-backed `SessionStore.load()` test never touches real
        // session state; the in-memory `SessionEditor` tests are unaffected by the override.
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-session-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A corrupt layout.json must be preserved as `.corrupt` for recovery (mirrors every other
    /// store) and `load()` must return a fresh empty snapshot rather than crashing or silently
    /// discarding the file (which the next save would overwrite).
    func testCorruptLayoutIsBackedUpAndLoadReturnsFreshSnapshot() throws {
        try HarnessPaths.ensureDirectories()
        let url = HarnessPaths.snapshotURL
        let backup = url.appendingPathExtension("corrupt")
        try Data("{ this is not valid json".utf8).write(to: url)

        let snapshot = SessionStore().load()

        // Fresh snapshot: a single default workspace, no carried-over corruption.
        let fresh = SessionSnapshot()
        XCTAssertEqual(snapshot.workspaces.count, fresh.workspaces.count,
                       "corrupt layout.json → a fresh default snapshot")
        // The bad file is moved aside, not left in place to be clobbered by the next save.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "corrupt layout.json must be preserved as .corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the unreadable layout.json must be moved aside")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ this is not valid json",
                       "the preserved backup must be byte-for-byte the original corrupt content")
    }

    func testNewSessionsDefaultUnpinned() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let id = try XCTUnwrap(editor.addSession(to: ws.id, name: "work"))
        let session = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == id })
        XCTAssertFalse(session.persistent, "new sessions start unpinned; pinning is explicit")
    }

    func testSetSessionPersistentTogglesAndReports() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let id = try XCTUnwrap(editor.addSession(to: ws.id, name: "work"))
        XCTAssertTrue(editor.setSessionPersistent(id, true))
        XCTAssertTrue(try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == id }).persistent)
        XCTAssertTrue(editor.setSessionPersistent(id, false))
        XCTAssertFalse(try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == id }).persistent)
        XCTAssertFalse(editor.setSessionPersistent(UUID(), true), "unknown session reports failure")
    }

    func testEphemeralWhenKeepOnQuitOn_isEmpty() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(true)
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        _ = editor.addSession(to: ws.id, name: "a")
        _ = editor.addSession(to: ws.id, name: "b")
        // keep-on-quit on (Persistent/Full/Agent, and every pre-modes install): nothing is
        // ephemeral, the per-session flag is moot.
        XCTAssertTrue(editor.ephemeralSessionIDs().isEmpty)
    }

    func testEphemeralWhenKeepOnQuitOff_excludesPinned() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(false)
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let pinned = try XCTUnwrap(editor.addSession(to: ws.id, name: "pinned"))
        let throwaway = try XCTUnwrap(editor.addSession(to: ws.id, name: "throwaway"))
        editor.setSessionPersistent(pinned, true)
        let ephemeral = editor.ephemeralSessionIDs()
        // Plain mode: only unpinned sessions are torn down on a clean quit.
        XCTAssertTrue(ephemeral.contains(throwaway))
        XCTAssertFalse(ephemeral.contains(pinned))
    }

    func testLegacySnapshotDecodesSessionsAsUnpinned() throws {
        // A SessionGroup written before `persistent` existed must decode to false, not fail.
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"old","tabs":[],"sortOrder":0}"#
        let group = try JSONDecoder().decode(SessionGroup.self, from: Data(legacy.utf8))
        XCTAssertFalse(group.persistent)
        XCTAssertEqual(group.tabs.count, 1, "empty tabs repairs to one tab")
    }

    func testPersistentSurvivesEncodeDecode() throws {
        var group = SessionGroup(name: "x")
        group.persistent = true
        let decoded = try JSONDecoder().decode(SessionGroup.self, from: JSONEncoder().encode(group))
        XCTAssertTrue(decoded.persistent)
    }

    // MARK: - Per-tab persistence (precedence: tab → session → global)

    func testSetTabPersistentTogglesAndReports() throws {
        var editor = SessionEditor()
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        let sessionID = try XCTUnwrap(editor.addSession(to: wsID, name: "s"))
        let tab1 = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == sessionID }).tabs[0].id
        XCTAssertTrue(editor.setTabPersistent(tab1, true))
        XCTAssertTrue(try tabPersistent(editor, tab1))
        XCTAssertTrue(editor.setTabPersistent(tab1, false))
        XCTAssertFalse(try tabPersistent(editor, tab1))
        XCTAssertFalse(editor.setTabPersistent(UUID(), true), "unknown tab reports failure")
    }

    func testPinnedTabKeepsSessionAndClosesUnpinnedSiblings() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(false)
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        let sessionID = try XCTUnwrap(editor.addSession(to: wsID, name: "s"))
        let tab1 = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == sessionID }).tabs[0].id
        let tab2 = try XCTUnwrap(editor.addTab(to: wsID))
        XCTAssertTrue(editor.setTabPersistent(tab1, true))
        // The session survives as a container for its pinned tab…
        XCTAssertFalse(editor.ephemeralSessionIDs().contains(sessionID))
        // …its unpinned sibling is torn down individually, the pinned one is not.
        XCTAssertTrue(editor.ephemeralTabIDs().contains(tab2))
        XCTAssertFalse(editor.ephemeralTabIDs().contains(tab1))
    }

    func testSessionPinKeepsAllTabs() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(false)
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        let sessionID = try XCTUnwrap(editor.addSession(to: wsID, name: "s"))
        _ = try XCTUnwrap(editor.addTab(to: wsID))
        editor.setSessionPersistent(sessionID, true)
        // A session pin keeps every tab — none are individually ephemeral.
        XCTAssertFalse(editor.ephemeralSessionIDs().contains(sessionID))
        let tabs = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == sessionID }).tabs
        for tab in tabs {
            XCTAssertFalse(editor.ephemeralTabIDs().contains(tab.id))
        }
    }

    func testUnpinnedSessionWithNoPinnedTabIsClosedWholesale() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(false)
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        let sessionID = try XCTUnwrap(editor.addSession(to: wsID, name: "s"))
        let tab2 = try XCTUnwrap(editor.addTab(to: wsID))
        // No pins anywhere: the whole session is ephemeral, with no per-tab teardown for it.
        XCTAssertTrue(editor.ephemeralSessionIDs().contains(sessionID))
        XCTAssertFalse(editor.ephemeralTabIDs().contains(tab2))
    }

    func testKeepOnQuitMakesEverythingSurviveRegardlessOfTabPin() throws {
        var editor = SessionEditor()
        editor.setKeepSessionsOnQuit(true)
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        _ = try XCTUnwrap(editor.addSession(to: wsID, name: "s"))
        let tab2 = try XCTUnwrap(editor.addTab(to: wsID))
        editor.setTabPersistent(tab2, true)
        XCTAssertTrue(editor.ephemeralSessionIDs().isEmpty)
        XCTAssertTrue(editor.ephemeralTabIDs().isEmpty)
    }

    func testLegacyTabDecodesAsUnpinned() throws {
        // A Tab written before `persistent` existed must decode to false, not fail. Strip the key
        // from an encoded Tab (rather than hand-writing a PaneNode tree) to simulate the old file.
        let tab = Tab(title: "t")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object.removeValue(forKey: "persistent")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        XCTAssertFalse(decoded.persistent)
    }

    private func tabPersistent(_ editor: SessionEditor, _ tabID: TabID) throws -> Bool {
        try XCTUnwrap(editor.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
            .first { $0.id == tabID }).persistent
    }

    // MARK: - layout.json write path (off the synchronous critical path)

    /// The compact (non-prettyPrinted) encode must still round-trip losslessly, and the on-disk
    /// file must be single-line so the format change is real (not just claimed in a comment).
    func testCompactEncodeRoundTrips() throws {
        var editor = SessionEditor()
        let wsID = try XCTUnwrap(editor.snapshot.activeWorkspace).id
        _ = editor.addSession(to: wsID, name: "work")
        let snapshot = editor.snapshot

        let store = SessionStore()
        try store.saveImmediately(snapshot)

        let onDisk = try String(contentsOf: HarnessPaths.snapshotURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("\n"), "layout.json is written compact, not prettyPrinted")

        let reloaded = store.load()
        // `savedAt` is stamped at write time, so compare the structural fields rather than `==`.
        XCTAssertEqual(reloaded.workspaces, snapshot.workspaces)
        XCTAssertEqual(reloaded.version, snapshot.version)
        XCTAssertEqual(reloaded.revision, snapshot.revision)
        XCTAssertEqual(reloaded.activeWorkspaceID, snapshot.activeWorkspaceID)
    }

    /// `save()` is debounced: it must NOT write synchronously (that's the whole point of moving the
    /// write off the caller's latency path), but the write must land shortly after.
    func testDebouncedSaveDefersTheWrite() {
        let store = SessionStore()
        let url = HarnessPaths.snapshotURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no layout.json before save")

        store.save(SessionSnapshot())
        // The debounce window is 0.5s, so the write cannot have happened in the time save() takes
        // to return — the file is still absent here.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "save() must not write synchronously")

        waitForFile(at: url, message: "the debounced write must land")
    }

    /// The destination is pinned at `save()` time. A `HARNESS_HOME` change before the debounced
    /// write fires must NOT redirect the write — a late write resolving the real home would pollute
    /// a user's live session state during a test run. Regression guard for that exact hazard.
    func testDebouncedSaveTargetsPinnedHomeNotChangedEnv() throws {
        let pinnedURL = HarnessPaths.snapshotURL
        let store = SessionStore()
        store.save(SessionSnapshot())

        // Repoint HARNESS_HOME immediately, exactly as a test tearDown would.
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-other-\(UUID().uuidString)", isDirectory: true)
        setenv("HARNESS_HOME", other.path, 1)
        defer {
            if let root { setenv("HARNESS_HOME", root.path, 1) } // restore for tearDown
            try? FileManager.default.removeItem(at: other)
        }

        waitForFile(at: pinnedURL, message: "the debounced write must land at the pinned URL")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: other.appendingPathComponent("sessions/layout.json").path),
            "a since-changed HARNESS_HOME must not capture the pinned write")
    }

    /// Spin until `url` exists (the debounced write lands asynchronously on the store's queue),
    /// failing on timeout. A plain poll keeps the helper free of `@Sendable` closure capture.
    private func waitForFile(at url: URL, message: String) {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), message)
    }
}
