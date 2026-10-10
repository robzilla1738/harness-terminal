import XCTest
@testable import HarnessCore

final class HarnessAPITests: XCTestCase {
    func testAccessDenialPrecedesDaemonConnection() throws {
        let client = DaemonClient(endpoint: .unix(path: "/tmp/harness-no-service-\(UUID().uuidString)"))
        let localOnly = APIExecutor.call(method: "pane.theme", arguments: [:], client: client, exposure: .mobile)
        XCTAssertEqual(localOnly.exitCode, Int32(APIExit.badArguments.rawValue))
        XCTAssertTrue(localOnly.message?.contains("unavailable through mobile") == true)
        let write = APIExecutor.call(method: "pane.write", arguments: [:], client: client, exposure: .mcp, allowWrite: false)
        XCTAssertEqual(write.exitCode, Int32(APIExit.badArguments.rawValue))
        XCTAssertTrue(write.message?.contains("explicit write access") == true)
        XCTAssertEqual(HarnessAPI.method(named: "schedule.save")?.access.exposures, [.cli])
        XCTAssertEqual(HarnessAPI.method(named: "schedule.list")?.access.effect, .read)
        XCTAssertTrue(IPCRequest.activity(.schedules(requestID: UUID(), operation: .list(offset: 0, limit: 100))).requiresLocalOwner)
        XCTAssertTrue(IPCRequest.activity(.notifications(.status)).requiresLocalOwner)
        XCTAssertFalse(IPCRequest.activity(.list(hostID: nil, surfaceID: nil, activeOnly: false, offset: 0, limit: 100)).requiresLocalOwner)
        XCTAssertEqual(HarnessAPI.method(named: "worktree.inspect")?.access.effect, .write, "Inspection can reconcile durable partial-operation state")
        XCTAssertEqual(HarnessAPI.method(named: "worktree.compare")?.access.effect, .read)
        XCTAssertEqual(HarnessAPI.method(named: "worktree.create")?.access.exposures, [.cli])
        XCTAssertEqual(HarnessAPI.method(named: "pane.capture")?.access.effect, .read)
        XCTAssertEqual(HarnessAPI.method(named: "pane.write")?.access.effect, .write)
        XCTAssertTrue(try HarnessAPI.describeJSON(named: "pane.capture").contains("\"access\""))
    }
    func testDescribePaneCapturePrintsSchema() throws {
        let json = try HarnessAPI.describeJSON(named: "pane.capture")
        XCTAssertTrue(json.contains("\"$schema\""))
        XCTAssertTrue(json.contains("https://json-schema.org/draft/2020-12/schema"))
        XCTAssertTrue(json.contains("\"title\" : \"pane.capture\"") || json.contains("\"title\" : \"pane.capture\""))
        XCTAssertTrue(json.contains("pane.capture"))
        for token in ["text", "html", "vt", "pane", "format", "trim", "unwrap", "screen"] {
            XCTAssertTrue(json.contains(token), "schema missing \(token)")
        }
    }

    func testPaneCaptureTakesTheScreenOnlyFlag() {
        let catalog = APICatalog(panes: [
            APIPaneRecord(surfaceID: "surface-a", paneID: "pane-a", tabID: "tab", sessionID: "session", label: "shell"),
        ])
        let plan = { (arguments: [String: APIArgument]) in
            HarnessAPI.plan(method: "pane.capture", arguments: arguments, catalog: catalog, environment: APIEnvironment(environment: [:]))
        }
        guard case let .capture(_, _, _, _, screen) = plan(["pane": .string("shell"), "screen": .bool(true)]) else {
            return XCTFail("expected a capture")
        }
        XCTAssertTrue(screen)
        guard case let .capture(_, _, _, _, history) = plan(["pane": .string("shell")]) else { return XCTFail("expected a capture") }
        XCTAssertFalse(history, "history and screen unless asked")
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
        XCTAssertEqual(created?.type, "session.created")
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
    func testHexKeysSkipNonHexTokens() {
        XCTAssertEqual(HexKeys.bytes(["1b", "5b", "41"]), Data([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(HexKeys.bytes(["0x0d"]), Data([0x0d]))
        XCTAssertEqual(HexKeys.bytes(["zz", "41"]), Data([0x41]))
        XCTAssertEqual(HexKeys.bytes([]), Data())
    }

    func testPaneTargetsAcceptSurfaceIDsAndFallBackToTheActivePane() {
        let tab = UUID().uuidString, pane = UUID().uuidString, surface = UUID().uuidString
        let catalog = APICatalog(
            tabs: [APITabRecord(id: tab, sessionID: "session", label: "main")],
            panes: [APIPaneRecord(surfaceID: surface, paneID: pane, tabID: tab, sessionID: "session", label: "main")],
            activeTab: tab,
            activeSurface: surface
        )
        for arguments: [String: APIArgument] in [["pane": .string(surface)], ["pane": .string(pane)], [:]] {
            let plan = HarnessAPI.plan(method: "pane.zoom", arguments: arguments, catalog: catalog, environment: APIEnvironment(environment: [:]))
            guard case let .request(.zoomPane(target)) = plan else { return XCTFail("expected a zoom request, got \(plan)") }
            XCTAssertEqual(target.uuidString, pane)
        }
    }

    func testNewTabMethodsPlanTheirRequests() {
        let tab = UUID().uuidString
        let catalog = APICatalog(tabs: [APITabRecord(id: tab, sessionID: "session", label: "main")], activeTab: tab)
        let plan = HarnessAPI.plan(method: "tab.label", arguments: ["title": .string("logs")], catalog: catalog, environment: APIEnvironment(environment: [:]))
        guard case let .request(.renameTab(id, title)) = plan else { return XCTFail("expected a rename, got \(plan)") }
        XCTAssertEqual(id.uuidString, tab)
        XCTAssertEqual(title, "logs")
    }


    func testParserAliasesAreCallableMethodsWithArgs() {
        XCTAssertNotNil(HarnessAPI.method(named: "split-window"), "aliases resolve like listed verbs")
        XCTAssertNil(HarnessAPI.method(named: "not-a-command"))
        let planned = HarnessAPI.plan(method: "split-window", arguments: ["args": .string("-h")], catalog: APICatalog(), environment: APIEnvironment())
        guard case let .verb(source) = planned else { return XCTFail("expected a verb plan, got \(planned)") }
        XCTAssertEqual(source, "split-window -h")
    }
}
