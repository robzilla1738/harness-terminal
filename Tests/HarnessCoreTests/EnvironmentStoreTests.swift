import XCTest
@testable import HarnessCore

final class EnvironmentStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString).json")
    }

    func testSessionOverridesGlobal() {
        let store = EnvironmentStore(url: tempURL())
        store.set("global", key: "EDITOR")
        store.set("session", key: "EDITOR", sessionID: "S1")
        store.set("only-global", key: "PAGER")

        let resolved = store.resolved(sessionID: "S1")
        XCTAssertEqual(resolved["EDITOR"], "session", "session value wins")
        XCTAssertEqual(resolved["PAGER"], "only-global", "global inherited where session has no override")

        let otherSession = store.resolved(sessionID: "S2")
        XCTAssertEqual(otherSession["EDITOR"], "global", "a different session sees only the global value")
    }

    func testUnsetAndClear() {
        let url = tempURL()
        let store = EnvironmentStore(url: url)
        store.set("x", key: "FOO", sessionID: "S1")
        store.set(nil, key: "FOO", sessionID: "S1")   // unset
        XCTAssertNil(store.resolved(sessionID: "S1")["FOO"])

        store.set("y", key: "BAR", sessionID: "S1")
        store.clearSession("S1")
        XCTAssertNil(store.resolved(sessionID: "S1")["BAR"])
    }

    func testPersistsAcrossInstances() {
        let url = tempURL()
        let first = EnvironmentStore(url: url)
        first.set("kept", key: "TOKEN")
        first.set("svalue", key: "S", sessionID: "abc")

        let reloaded = EnvironmentStore(url: url)
        XCTAssertEqual(reloaded.resolved(sessionID: "abc")["TOKEN"], "kept")
        XCTAssertEqual(reloaded.resolved(sessionID: "abc")["S"], "svalue")
    }
}
