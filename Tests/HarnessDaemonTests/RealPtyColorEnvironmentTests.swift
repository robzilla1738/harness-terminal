import XCTest
@testable import HarnessDaemonCore

/// The child environment is the one `RealPty` builds at spawn. These cases set the
/// parent process environment, then read `env` from the forked child.
final class RealPtyColorEnvironmentTests: XCTestCase {
    private var savedNoColor: String?
    private var savedForce: String?

    override func setUp() {
        _ = testSIGPIPEIgnored
        savedNoColor = getenv("NO_COLOR").map { String(cString: $0) }
        savedForce = getenv("FORCE_COLOR").map { String(cString: $0) }
    }

    override func tearDown() {
        restore("NO_COLOR", savedNoColor)
        restore("FORCE_COLOR", savedForce)
    }

    func testSpawnStripsNoColorAndDisabledForceColor() throws {
        try assertChild(force: "0", expectForce: false)
        try assertChild(force: "false", expectForce: false)
        try assertChild(force: "off", expectForce: false)
        try assertChild(force: "1", expectForce: true)
    }

    private func assertChild(force: String, expectForce: Bool) throws {
        setenv("NO_COLOR", "1", 1)
        setenv("FORCE_COLOR", force, 1)
        let pty = try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 8,
            cols: 80,
            scrollbackBytes: 16 * 1024,
            launchArgumentsOverride: ["-c", "env"]
        )
        // `sh -c env` can exit inside `start()`. The handler has to be in place first,
        // or that exit is delivered to a nil `onExit` and the assertion never runs.
        let exited = expectation(description: "env child exited \(force)")
        pty.onExit = { _ in exited.fulfill() }
        pty.start()
        wait(for: [exited], timeout: 8)
        // The exit watcher can cancel the reader before the last PTY bytes are copied.
        // Give that copy a moment; a still-empty replay is a failed observation.
        XCTAssertTrue(waitUntil(timeout: 2) {
            pty.replay(fromSequence: nil).contains("COLORTERM=truecolor")
        }, "child env never reached scrollback for FORCE_COLOR=\(force)")
        let output = pty.replay(fromSequence: nil)
        pty.close()
        // Match the variable name at the start of a line. A substring check is wrong:
        // `PIP_NO_COLOR=1` contains `NO_COLOR=` and is a different variable.
        XCTAssertNil(envAssignment(output, "NO_COLOR"), "NO_COLOR leaked for FORCE_COLOR=\(force)")
        let forceValue = envAssignment(output, "FORCE_COLOR")
        if expectForce {
            XCTAssertEqual(forceValue, force, "FORCE_COLOR=\(force) should remain")
        } else {
            XCTAssertNil(forceValue, "FORCE_COLOR=\(force) should be stripped")
        }
    }

    /// Value of `KEY=value` in `env` output, or nil when that variable is absent.
    private func envAssignment(_ output: String, _ key: String) -> String? {
        let prefix = "\(key)="
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func restore(_ key: String, _ value: String?) {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
}
