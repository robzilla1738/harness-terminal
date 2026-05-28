import XCTest
@testable import HarnessCore

final class HarnessPathsTests: XCTestCase {
    private var previousHome: String?

    override func setUp() {
        super.setUp()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
    }

    override func tearDown() {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        super.tearDown()
    }

    func testHarnessHomeOverrideRootsAllPaths() {
        setenv("HARNESS_HOME", "/tmp/harness-paths-test", 1)
        XCTAssertEqual(HarnessPaths.applicationSupport.path, "/tmp/harness-paths-test")
        XCTAssertEqual(HarnessPaths.socketURL.path, "/tmp/harness-paths-test/harness.sock")
        XCTAssertEqual(HarnessPaths.snapshotURL.path, "/tmp/harness-paths-test/sessions/layout.json")
        XCTAssertEqual(HarnessPaths.settingsURL.lastPathComponent, "settings.json")
    }

    func testHarnessHomeExpandsTilde() {
        setenv("HARNESS_HOME", "~/.harness-paths-test", 1)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(HarnessPaths.applicationSupport.path, "\(home)/.harness-paths-test")
    }

    func testWithoutOverrideFallsBackToApplicationSupportHarness() {
        unsetenv("HARNESS_HOME")
        let path = HarnessPaths.applicationSupport.path
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.hasSuffix("/Harness"), "expected an Application Support/Harness path, got \(path)")
    }
}
