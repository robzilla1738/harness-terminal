import XCTest
import Foundation
import HarnessMCP

final class MCPInstallerTests: XCTestCase {
    func testDryRunAndBackedUpFormatAwareEditsPreserveUnrelatedConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hmcp-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = "/fixture/Harness/harness-cli"
        let preview = try MCPInstaller.install(client: .codex, executable: executable, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path)); XCTAssertFalse(preview.changed)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = home.appendingPathComponent("config.toml")
        let original = "# User's retained comment\nmodel = 'fixture-model'\n[features]\nhooks = true\n[mcp_servers.other]\ncommand = 'other-program'\n"
        try Data(original.utf8).write(to: path)
        let install = try MCPInstaller.install(client: .codex, executable: executable, write: true, home: home, path: path)
        XCTAssertTrue(install.changed)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(install.backup), encoding: .utf8), original)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).hasPrefix(original))
        let repeatInstall = try MCPInstaller.install(client: .codex, executable: executable, write: true, home: home, path: path)
        XCTAssertFalse(repeatInstall.changed)
        let optedIn = try MCPInstaller.install(client: .codex, executable: executable, allowWrite: true, write: true, home: home, path: path)
        XCTAssertTrue(optedIn.changed)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).hasPrefix(original))
        let json = home.appendingPathComponent("mcp.json")
        try Data("{\"unrelated\":42,\"mcpServers\":{\"other\":{\"command\":\"other-program\"}}}".utf8).write(to: json)
        _ = try MCPInstaller.install(client: .cursor, executable: executable, write: true, home: home, path: json)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        XCTAssertEqual(parsed["unrelated"] as? Int, 42)
        XCTAssertEqual((parsed["mcpServers"] as? [String: [String: Any]])?["other"]?["command"] as? String, "other-program")
        try Data("invalid TOML = [".utf8).write(to: path)
        XCTAssertThrowsError(try MCPInstaller.install(client: .codex, executable: executable, write: true, home: home, path: path))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "invalid TOML = [")
    }
}
