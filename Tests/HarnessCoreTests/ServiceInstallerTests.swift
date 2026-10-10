import XCTest
@testable import HarnessCore

final class ServiceInstallerTests: XCTestCase {
    func testSystemdUnitContents() throws {
        let unit = try SystemdUserInstaller.unitContents(
            daemonPath: URL(fileURLWithPath: "/opt/harness/HarnessDaemon"),
            harnessHome: URL(fileURLWithPath: "/home/u/.local/share/harness"),
            logPath: URL(fileURLWithPath: "/home/u/.local/share/harness/logs/daemon.log")
        )
        XCTAssertTrue(unit.contains("ExecStart=:\"/opt/harness/HarnessDaemon\""))
        XCTAssertTrue(unit.contains("Environment=\"HARNESS_HOME=/home/u/.local/share/harness\""))
        XCTAssertTrue(unit.contains("Restart=on-failure"))
        XCTAssertTrue(unit.contains("Type=simple"))
        XCTAssertTrue(unit.contains("WantedBy=default.target"))
        XCTAssertTrue(unit.contains("StandardError=append:/home/u/.local/share/harness/logs/daemon.log"))
        let special = try SystemdUserInstaller.unitContents(daemonPath: URL(fileURLWithPath: "/tmp/a $literal \"quoted\"/HarnessDaemon"), harnessHome: URL(fileURLWithPath: "/tmp/harness %h"), logPath: URL(fileURLWithPath: "/tmp/harness %h/log"))
        XCTAssertTrue(special.contains("ExecStart=:\"/tmp/a $literal \\\"quoted\\\"/HarnessDaemon\"")); XCTAssertTrue(special.contains("Environment=\"HARNESS_HOME=/tmp/harness %%h\""))
        XCTAssertThrowsError(try SystemdUserInstaller.unitContents(daemonPath: URL(fileURLWithPath: "/tmp/a\nExecStart=bad"), harnessHome: URL(fileURLWithPath: "/tmp/home"), logPath: URL(fileURLWithPath: "/tmp/log")))
    }

    func testCurrentBackendMatchesPlatform() {
        #if os(macOS)
        XCTAssertEqual(ServiceInstallers.current.backendName, "launchd")
        #else
        XCTAssertEqual(ServiceInstallers.current.backendName, "systemd --user")
        #endif
    }
}
