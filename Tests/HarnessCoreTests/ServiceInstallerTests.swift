import XCTest
@testable import HarnessCore

final class ServiceInstallerTests: XCTestCase {
    func testSystemdUnitContents() {
        let unit = SystemdUserInstaller.unitContents(
            daemonPath: URL(fileURLWithPath: "/opt/harness/HarnessDaemon"),
            harnessHome: URL(fileURLWithPath: "/home/u/.local/share/harness"),
            logPath: URL(fileURLWithPath: "/home/u/.local/share/harness/logs/daemon.log")
        )
        XCTAssertTrue(unit.contains("ExecStart=/opt/harness/HarnessDaemon"))
        XCTAssertTrue(unit.contains("Environment=HARNESS_HOME=/home/u/.local/share/harness"))
        XCTAssertTrue(unit.contains("Restart=on-failure"))
        XCTAssertTrue(unit.contains("Type=simple"))
        XCTAssertTrue(unit.contains("WantedBy=default.target"))
        XCTAssertTrue(unit.contains("StandardError=append:/home/u/.local/share/harness/logs/daemon.log"))
    }

    func testCurrentBackendMatchesPlatform() {
        #if os(macOS)
        XCTAssertEqual(ServiceInstallers.current.backendName, "launchd")
        #else
        XCTAssertEqual(ServiceInstallers.current.backendName, "systemd --user")
        #endif
    }
}
