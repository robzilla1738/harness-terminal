import Foundation
import XCTest
@testable import HarnessCore

final class LayoutImporterTests: XCTestCase {
    func testNestedStableLayoutsAndSettingsPreviewFailurePaths() throws {
        let body = "120x40,0,0{60x40,0,0,7,59x40,61,0[59x20,61,0,12,59x19,61,21,20]}"
        var checksum: UInt16 = 0
        for byte in body.utf8 { checksum = ((checksum >> 1) | ((checksum & 1) << 15)) &+ UInt16(byte) }
        let text = String(format: "%04x,", checksum) + body
        let directory = "/tmp/quotes'\\tabs\tand\nnewlines"
        let panes = ["%20", "%7", "%12"].map { TmuxPaneRecord(id: $0, directory: directory, startupSuggestion: "printf '%s' 'do not execute'\n") }
        var record = TmuxWindowRecord(sessionID: "$4", windowID: "@2", sessionName: "dev\tsession", windowName: "window\nname", layout: text, panes: panes)
        let v1 = try XCTUnwrap(TmuxLayoutImport.proposals(TmuxImportSnapshot(windows: [record])).first)
        XCTAssertEqual(v1.setup.tabs[0].layout.panes.map(\.directory), Array(repeating: directory, count: 3))
        XCTAssertTrue(v1.setup.tabs[0].layout.panes.allSatisfy { $0.startupCommand == nil && $0.shell == nil })
        XCTAssertEqual(v1.suggestions.count, 3)
        let json = #"{"V":2,"L":{"t":"h","w":120,"h":40,"x":0,"y":0,"c":[{"t":"p","w":60,"h":40,"x":0,"y":0,"I":"%7"},{"t":"v","w":59,"h":40,"x":61,"y":0,"c":[{"t":"p","w":59,"h":20,"x":61,"y":0,"I":"%12"},{"t":"p","w":59,"h":19,"x":61,"y":21,"I":"%20"}]}]}}"#
        record.layout = json
        let v2 = try XCTUnwrap(TmuxLayoutImport.proposals(TmuxImportSnapshot(windows: [record])).first)
        XCTAssertEqual(v2.setup.tabs[0].layout, v1.setup.tabs[0].layout)
        record.layout = "0000," + body; XCTAssertThrowsError(try TmuxLayoutImport.proposals(TmuxImportSnapshot(windows: [record])))
        record.layout = json.replacingOccurrences(of: "\"%20\"", with: "\"%12\""); XCTAssertThrowsError(try TmuxLayoutImport.proposals(TmuxImportSnapshot(windows: [record])))
        record.layout = json.replacingOccurrences(of: "\"x\":61", with: "\"x\":60"); XCTAssertThrowsError(try TmuxLayoutImport.proposals(TmuxImportSnapshot(windows: [record])))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("himport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json"), original = Data(##"{"customBackgroundHex":"#111111","unknown":{"keep":true},"power":{"preventOnAC":false}}"##.utf8)
        _ = try PrivateFile.replace(file, data: original, expected: nil)
        let current = try HarnessSettings.reload(data: original)
        let imported = TerminalConfigImporter.parse("background = #222222\nkeybind = super+t=new_tab\nkeybind = super+t=new_window\nkeybind = super+w=new_window\nkeybind = global:super+x=new_tab")
        XCTAssertEqual(imported.paletteShortcuts, ["action.newWindow": "Cmd-w"])
        XCTAssertTrue(imported.skippedKeys.contains { $0.contains("conflict") }); XCTAssertTrue(imported.skippedKeys.contains { $0.contains("global:") })
        let patch = try SettingsImport(current: current, imported: imported)
        XCTAssertEqual(try PrivateFile.read(file), original, "Preview must be read-only")
        let backup = try XCTUnwrap(patch.applyFile(at: file, expected: original, selected: ["customBackgroundHex"]))
        XCTAssertEqual(try PrivateFile.read(backup), original)
        let updated = try XCTUnwrap(PrivateFile.read(file)), values = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertEqual(values["customBackgroundHex"] as? String, "#222222"); XCTAssertNotNil(values["unknown"]); XCTAssertNotNil(values["power"])
        XCTAssertThrowsError(try patch.applyFile(at: file, expected: original, selected: ["customBackgroundHex"]))
        XCTAssertEqual(try PrivateFile.read(file), updated)
    }

    func testRealTmuxCaptureLeavesPanesAndEscapedFieldsUntouched() throws {
        guard let executable = try? TmuxSnapshotCapture.executable() else { throw XCTSkip("tmux unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("htm-" + UUID().uuidString.prefix(8))
        let directory = root.appendingPathComponent("space\ttab'line\nnext")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("server.sock").path
        defer { _ = try? ProcessCapture.run(executable, arguments: ["-S", socket, "kill-server"], timeout: 3); try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String]) throws -> String {
            let value = try ProcessCapture.run(executable, arguments: ["-f", "/dev/null", "-S", socket] + args, timeout: 3)
            guard value.status == 0 else { throw TmuxImportError.unavailable }; return String(decoding: value.stdout, as: UTF8.self)
        }
        _ = try run(["new-session", "-d", "-s", "fixture", "-x", "120", "-y", "40", "-c", directory.path, "/bin/sh"])
        _ = try run(["split-window", "-h", "-t", "$0", "-c", root.path, "/bin/sh"])
        _ = try run(["split-window", "-v", "-t", "$0", "-c", root.path, "/bin/sh"])
        let before = try run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let snapshot = try TmuxSnapshotCapture.capture(executable: executable, socketPath: socket)
        let proposal = try XCTUnwrap(TmuxLayoutImport.proposals(snapshot).first)
        XCTAssertEqual(proposal.setup.tabs[0].layout.panes.count, 3)
        XCTAssertTrue(snapshot.windows[0].panes.contains { URL(fileURLWithPath: $0.directory).standardizedFileURL == directory.standardizedFileURL.resolvingSymlinksInPath() })
        XCTAssertTrue(proposal.setup.tabs[0].layout.panes.allSatisfy { $0.startupCommand == nil })
        XCTAssertEqual(try run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), before)
    }
}
