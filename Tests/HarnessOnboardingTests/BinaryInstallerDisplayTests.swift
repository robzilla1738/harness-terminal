import XCTest
@testable import HarnessOnboarding

final class BinaryInstallerDisplayTests: XCTestCase {
    /// Regression: the install screen's Daemon row used to read "Found harness-cli" — identical to
    /// the CLI row — because the `.found` display hardcoded the CLI name. It must report the
    /// detected binary's own name.
    @MainActor
    func testFoundDisplayUsesDetectedBinaryName() {
        let cli = BinaryInstaller.DetectionStatus.found(
            version: nil, path: URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/harness-cli")
        )
        let daemon = BinaryInstaller.DetectionStatus.found(
            version: nil, path: URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon")
        )
        XCTAssertEqual(cli.display, "Found harness-cli")
        XCTAssertEqual(daemon.display, "Found HarnessDaemon")
        XCTAssertNotEqual(cli.display, daemon.display)
    }

    @MainActor
    func testFoundDisplayPrefersExplicitVersion() {
        let withVersion = BinaryInstaller.DetectionStatus.found(
            version: "1.1.2", path: URL(fileURLWithPath: "/x/harness-cli")
        )
        XCTAssertEqual(withVersion.display, "Found 1.1.2")
    }
}
