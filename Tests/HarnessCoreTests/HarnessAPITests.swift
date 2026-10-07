import XCTest
@testable import HarnessCore

final class HarnessAPITests: XCTestCase {
    func testDescribePaneCapturePrintsSchema() throws {
        let json = try HarnessAPI.describeJSON(named: "pane.capture")
        XCTAssertTrue(json.contains("\"$schema\""))
        XCTAssertTrue(json.contains("https://json-schema.org/draft/2020-12/schema"))
        XCTAssertTrue(json.contains("\"title\" : \"pane.capture\"") || json.contains("\"title\" : \"pane.capture\""))
        XCTAssertTrue(json.contains("pane.capture"))
        for token in ["text", "html", "vt", "pane", "format", "trim", "unwrap"] {
            XCTAssertTrue(json.contains(token), "schema missing \(token)")
        }
    }

    func testIntegerArgumentsStayIntegers() {
        guard case let .success(parsed) = HarnessAPI.arguments(from: "{\"timeout\":1,\"trim\":true,\"ratio\":0.5}") else {
            return XCTFail("expected an object")
        }
        XCTAssertEqual(parsed["timeout"], .int(1))
        XCTAssertEqual(parsed["trim"], .bool(true))
        XCTAssertEqual(parsed["ratio"], .double(0.5))
    }

    func testAmbiguousLabelExitsThreeWithoutAMutation() {
        let catalog = APICatalog(panes: [
            APIPaneRecord(surfaceID: "surface-a", paneID: "pane-a", tabID: "tab", sessionID: "session", label: "shell"),
            APIPaneRecord(surfaceID: "surface-b", paneID: "pane-b", tabID: "tab", sessionID: "session", label: "shell"),
        ])
        let before = catalog
        let plan = HarnessAPI.plan(
            method: "pane.zoom",
            arguments: ["pane": .string("shell")],
            catalog: catalog,
            environment: APIEnvironment(environment: [:])
        )
        guard case let .failure(code, message) = plan else { return XCTFail("expected a failure, got \(plan)") }
        XCTAssertEqual(code, APIExit.ambiguous.rawValue)
        XCTAssertTrue(message.contains("surface-a"))
        XCTAssertTrue(message.contains("surface-b"))
        XCTAssertEqual(catalog, before)
        if case .zoom = plan { XCTFail("ambiguous plan must not zoom") }
    }

    func testUnknownMethodAndArgumentExitTwo() {
        let unknown = HarnessAPI.plan(method: "pane.nope", arguments: [:], catalog: APICatalog(), environment: APIEnvironment(environment: [:]))
        guard case let .failure(code, _) = unknown else { return XCTFail("expected failure") }
        XCTAssertEqual(code, APIExit.badArguments.rawValue)
        let extra = HarnessAPI.plan(
            method: "pane.zoom",
            arguments: ["pane": .string("shell"), "extra": .string("no")],
            catalog: APICatalog(),
            environment: APIEnvironment(environment: [:])
        )
        guard case let .failure(extraCode, _) = extra else { return XCTFail("expected failure") }
        XCTAssertEqual(extraCode, APIExit.badArguments.rawValue)
    }

    func testFalseCommandPlansAnExecutablePath() {
        let catalog = APICatalog(
            tabs: [APITabRecord(id: "tab", sessionID: "session", label: "main")],
            panes: [APIPaneRecord(surfaceID: "surface", paneID: "pane", tabID: "tab", sessionID: "session", label: "main")]
        )
        let plan = HarnessAPI.plan(
            method: "pane.split",
            arguments: ["command": .string("false")],
            catalog: catalog,
            environment: APIEnvironment(environment: ["HARNESS_TAB": "tab", "HARNESS_SURFACE": "surface"])
        )
        guard case let .split(_, _, direction, command, _, _) = plan else { return XCTFail("expected a split, got \(plan)") }
        XCTAssertEqual(direction, "vertical")
        XCTAssertEqual(command, "false")
    }

    func testFollowSessionFilterAndServerFlag() {
        let status = FollowEvent.programStatusChanged(pane: "pane", session: "session", state: "working", app: "demo", message: "build")
        XCTAssertTrue(FollowSubscription(sessionID: "session", includeServer: false).accepts(status))
        XCTAssertFalse(FollowSubscription(sessionID: "other", includeServer: false).accepts(status))
        let server = FollowEvent(type: "client.connected", payload: ["server": .bool(true)])
        XCTAssertFalse(FollowSubscription(sessionID: nil, includeServer: false).accepts(server))
        XCTAssertTrue(FollowSubscription(sessionID: "session", includeServer: true).accepts(server))
        let created = FollowHookBridge.event(hook: "session-created", context: FollowHookContext(sessionID: "session"))
        XCTAssertEqual(created?.type, "session_created")
        XCTAssertNil(FollowHookBridge.event(hook: "after-new-session", context: FollowHookContext()), "one event per session")
        XCTAssertNil(FollowHookBridge.event(hook: "alert-bell", context: FollowHookContext()), "bells come from the monitor")
        XCTAssertEqual(FollowHookBridge.event(hook: "tab-selected", context: FollowHookContext())?.type, "tab.activated")
        XCTAssertEqual(FollowHookBridge.event(hook: "window-pane-changed", context: FollowHookContext())?.type, "pane.focused")
        XCTAssertNil(FollowHookBridge.event(hook: "not-a-hook", context: FollowHookContext()))
    }

    func testUpsertPaneThemeReplacesTheSameSurface() {
        let first = HarnessAPI.upsertPaneTheme([], surfaceID: "Surface", theme: "One")
        let second = HarnessAPI.upsertPaneTheme(first, surfaceID: "surface", theme: "Two")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].theme, "Two")
        XCTAssertEqual(second[0].surface?.lowercased(), "surface")
    }
}

final class APIVerbTests: XCTestCase {
    func testParserAliasesAreCallableMethodsWithArgs() {
        XCTAssertNotNil(HarnessAPI.method(named: "split-window"), "aliases resolve like listed verbs")
        XCTAssertNil(HarnessAPI.method(named: "not-a-command"))
        let planned = HarnessAPI.plan(method: "split-window", arguments: ["args": .string("-h")], catalog: APICatalog(), environment: APIEnvironment())
        guard case let .verb(source) = planned else { return XCTFail("expected a verb plan, got \(planned)") }
        XCTAssertEqual(source, "split-window -h")
    }
}
