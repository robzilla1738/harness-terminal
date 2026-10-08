import XCTest
@testable import HarnessTerminalEngine

/// A replacement emulator rebuilds history off to the side, silently, and then takes over from
/// the one a host drives: its callbacks and settings, and a report of the state it restored.
final class EmulatorReplacementTests: XCTestCase {
    private let pixel = "/wAA/w==" // a 1×1 RGBA pixel

    func testReplacementHasTheSettingsButStaysSilentUntilItTakesOver() {
        let live = TerminalEmulator(cols: 80, rows: 24)
        live.maxScrollbackLines = 123
        live.readsGraphicsFiles = false
        live.terminalName = "Probe"
        var responses: [String] = []
        live.onResponse = { responses.append(String(decoding: $0, as: UTF8.self)) }

        let replacement = live.makeReplacement(cols: 40, rows: 10)
        XCTAssertEqual(replacement.cols, 40)
        XCTAssertEqual(replacement.rows, 10)
        XCTAssertEqual(replacement.maxScrollbackLines, 123)
        XCTAssertFalse(replacement.readsGraphicsFiles)
        replacement.feed("\u{1b}[6n\u{1b}[>q")
        XCTAssertTrue(responses.isEmpty, "history parsed into the replacement answers nothing")

        replacement.takeOver(from: live)
        replacement.feed("\u{1b}[>q")
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses[0].contains("Probe"), "the identity came across")
    }

    func testTakingOverReportsTheRestoredState() {
        let live = TerminalEmulator(cols: 80, rows: 24)
        var titles: [String] = []
        var directories: [String] = []
        var hosts: [String?] = []
        var variables: [String: String] = [:]
        var pointers: [String?] = []
        live.onTitleChange = { titles.append($0) }
        live.onWorkingDirectoryChange = { directories.append($0) }
        live.onRemoteHostChange = { hosts.append($0) }
        live.onUserVariableChange = { variables[$0] = $1 }
        live.onPointerShapeChange = { pointers.append($0) }

        let replacement = live.makeReplacement(cols: 80, rows: 24)
        replacement.feed("\u{1b}]2;old\u{07}\u{1b}]2;build\u{07}")
        replacement.feed("\u{1b}]7;file://devbox/srv/app\u{07}")
        replacement.feed("\u{1b}]1337;SetUserVar=job=\(Data("deploy".utf8).base64EncodedString())\u{07}")
        replacement.feed("\u{1b}]22;text\u{07}")
        XCTAssertTrue(titles.isEmpty && directories.isEmpty, "nothing reaches the host before the swap")

        replacement.takeOver(from: live)
        XCTAssertEqual(titles, ["build"], "only the latest title, not the history of them")
        XCTAssertEqual(directories, ["/srv/app"])
        XCTAssertEqual(hosts, ["devbox"])
        XCTAssertEqual(variables, ["job": "deploy"])
        XCTAssertEqual(pointers, ["text"])
        XCTAssertEqual(replacement.workingDirectory, "/srv/app")
    }

    func testImageIDsNeverRepeatAcrossEmulators() throws {
        let first = TerminalEmulator(cols: 80, rows: 24)
        let second = first.makeReplacement(cols: 80, rows: 24)
        for term in [first, second] {
            term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\")
        }
        let firstID = try XCTUnwrap(first.readGrid().images.first?.id)
        let secondID = try XCTUnwrap(second.readGrid().images.first?.id)
        XCTAssertNotEqual(firstID, secondID, "the renderer caches textures by id")
        XCTAssertNil(first.image(for: secondID))
    }
}
