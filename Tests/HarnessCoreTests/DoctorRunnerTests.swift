import XCTest
@testable import HarnessCore

final class DoctorRunnerTests: XCTestCase {
    /// A fresh owner-only (0o700) temp home, auto-cleaned. Rooted under `/tmp` (not the long
    /// `/var/folders/...` temp dir) so the `home/harness.sock` path stays under the 104-byte
    /// `sun_path` limit — otherwise doctor's (correct) socket-path-too-long check would fire.
    private func makeHome(mode: Int = 0o700) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hcd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: mode])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func check(_ report: DoctorReport, _ name: String) -> DiagnosticCheck? {
        report.checks.first { $0.name == name }
    }

    func testDaemonAbsentIsWarnNotFailAndExitsZero() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: false,
                                      cliPath: "/usr/local/bin/harness-cli", installedAgentHooks: [])
        XCTAssertEqual(report.exitCode, 0, "a missing daemon is a warning, not a failure")
        XCTAssertEqual(check(report, "Daemon")?.status, .warn)
        XCTAssertFalse(report.checks.contains { $0.status == .fail },
                       "a clean-but-idle setup must produce no failures")
        // Sanity: it still reports the CLI path and the optional integrations as warnings.
        XCTAssertEqual(check(report, "CLI executable")?.detail, "/usr/local/bin/harness-cli")
        XCTAssertEqual(check(report, "Shell integration")?.status, .warn)
    }

    func testWorldReadableHomeFailsWithNonzeroExit() throws {
        let home = try makeHome(mode: 0o755)
        let report = DoctorRunner.run(home: home, daemonReachable: false, cliPath: "x",
                                      installedAgentHooks: [])
        XCTAssertEqual(check(report, "Home directory")?.status, .fail)
        XCTAssertEqual(report.exitCode, 1, "an insecure home is a clear failure")
    }

    func testOwnerOnlySocketPasses() throws {
        let home = try makeHome()
        let sock = home.appendingPathComponent("harness.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: sock.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sock.path)
        let report = DoctorRunner.run(home: home, daemonReachable: true, cliPath: "x",
                                      installedAgentHooks: [])
        XCTAssertEqual(check(report, "Control socket")?.status, .pass)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testWorldAccessibleSocketFails() throws {
        let home = try makeHome()
        let sock = home.appendingPathComponent("harness.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: sock.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: sock.path)
        let report = DoctorRunner.run(home: home, daemonReachable: true, cliPath: "x",
                                      installedAgentHooks: [])
        XCTAssertEqual(check(report, "Control socket")?.status, .fail)
        XCTAssertEqual(report.exitCode, 1)
    }

    private func stats(version: String?, build: Int?) -> DaemonStats {
        DaemonStats(pid: 1, uptimeSeconds: 0, surfaceCount: 0, totalScrollbackBytes: 0,
                    clientCount: 0, subscriberCount: 0, snapshotRevision: 0,
                    version: version, build: build)
    }

    func testMatchingDaemonBuildPasses() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: true, cliPath: "x",
                                      daemonStats: stats(version: HarnessVersion.short,
                                                         build: HarnessVersion.build),
                                      installedAgentHooks: [])
        XCTAssertEqual(check(report, "Daemon version")?.status, .pass)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testMismatchedDaemonBuildWarnsButExitsZero() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: true, cliPath: "x",
                                      daemonStats: stats(version: "0.0.1",
                                                         build: HarnessVersion.build + 1),
                                      installedAgentHooks: [])
        let row = check(report, "Daemon version")
        XCTAssertEqual(row?.status, .warn, "a stale daemon is recoverable — warn, don't fail")
        XCTAssertTrue(row?.detail.contains("harness-cli install") == true,
                      "the warning should tell the user how to heal")
        XCTAssertEqual(report.exitCode, 0)
    }

    func testPreHandshakeDaemonWarns() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: true, cliPath: "x",
                                      daemonStats: stats(version: nil, build: nil),
                                      installedAgentHooks: [])
        XCTAssertEqual(check(report, "Daemon version")?.status, .warn,
                       "a daemon too old to report a build is stale by definition")
    }

    func testNoVersionRowWhenDaemonUnreachable() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: false, cliPath: "x",
                                      installedAgentHooks: [])
        XCTAssertNil(check(report, "Daemon version"),
                     "no daemon to compare against — don't assert a version verdict")
    }

    func testInstalledAgentHooksAreReported() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: false, cliPath: "x",
                                      installedAgentHooks: [.claudeCode])
        let hooks = check(report, "Agent hooks")
        XCTAssertEqual(hooks?.status, .pass)
        XCTAssertTrue(hooks?.detail.contains("Claude Code") == true)
    }

    func testReportEncodesToValidJSON() throws {
        let home = try makeHome()
        let report = DoctorRunner.run(home: home, daemonReachable: false, cliPath: "x",
                                      installedAgentHooks: [])
        let json = try JSONOutputFormatter.encode(report)
        XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(json.utf8)) is [String: Any])
    }
}
