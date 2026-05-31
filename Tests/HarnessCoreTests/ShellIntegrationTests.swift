import XCTest
@testable import HarnessCore

final class ShellIntegrationTests: XCTestCase {
    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-shellint-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    func testDetectFromShellPath() {
        XCTAssertEqual(ShellIntegration.Shell.detect(from: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellIntegration.Shell.detect(from: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(ShellIntegration.Shell.detect(from: "-bash"), .bash)   // login-shell dash prefix
        XCTAssertNil(ShellIntegration.Shell.detect(from: "/usr/bin/tcsh"))
    }

    func testScriptsGateOnHarnessEnv() {
        // Every script must only run inside a Harness pane (the $HARNESS presence flag) and emit
        // the OSC 133 prompt + exit-status sequences.
        for shell in ShellIntegration.Shell.allCases {
            let s = ShellIntegration.script(for: shell)
            XCTAssertTrue(s.contains("HARNESS"), "\(shell) script must gate on $HARNESS")
            XCTAssertTrue(s.contains("133;A"), "\(shell) script must emit the prompt mark")
            XCTAssertTrue(s.contains("133;D"), "\(shell) script must emit the exit status")
        }
    }

    func testInstallWritesScriptAndWiresRCIdempotently() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let r1 = try ShellIntegration.install(.zsh, homeOverride: home)
        XCTAssertFalse(r1.alreadyWired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r1.scriptPath.path), "script written")
        let rc1 = try String(contentsOf: r1.rcPath, encoding: .utf8)
        XCTAssertTrue(rc1.contains("Harness shell integration"), "rc has the marker block")
        XCTAssertTrue(rc1.contains(r1.scriptPath.path), "rc sources the script")

        // Second install is idempotent: no duplicate block, reports alreadyWired.
        let r2 = try ShellIntegration.install(.zsh, homeOverride: home)
        XCTAssertTrue(r2.alreadyWired)
        let rc2 = try String(contentsOf: r2.rcPath, encoding: .utf8)
        XCTAssertEqual(rc2.components(separatedBy: "# >>> Harness shell integration >>>").count - 1, 1,
                       "marker block appears exactly once after two installs")
    }

    func testInstallPreservesExistingRCContent() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".bashrc")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "export FOO=bar\nalias ll='ls -la'\n".write(to: rc, atomically: true, encoding: .utf8)

        let r = try ShellIntegration.install(.bash, homeOverride: home)
        XCTAssertNotNil(r.rcBackedUp, "pre-existing rc backed up")
        let updated = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(updated.contains("export FOO=bar"), "original rc content preserved")
        XCTAssertTrue(updated.contains("alias ll='ls -la'"))
        XCTAssertTrue(updated.contains("Harness shell integration"))
    }
}
