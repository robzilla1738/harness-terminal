import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Live end-to-end for the spawn-time shell-integration injection: a real bash spawned
/// through the injection plan must emit OSC 133 prompt marks, still source the user's own
/// rc files, keep `$SHELL`/`$0` intact, and spawn untouched when the option is off.
/// zsh/fish run the same plan shape (covered purely in `ShellIntegrationInjectorTests`);
/// their live halves run on hosts that have them — each test skips when the shell is absent.
final class ShellIntegrationInjectionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        home = URL(fileURLWithPath: "/tmp/sii-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func bashPath() throws -> String {
        for candidate in ["/bin/bash", "/usr/bin/bash"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw XCTSkip("bash not installed")
    }

    /// Spawn a RealPty through the injection plan with a controlled $HOME and collect output.
    private func spawnInjectedBash(userHome: URL) throws -> (RealPty, OutputAccumulator) {
        let bash = try bashPath()
        guard let plan = ShellIntegrationInjector.plan(
            shellPath: bash, baseEnvironment: [:], home: home) else {
            // The stock macOS /bin/bash is 3.2, below the injection floor — the gate working
            // as designed. The Linux CI container (bash 5.x) runs the full end-to-end.
            throw XCTSkip("bash at \(bash) is below the 4.4 injection floor")
        }
        var env = plan.environment
        env["HOME"] = userHome.path
        env["HARNESS"] = "test" // the snippets gate on $HARNESS
        let pty = try RealPty(
            id: UUID().uuidString,
            cwd: userHome.path,
            shell: bash,
            extraEnvironment: env,
            launchArgumentsOverride: plan.argumentsOverride
        )
        let acc = OutputAccumulator()
        _ = pty.subscribe { data, _ in
            _ = acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: "")
        }
        pty.start()
        return (pty, acc)
    }

    func testInjectedBashEmitsPromptMarksAndSourcesUserRC() throws {
        let userHome = home.appendingPathComponent("user-home", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        // The user's own login file must still run (the shim replays it).
        try """
        export HARNESS_TEST_RC_RAN=yes
        """.write(to: userHome.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)

        let (pty, acc) = try spawnInjectedBash(userHome: userHome)
        defer { pty.close() }

        // OSC 133;A arrives with the first prompt — the injection worked end to end.
        XCTAssertTrue(waitUntil { acc.contains("\u{1b}]133;A") },
                      "injected bash must emit OSC 133 prompt marks; got: \(acc.snapshot.suffix(300).debugDescription)")

        // The user's rc ran (shim replayed the login files `-l` would have read)…
        pty.write("echo RC=$HARNESS_TEST_RC_RAN\n")
        XCTAssertTrue(waitUntil { acc.contains("RC=yes") }, "user .bash_profile must still be sourced")

        // …and the shim's plumbing variables don't leak into the session.
        pty.write("echo ENVVAR=[$ENV] LOGINFLAG=[$HARNESS_BASH_LOGIN]\n")
        XCTAssertTrue(waitUntil { acc.contains("ENVVAR=[]") && acc.contains("LOGINFLAG=[]") },
                      "shim must clean up ENV/HARNESS_BASH_LOGIN after itself")
    }

    /// A user `set-environment` for any of the plan's keys must drop the ENTIRE plan:
    /// applying `--posix` with the USER's `$ENV` would leave the pane stuck in posix mode
    /// with no login replay. The pane spawns untouched instead — default `-l` argv,
    /// posix off, the user's `$ENV` delivered intact.
    func testUserEnvCollisionDropsEntirePlan() throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        setenv("HARNESS_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        }
        try HarnessPaths.ensureDirectories()

        let registry = SurfaceRegistry()
        guard case .ok = registry.handle(.setEnvironment(
            sessionID: nil, key: "ENV", value: "/tmp/their-env-file"
        )) else { return XCTFail("setEnvironment failed") }

        let surfaceID = UUID().uuidString
        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: surfaceID, cwd: NSTemporaryDirectory(), shell: try bashPath(),
            rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface failed") }

        _ = registry.handle(.sendData(surfaceID: surfaceID, data: Data(
            "echo MODE=login:$(shopt -q login_shell && echo yes || echo no),posix:$(shopt -oq posix && echo on || echo off),env:[$ENV]\n".utf8)))
        let sawUntouched = waitUntil {
            guard case let .text(text) = registry.handle(.capturePane(surfaceID: surfaceID, includeScrollback: true))
            else { return false }
            return text.contains("MODE=login:yes,posix:off,env:[/tmp/their-env-file]")
        }
        XCTAssertTrue(sawUntouched,
                      "user ENV collision must drop the whole plan: -l argv (login shell), posix off, user $ENV intact")
    }

    func testRegistryOptionOffSpawnsUntouched() throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        setenv("HARNESS_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        }
        try HarnessPaths.ensureDirectories()

        let registry = SurfaceRegistry()
        guard case .ok = registry.handle(.setOption(
            scope: "global", target: nil, key: "shell-integration", rawValue: "off"
        )) else { return XCTFail("setOption failed") }

        let surfaceID = UUID().uuidString
        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: surfaceID, cwd: NSTemporaryDirectory(), shell: try bashPath(),
            rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface failed") }

        // The opted-out shell must have no injection plumbing in its environment.
        let acc = OutputAccumulator()
        _ = registry.handle(.sendData(surfaceID: surfaceID, data: Data("echo PROBE=[$ENV][$ZDOTDIR]\n".utf8)))
        guard case let .text(captured) = registry.handle(.capturePane(surfaceID: surfaceID, includeScrollback: true))
        else { return XCTFail("capture failed") }
        _ = acc.appendAndContains(captured, marker: "")
        let sawClean = waitUntil {
            guard case let .text(text) = registry.handle(.capturePane(surfaceID: surfaceID, includeScrollback: true))
            else { return false }
            return text.contains("PROBE=[][]")
        }
        XCTAssertTrue(sawClean, "with shell-integration off, no ENV/ZDOTDIR plumbing is injected")
    }
}
