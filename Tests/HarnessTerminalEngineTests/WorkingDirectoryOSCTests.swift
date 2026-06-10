import XCTest
@testable import HarnessTerminalEngine

/// OSC 7 (`ESC ] 7 ; file://<host>/<path> ST`) reports the shell's working directory. The engine
/// accepts only a `file://` URL resolving to an absolute path so hostile output can't steer the
/// cwd inherited by new tabs to an attacker-chosen value.
final class WorkingDirectoryOSCTests: XCTestCase {
    private func reportedCwd(_ payload: String) -> String? {
        let term = TerminalEmulator(cols: 80, rows: 24)
        var captured: String?
        term.onWorkingDirectoryChange = { captured = $0 }
        term.feed("\u{1b}]7;\(payload)\u{07}")
        return captured
    }

    func testAbsoluteFileURLReportsPath() {
        XCTAssertEqual(reportedCwd("file://localhost/Users/me/src"), "/Users/me/src")
    }

    func testFileURLWithoutHostReportsPath() {
        XCTAssertEqual(reportedCwd("file:///etc"), "/etc")
    }

    func testPercentEncodedPathIsDecoded() {
        XCTAssertEqual(reportedCwd("file://localhost/Users/me/a%20b"), "/Users/me/a b")
    }

    func testNonFileSchemeIsRejected() {
        XCTAssertNil(reportedCwd("http://evil.example/etc/passwd"))
    }

    func testRelativeFileURLIsRejected() {
        // `file:relative` carries a non-absolute path — never report it as a cwd.
        XCTAssertNil(reportedCwd("file:relative/path"))
    }

    func testEmptyPathIsRejected() {
        XCTAssertNil(reportedCwd("file://localhost"))
    }

    func testJunkIsRejected() {
        XCTAssertNil(reportedCwd("not a url"))
    }
}
