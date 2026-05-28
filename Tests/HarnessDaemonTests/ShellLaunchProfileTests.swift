import XCTest
@testable import HarnessDaemonCore

final class ShellLaunchProfileTests: XCTestCase {
    func testKnownBourneStyleShellsUseLoginFlag() {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/dash", "/bin/ksh"] {
            XCTAssertEqual(ShellLaunchProfile.make(shell: shell).argv, [shell, "-l"])
        }
    }

    func testFishKeepsNoQueryTermFeature() {
        XCTAssertEqual(
            ShellLaunchProfile.make(shell: "/opt/homebrew/bin/fish").argv,
            ["/opt/homebrew/bin/fish", "--features=no-query-term", "-l"]
        )
    }

    func testModernShellsUseTheirNativeLoginFlags() {
        XCTAssertEqual(ShellLaunchProfile.make(shell: "/opt/homebrew/bin/nu").argv, ["/opt/homebrew/bin/nu", "--login"])
        XCTAssertEqual(ShellLaunchProfile.make(shell: "/opt/homebrew/bin/pwsh").argv, ["/opt/homebrew/bin/pwsh", "-Login"])
        XCTAssertEqual(ShellLaunchProfile.make(shell: "/opt/homebrew/bin/xonsh").argv, ["/opt/homebrew/bin/xonsh", "--login"])
    }

    func testUnknownShellLaunchesWithoutGuessedFlags() {
        XCTAssertEqual(ShellLaunchProfile.make(shell: "/usr/local/bin/custom-shell").argv, ["/usr/local/bin/custom-shell"])
    }
}
