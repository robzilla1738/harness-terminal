import XCTest
@testable import HarnessCore

final class SessionPersistenceTests: XCTestCase {
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
}
