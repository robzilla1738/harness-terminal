import XCTest
@testable import HarnessCore

final class LaunchAgentInstallerTests: XCTestCase {
    func testPlistContainsLabelDaemonPathAndLogPath() {
        let daemon = URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon")
        let home = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness")
        let log = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness/logs/daemon.log")

        let plist = LaunchAgentInstaller.plist(daemonPath: daemon, harnessHome: home, logPath: log)

        XCTAssertTrue(plist.contains("<string>\(HarnessPaths.launchAgentLabel)</string>"),
                      "label must appear so launchctl can address the service")
        XCTAssertTrue(plist.contains(daemon.path), "daemon path must be embedded")
        XCTAssertTrue(plist.contains(home.path), "HARNESS_HOME must be embedded")
        XCTAssertTrue(plist.contains(log.path), "log path must be embedded")
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"), "KeepAlive must be set so launchd respawns on crash")
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"), "RunAtLoad ensures the daemon starts on user login")
    }

    func testPlistPreservesPathsWithXMLCharacters() throws {
        let path = URL(fileURLWithPath: "/tmp/Harness & <tools>/daemon")
        let data = Data(LaunchAgentInstaller.plist(daemonPath: path, harnessHome: path, logPath: path).utf8)
        let values = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(values["ProgramArguments"] as? [String], [path.path])
        XCTAssertEqual((values["EnvironmentVariables"] as? [String: String])?["HARNESS_HOME"], path.path)
        XCTAssertEqual(values["StandardErrorPath"] as? String, path.path)
    }

    func testIsInstalledReflectsFilesystem() throws {
        // Don't touch the real LaunchAgents path; just confirm the API uses
        // FileManager.default which honors the URL we expose.
        let exists = FileManager.default.fileExists(atPath: HarnessPaths.launchAgentURL.path)
        XCTAssertEqual(LaunchAgentInstaller.isInstalled, exists)
    }
}
