import XCTest
import HarnessCore
@testable import HarnessScript

final class ScriptEngineTests: XCTestCase {
    func testModeTableEntersAndAnActionBindStillLoads() throws {
        let engine = try ScriptEngine()
        let loaded = engine.load("""
        harness.mode("resize", { exclusive = true })
        harness.bind("ctrl+r", { mode = "resize" })
        harness.bind("not a key", { mode = "resize" })
        harness.bind("resize/left", "nudge")
        """, from: "/cfg/init.lua", replacingFileLayer: false)
        guard case .loaded = loaded else { return XCTFail("\(loaded)") }
        XCTAssertEqual(engine.press(ScriptKey.parse("ctrl+r")!.sequence[0]), .consumed(.enter("resize")))
        XCTAssertEqual(engine.keymap.stack, ["resize"])
        XCTAssertEqual(engine.press(ScriptKey.parse("left")!.sequence[0]), .consumed(.action("nudge")))
        XCTAssertEqual(engine.keymap.exportedModes().first?.exclusive, true)
        XCTAssertTrue(engine.warnings.contains { $0.contains("bad bind") })
        XCTAssertFalse(engine.keymap.exportedBindings().contains { $0.spec == "not a key" })
    }

    func testLuaOpensTheStandardLibraryAndSkipsABadBind() throws {
        let engine = try ScriptEngine()
        let loaded = engine.load("""
        assert(type(io.open) == "function")
        assert(type(os.time) == "function")
        assert(type(require) == "function")
        assert(type(string.byte) == "function")
        assert(math.floor(1.2) == 1)
        harness.bind("not a key", "nope")
        harness.bind("ctrl+k", "build")
        """, from: "/cfg/init.lua", replacingFileLayer: false)
        guard case .loaded = loaded else { return XCTFail("\(loaded)") }
        XCTAssertEqual(engine.bindCount, 1)
        XCTAssertTrue(engine.warnings.contains { $0.contains("bad bind") })
        XCTAssertEqual(engine.press(ScriptKey.parse("ctrl+k")!.sequence[0]), .consumed(.action("build")))
    }

    func testSyntaxErrorRestoresTheRecorderBinding() throws {
        let engine = try ScriptEngine()
        XCTAssertNil(engine.bind("ctrl+a", target: .action("scratch"), layer: .recorder, source: "recorder"))
        guard case .loaded = engine.load("harness.bind('ctrl+b', 'keep')", from: "/cfg/init.lua", replacingFileLayer: true) else {
            return XCTFail("load")
        }
        let broken = engine.load("this is not lua {{", from: "/cfg/init.lua", replacingFileLayer: true)
        guard case .syntax = broken else { return XCTFail("expected syntax") }
        XCTAssertEqual(engine.press(ScriptKey.parse("ctrl+a")!.sequence[0]), .consumed(.action("scratch")))
        XCTAssertEqual(engine.press(ScriptKey.parse("ctrl+b")!.sequence[0]), .consumed(.action("keep")))
    }

    func testRemoteReloadDoesNotReadTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("init-\(UUID().uuidString).lua")
        try "harness.bind('ctrl+k', 'build')\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        let engine = try ScriptEngine()
        XCTAssertEqual(engine.reload(file: url, remote: true), .refused)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(engine.bindCount, 0)
    }

    func testMisspelledArgumentDoesNotRun() throws {
        let engine = try ScriptEngine()
        guard case .loaded = engine.load("""
        ran = 0
        harness.action({ name = "build", title = "Build", args = { name = "string" }, run = function() ran = 1 end })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        let outcome = engine.invoke(name: "build", arguments: ["typo": "x"], origin: .cli)
        XCTAssertFalse(outcome.ran)
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(engine.numberGlobal("ran") ?? -1, 0, accuracy: 0.001)
    }

    func testInvokeNestsAtMostSixteenTimes() throws {
        let engine = try ScriptEngine()
        guard case .loaded = engine.load("""
        n = 0
        function run()
          n = n + 1
          if n < 20 then harness.invoke("go", {}) end
        end
        harness.action({ name = "go", title = "Go", run = run })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        let outcome = engine.invoke(name: "go", arguments: [:], origin: .script)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(engine.numberGlobal("n") ?? -1, 16, accuracy: 0.001)
    }

    func testFailedRunDropsQueuedGUIActions() throws {
        let engine = try ScriptEngine()
        guard case .loaded = engine.load("""
        harness.action({ name = "bad", title = "Bad", run = function()
          harness.queue("draw")
          error("nope")
        end })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        let outcome = engine.invoke(name: "bad", arguments: [:], origin: .script)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.queued.isEmpty)
    }

    func testTunnelCannotDriveGUIUntilRemoteControlIsOn() throws {
        let engine = try ScriptEngine()
        engine.tunnel = true
        guard case .loaded = engine.load("""
        harness.action({ name = "draw", title = "Draw", gui = true, run = function() end })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        XCTAssertEqual(engine.invoke(name: "draw", arguments: [:], origin: .api).exitCode, 1)
        engine.remoteControlEnabled = true
        XCTAssertEqual(engine.invoke(name: "draw", arguments: [:], origin: .api).exitCode, 0)
    }

    func testWaitReturnsTheChildExitAndATimeout() throws {
        let engine = try ScriptEngine()
        engine.poll = { FollowEvent(type: "terminal.child_exited", payload: ["exit": .int(4)]) }
        guard case .loaded = engine.load("""
        code = harness.wait("terminal.child_exited", { timeout = 2 })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        XCTAssertEqual(engine.numberGlobal("code") ?? -1, 4, accuracy: 0.001)

        let timing = try ScriptEngine()
        timing.poll = { nil }
        let started = Date()
        guard case .loaded = timing.load("""
        value, err = harness.wait("terminal.child_exited", { timeout = 1 })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("timeout load") }
        XCTAssertNil(timing.numberGlobal("value"))
        XCTAssertEqual(timing.stringGlobal("err"), "timeout")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }

    func testHostUpsertWritesTheInjectedStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try ScriptEngine(hosts: RemoteHostStore(fileURL: url))
        var noted = false
        engine.onHostsChanged = { noted = true }
        guard case .loaded = engine.load("""
        harness.host({ name = "box", ssh = "me@box", socket = "/var/harness.sock" })
        """, from: "/cfg/init.lua", replacingFileLayer: false) else { return XCTFail("load") }
        XCTAssertTrue(noted)
        XCTAssertEqual(engine.hosts.load().map(\.sshTarget), ["me@box"])
    }
}
