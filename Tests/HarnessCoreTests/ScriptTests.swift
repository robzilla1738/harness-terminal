import XCTest
@testable import HarnessCore

final class ScriptKeymapTests: XCTestCase {
    private func chord(_ spec: String) -> ScriptChord {
        let parsed = ScriptKey.parse(spec)
        XCTAssertNotNil(parsed, spec)
        return parsed!.sequence[0]
    }

    func testPlusGrammarKeepsTheUnshiftedKeyAndThePlusSign() {
        let plus = ScriptKey.parse("cmd+shift+=")
        XCTAssertEqual(plus?.sequence.first?.key, "=")
        XCTAssertEqual(plus?.sequence.first?.modifiers, [.command, .shift])
        XCTAssertEqual(ScriptKey.parse("cmd++")?.sequence.first?.key, "+")
        XCTAssertEqual(ScriptKey.parse("ctrl+[KeyA]")?.sequence.first?.key, "KeyA")
        XCTAssertEqual(ScriptKey.parse("ctrl+[KeyA]")?.sequence.first?.physical, true)
        XCTAssertEqual(ScriptKey.parse("meta+k")?.sequence.first?.modifiers, [.command])
        XCTAssertEqual(ScriptKey.parse("ctrl+a>ctrl+b")?.sequence.map(\.key), ["a", "b"])
    }

    func testAPrefixIsNotAlsoImmediateAndEscapeCancelsIt() {
        var map = ScriptKeymap()
        XCTAssertNil(map.bind(spec: "ctrl+a", target: .action("one"), layer: .configFile, source: "file"))
        XCTAssertNil(map.bind(spec: "ctrl+a>ctrl+b", target: .action("two"), layer: .configFile, source: "file"))
        XCTAssertEqual(map.role(of: chord("ctrl+a")), .prefix)
        XCTAssertEqual(map.press(chord("ctrl+a"), functionReturns: { _ in false }), .partial)
        XCTAssertEqual(map.press(chord("escape"), functionReturns: { _ in false }), .cancelled)
        XCTAssertEqual(map.pending.count, 0)
    }

    func testNewerBindingWinsAndNamesBothSources() {
        var map = ScriptKeymap()
        XCTAssertNil(map.bind(spec: "ctrl+k", target: .action("old"), layer: .clientDefault, source: "defaults"))
        XCTAssertNil(map.bind(spec: "ctrl+k", target: .action("new"), layer: .configFile, source: "init.lua"))
        let row = map.listing().first { $0.spec == "ctrl+k" }
        XCTAssertEqual(row?.winner, "new")
        XCTAssertEqual(row?.source, "init.lua")
        XCTAssertEqual(row?.also, ["defaults"])
        XCTAssertTrue(map.warnings.contains { $0.contains("init.lua") && $0.contains("defaults") })
    }

    func testUnbindingAPrefixLeavesTheLongerSequence() {
        var map = ScriptKeymap()
        XCTAssertNil(map.bind(spec: "ctrl+a", target: .action("one"), layer: .configFile, source: "file"))
        XCTAssertNil(map.bind(spec: "ctrl+a>ctrl+b", target: .action("two"), layer: .configFile, source: "file"))
        XCTAssertNil(map.unbind(spec: "ctrl+a", layer: .configFile))
        XCTAssertEqual(map.press(chord("ctrl+a"), functionReturns: { _ in false }), .partial)
        XCTAssertEqual(map.press(chord("ctrl+b"), functionReturns: { _ in false }), .consumed(.action("two")))
    }

    func testModesStackEscapeLeavesAndOncePops() {
        var map = ScriptKeymap()
        XCTAssertNil(map.defineMode(name: "resize", exclusive: true, once: true))
        XCTAssertNotNil(map.defineMode(name: "bad", exclusive: false, once: false, unknownOption: "sticky"))
        XCTAssertNil(map.modes["bad"])
        XCTAssertNil(map.bind(spec: "resize/left", target: .action("nudge"), layer: .configFile, source: "file"))
        XCTAssertTrue(map.enter("resize"))
        XCTAssertEqual(map.press(chord("x"), functionReturns: { _ in false }), .consumed(.blocked))
        XCTAssertTrue(map.stack.isEmpty, "once leaves after the swallowed key")
        XCTAssertTrue(map.enter("resize"))
        XCTAssertEqual(map.press(chord("escape"), functionReturns: { _ in false }), .leftMode)
        XCTAssertNil(map.bind(spec: "resize/escape", target: .action("stay"), layer: .configFile, source: "file"))
        XCTAssertTrue(map.enter("resize"))
        XCTAssertEqual(map.press(chord("escape"), functionReturns: { _ in false }), .consumed(.action("stay")))
    }

    func testModeUnbindBlocksTheKeyInsideTheMode() {
        var map = ScriptKeymap()
        XCTAssertNil(map.defineMode(name: "resize", exclusive: false, once: false))
        XCTAssertNil(map.bind(spec: "resize/left", target: .action("nudge"), layer: .configFile, source: "file"))
        XCTAssertNil(map.unbind(spec: "resize/left", layer: .configFile))
        XCTAssertTrue(map.enter("resize"))
        XCTAssertEqual(map.press(chord("left"), functionReturns: { _ in false }), .consumed(.blocked))
    }

    func testFalseOnASequenceForwardsOnlyTheLastChord() {
        var map = ScriptKeymap()
        XCTAssertNil(map.bind(spec: "ctrl+a>ctrl+b", target: .function(7), layer: .configFile, source: "file"))
        let delivery = map.press(chord("ctrl+a"), functionReturns: { _ in false })
        XCTAssertEqual(delivery, .partial)
        let forwarded = map.press(chord("ctrl+b"), functionReturns: { _ in false })
        XCTAssertEqual(forwarded, .forward([chord("ctrl+b")]))
    }

    func testReplayKeepsExclusiveModesAndDropsFunctions() {
        var map = ScriptKeymap()
        XCTAssertNil(map.defineMode(name: "resize", exclusive: true, once: false))
        XCTAssertNil(map.bind(spec: "ctrl+r", target: .enter("resize"), layer: .configFile, source: "init.lua"))
        XCTAssertNil(map.bind(spec: "resize/left", target: .action("nudge"), layer: .configFile, source: "init.lua"))
        XCTAssertNil(map.bind(spec: "ctrl+a", target: .function(4), layer: .configFile, source: "init.lua"))
        XCTAssertNotNil(map.bind(spec: "resize/left", target: .enter("other"), layer: .configFile, source: "init.lua"))
        let data = try? JSONEncoder().encode(ScriptManifest(
            generation: 2,
            hash: "ab",
            actions: [],
            bindingCount: 3,
            bindings: map.exportedBindings(),
            modes: map.exportedModes()
        ))
        let decoded = try? JSONDecoder().decode(ScriptManifest.self, from: data ?? Data())
        var replayed = ScriptKeymap.replay(bindings: decoded?.bindings ?? [], modes: decoded?.modes ?? [])
        XCTAssertEqual(replayed.modes["resize"]?.exclusive, true)
        XCTAssertFalse(replayed.exportedBindings().contains { $0.spec == "ctrl+a" })
        XCTAssertEqual(replayed.press(chord("ctrl+r"), functionReturns: { _ in false }), .consumed(.enter("resize")))
        XCTAssertEqual(replayed.stack, ["resize"])
        XCTAssertEqual(replayed.press(chord("x"), functionReturns: { _ in false }), .consumed(.blocked))
        XCTAssertEqual(replayed.press(chord("left"), functionReturns: { _ in false }), .consumed(.action("nudge")))
        XCTAssertEqual(replayed.press(chord("escape"), functionReturns: { _ in false }), .leftMode)
        let old = """
        {"actions":[],"bindingCount":1,"generation":1,"hash":"ab"}
        """.data(using: .utf8)!
        let legacy = try? JSONDecoder().decode(ScriptManifest.self, from: old)
        XCTAssertEqual(legacy?.bindings, [])
        XCTAssertEqual(legacy?.modes, [])
        XCTAssertEqual(
            ScriptActionRunner.actionArguments(name: "build", origin: .key),
            ["do", "--action", "build", "--origin", "key"]
        )
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/harness-cli")
        let found = HarnessCLILocator.url(
            bundleExecutable: URL(fileURLWithPath: "/Apps/Harness"),
            isExecutable: { $0 == homebrew.path }
        )
        XCTAssertEqual(found, homebrew)
    }

    func testPhysicalChordWinsWhenThatBindingExists() {
        var map = ScriptKeymap()
        XCTAssertNil(map.bind(spec: "ctrl+[KeyA]", target: .action("physical"), layer: .configFile, source: "file"))
        let named = chord("ctrl+a")
        let physical = ScriptKey.parse("ctrl+[KeyA]")!.sequence[0]
        XCTAssertEqual(map.chordToPress(named: named, physical: physical), physical)
        XCTAssertEqual(map.press(physical, functionReturns: { _ in false }), .consumed(.action("physical")))
    }
}

final class LayoutAndAPITests: XCTestCase {
    func testLayoutRatioOutsideZeroToOneIsRejected() {
        let bad = LayoutTree.parse(.object(["ratio": .double(1.5), "children": .array([])]))
        guard case let .failure(error) = bad else { return XCTFail("expected failure") }
        XCTAssertTrue(error.message.contains("ratio"))
        let tree = LayoutTree.parse(.object([
            "direction": .string("horizontal"),
            "ratio": .double(0.25),
            "children": .array([
                .object(["command": .string("false")]),
                .object(["cwd": .string("/var/build"), "input": .string("pwd\n"), "keep-open": .bool(true)]),
            ]),
        ]))
        guard case let .success(node) = tree else { return XCTFail("parse") }
        let leaves = LayoutTree.leaves(node)
        XCTAssertEqual(leaves.count, 2)
        XCTAssertEqual(leaves[0].splits.count, 0)
        XCTAssertEqual(leaves[1].splits.first?.ratio, 0.25)
        XCTAssertEqual(leaves[1].keepOpen, true)
    }

    func testArgumentsAcceptALayoutObject() {
        let parsed = HarnessAPI.arguments(from: #"{"layout":{"ratio":0.5,"children":[{"command":"false"}]}}"#)
        guard case let .success(arguments) = parsed else { return XCTFail("parse") }
        XCTAssertNotNil(arguments["layout"]?.object)
        XCTAssertEqual(arguments["layout"]?.object?["children"]?.array?.count, 1)
    }

    func testApiListCoversBindableVerbsAndSessionCreate() throws {
        let list = try HarnessAPI.listJSON()
        XCTAssertTrue(list.contains("\"kill-pane\""))
        XCTAssertTrue(list.contains("\"session.create\""))
        XCTAssertTrue(list.contains("\"client.list\""))
        XCTAssertFalse(list.contains("floating"))
        let plan = HarnessAPI.plan(method: "kill-pane", arguments: [:], catalog: APICatalog(), environment: APIEnvironment(environment: [:]))
        guard case .verb("kill-pane") = plan else { return XCTFail("\(plan)") }
    }

    func testSessionCreateLayoutBecomesSessionAndSplitRequests() throws {
        let parsed = LayoutTree.parse(.object([
            "direction": .string("vertical"),
            "ratio": .double(0.4),
            "children": .array([
                .object(["shell": .string("false")]),
                .object(["command": .string("/bin/echo"), "cwd": .string("/var"), "input": .string("hi")]),
            ]),
        ]))
        guard case let .success(layout) = parsed else { return XCTFail("layout") }
        let workspace = UUID()
        let session = UUID()
        let tab = UUID()
        let rootPane = UUID()
        let rootSurface = UUID()
        let splitPane = UUID()
        let splitSurface = UUID()
        var requests: [IPCRequest] = []
        let created = try APILayoutApply.createSession(name: "build", layout: layout, workspaceID: workspace) { request in
            requests.append(request)
            switch request {
            case .newSession:
                return .sessionID(session)
            case .getSnapshot where requests.contains(where: { if case .newSplit = $0 { return true } else { return false } }):
                let root = PaneLeaf(id: rootPane, surfaceID: rootSurface)
                let child = PaneLeaf(id: splitPane, surfaceID: splitSurface)
                let node = PaneNode.branch(direction: .vertical, ratio: 0.4, first: .leaf(root), second: .leaf(child))
                let snapTab = Tab(id: tab, cwd: "/", rootPane: node)
                return .snapshot(SessionSnapshot(workspaces: [Workspace(id: workspace, sessions: [SessionGroup(id: session, tabs: [snapTab])])]))
            case .getSnapshot:
                let snapTab = Tab(id: tab, cwd: "/", rootPane: .leaf(PaneLeaf(id: rootPane, surfaceID: rootSurface)))
                return .snapshot(SessionSnapshot(workspaces: [Workspace(id: workspace, sessions: [SessionGroup(id: session, tabs: [snapTab])])]))
            case .newSplit:
                return .paneID(splitPane)
            default:
                return .ok
            }
        }
        XCTAssertEqual(created, session.uuidString)
        guard case let .newSession(_, cwd, name, shell) = requests[0] else { return XCTFail("session") }
        XCTAssertEqual(name, "build")
        XCTAssertNil(cwd)
        XCTAssertEqual(shell, "/usr/bin/false")
        XCTAssertTrue(requests.contains { if case .newSplit = $0 { return true } else { return false } })
        XCTAssertTrue(requests.contains { if case .resizePaneRatio = $0 { return true } else { return false } })
        XCTAssertTrue(requests.contains { if case let .send(_, text) = $0 { return text == "hi" } else { return false } })
    }

    func testOneSecondWaitTimesOutWithTheRealSleeper() {
        let started = Date()
        let result = ScriptWait.next(timeout: 1, poll: { nil }, accept: { _ in true })
        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }

    func testChildExitWaitReturnsTheExitCode() {
        let event = FollowEvent(type: "terminal.child_exited", payload: ["exit": .int(3)])
        let result = ScriptWait.next(timeout: 1, poll: { event }, accept: { $0.type == "terminal.child_exited" })
        guard case let .success(found) = result else { return XCTFail("wait") }
        XCTAssertEqual(ScriptWait.childExit(found), 3)
    }

    func testRemoteControlRefusesATunnelUntilTheSwitchIsOn() {
        XCTAssertTrue(RemoteControlPolicy.allowsGUI(tunnel: false, enabled: false))
        XCTAssertFalse(RemoteControlPolicy.allowsGUI(tunnel: true, enabled: false))
        XCTAssertTrue(RemoteControlPolicy.allowsGUI(tunnel: true, enabled: true))
        XCTAssertFalse(HarnessSettings().remoteControl)
    }

    func testConfigPathHonorsHarnessConfigOverXDG() {
        let path = ScriptConfigPath.resolve(environment: [
            "HARNESS_CONFIG": "/opt/init.lua",
            "XDG_CONFIG_HOME": "/xdg",
        ], home: "/Users/someone")
        XCTAssertEqual(path, "/opt/init.lua")
        let xdg = ScriptConfigPath.resolve(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/someone")
        XCTAssertEqual(xdg, "/xdg/harness/init.lua")
    }

    func testHostStoreUsesTheInjectedFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RemoteHostStore(fileURL: url)
        let saved = store.upsert(RemoteHost(name: "box", sshTarget: "me@box", remoteSocketPath: "/var/harness.sock"))
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(store.load().map(\.name), ["box"])
        XCTAssertFalse(HarnessPaths.remoteHostsURL.path == url.path)
    }

    func testPaletteRowsAndFingerprint() {
        let action = ScriptAction(name: "build", title: "Build", source: "init.lua")
        XCTAssertEqual(ScriptPalette.rows(actions: [action]).map(\.id), ["script.build"])
        let hash = ScriptFingerprint.hash(bindings: ["ctrl+k"], actions: ["build"])
        XCTAssertEqual(hash, ScriptFingerprint.hash(bindings: ["ctrl+k"], actions: ["build"]))
        XCTAssertNotEqual(hash, ScriptFingerprint.hash(bindings: ["ctrl+j"], actions: ["build"]))
    }
}
