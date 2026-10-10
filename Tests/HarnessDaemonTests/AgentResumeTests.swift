import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class AgentResumeShellTests: XCTestCase {
    func testResumeRequiresFreshPromptAndInsertsWithoutSubmittingOrRetrying() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hresume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = try RealPty(id: UUID().uuidString, cwd: directory.path, shell: "/bin/sh",
            extraEnvironment: ["PS1": "\u{1b}]133;A\u{7}PROOF> "], launchArgumentsOverride: ["-i"])
        defer { pty.close() }
        XCTAssertNil(pty.freshShellIdentity)
        pty.start()
        XCTAssertTrue(waitUntil { pty.freshShellIdentity != nil })
        let identity = try XCTUnwrap(pty.freshShellIdentity)
        let result = directory.appendingPathComponent("submitted")
        let command = "printf resumed > " + ShellQuoting.quote(result.path)
        try pty.insertResume(command, expectedIdentity: identity)
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("printf resumed") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        XCTAssertNil(pty.freshShellIdentity)
        XCTAssertThrowsError(try pty.insertResume(command, expectedIdentity: identity))
        XCTAssertTrue(pty.write("\r"))
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: result.path) })
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "resumed")
        pty.respawn(clearHistory: false, fallbackCwd: directory.path)
        XCTAssertTrue(waitUntil { pty.freshShellIdentity != nil })
        XCTAssertThrowsError(try pty.insertResume(command, expectedIdentity: identity))
        XCTAssertTrue(pty.write("user input"))
        XCTAssertNil(pty.freshShellIdentity)
        XCTAssertTrue(pty.respawn(clearHistory: false, fallbackCwd: directory.path))
        XCTAssertTrue(waitUntil { pty.freshShellIdentity != nil })
        let restoredIdentity = try XCTUnwrap(pty.freshShellIdentity)
        let automaticResult = directory.appendingPathComponent("automatic")
        let automaticCommand = "printf automatic > " + ShellQuoting.quote(automaticResult.path)
        try pty.insertResume(automaticCommand, expectedIdentity: restoredIdentity, submit: true)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: automaticResult.path) })
        XCTAssertEqual(try String(contentsOf: automaticResult, encoding: .utf8), "automatic")
        XCTAssertThrowsError(try pty.insertResume(automaticCommand, expectedIdentity: restoredIdentity, submit: true))
    }
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }
}
