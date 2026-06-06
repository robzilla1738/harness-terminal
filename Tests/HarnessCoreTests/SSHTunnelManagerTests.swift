import Foundation
import XCTest
@testable import HarnessCore

/// Characterization tests for `SSHTunnelManager` — the SSH-forwarded remote-daemon socket
/// transport. These exercise the lifecycle (spawn / reuse / teardown), socket-path construction,
/// stale-tunnel cleanup, and the failure modes (ssh exits immediately, socket never becomes
/// reachable, malformed host entries) WITHOUT making any real SSH connection or touching the
/// network. The two injectable seams on the manager (`makeTunnelProcess` / `reachabilityProbe`)
/// default to the production builders, so production callers are unaffected; here we substitute a
/// controllable local child process and a deterministic reachability predicate.
final class SSHTunnelManagerTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Keep the root short: a tunnel socket lives under runtime/tunnels/ and must fit the
        // 104-byte sun_path limit, so use /tmp + a truncated UUID rather than the macOS temp dir.
        home = URL(fileURLWithPath: "/tmp/hsshtun-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", home.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    private func host(
        name: String = "devbox",
        target: String = "rob@devbox",
        remoteSocket: String = "/home/rob/.local/share/harness/harness.sock",
        sshArgs: [String] = []
    ) -> RemoteHost {
        RemoteHost(name: name, sshTarget: target, remoteSocketPath: remoteSocket, sshArgs: sshArgs)
    }

    /// A child process that runs until killed (so `isRunning` / `terminate()` behave like a live
    /// ssh tunnel) but never forwards anything.
    private func longRunningProcessFactory() -> (RemoteHost, URL) throws -> Process {
        { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "while true; do sleep 1; done"]
            return process
        }
    }

    /// A child process that exits immediately — models `ssh` failing fast on bad host/auth/forward.
    private func immediateExitProcessFactory() -> (RemoteHost, URL) throws -> Process {
        { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            return process
        }
    }

    // MARK: - Socket-path construction (pure, no SSH)

    func testTunnelSocketPathIsDeterministicAndUnderTunnelsDir() {
        let a = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        let b = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        XCTAssertEqual(a, b, "same host name must map to a stable socket path across calls")
        XCTAssertEqual(a.deletingLastPathComponent().standardizedFileURL,
                       HarnessPaths.tunnelsDirectory.standardizedFileURL)
        XCTAssertTrue(a.lastPathComponent.hasSuffix(".sock"))
    }

    func testTunnelSocketPathDisambiguatesNamesThatSanitizeAlike() {
        // "dev.box" and "dev-box" both sanitize their punctuation to '-'; the trailing hash of the
        // full name must keep them on distinct sockets so they can't clobber each other.
        let dotted = HarnessPaths.tunnelSocketURL(forHost: "dev.box")
        let dashed = HarnessPaths.tunnelSocketURL(forHost: "dev-box")
        XCTAssertNotEqual(dotted, dashed)
    }

    // MARK: - Argument construction / malformed host entries

    func testSSHArgumentsCarryHardeningOptionsAndForwardSpec() throws {
        let args = try SSHTunnelManager.sshArguments(
            for: host(remoteSocket: "/run/user/1000/harness/harness.sock"),
            localSocket: URL(fileURLWithPath: "/tmp/t.sock"))

        // Fixed safety options always lead.
        XCTAssertEqual(args.prefix(8), [
            "ssh", "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ServerAliveInterval=15",
        ])
        // The forward spec and target close it out.
        XCTAssertEqual(args.suffix(3), [
            "-L", "/tmp/t.sock:/run/user/1000/harness/harness.sock",
            "rob@devbox",
        ])
    }

    func testMalformedHostTargetIsRejected() {
        // A target that looks like an option must not be passed through as one.
        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host(target: "-oProxyCommand=evil"),
            localSocket: URL(fileURLWithPath: "/tmp/t.sock"))) { error in
            XCTAssertTrue(error is SSHTunnelError)
        }
    }

    func testMalformedHostTargetWithWhitespaceIsRejected() {
        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host(target: "rob@dev box"),
            localSocket: URL(fileURLWithPath: "/tmp/t.sock")))
    }

    func testControlCharacterInRemoteSocketIsRejected() {
        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host(remoteSocket: "/run/harness\u{0007}/harness.sock"),
            localSocket: URL(fileURLWithPath: "/tmp/t.sock")))
    }

    // MARK: - Lifecycle: spawn / reuse / teardown

    func testEndpointSpawnsTunnelAndBecomesReachable() throws {
        let expectedSocket = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { $0 == .unix(path: expectedSocket.path) })

        let endpoint = try manager.endpoint(for: host(), waitTimeout: 2)
        defer { manager.stopAll() }

        XCTAssertEqual(endpoint, .unix(path: expectedSocket.path))
        XCTAssertTrue(manager.isConnected("devbox"), "a live tunnel process should report connected")
    }

    func testEndpointReusesLiveTunnelWithoutRespawning() throws {
        let expectedSocket = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        var spawnCount = 0
        let manager = SSHTunnelManager(
            makeTunnelProcess: { _, _ in
                spawnCount += 1
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "while true; do sleep 1; done"]
                return process
            },
            reachabilityProbe: { $0 == .unix(path: expectedSocket.path) })
        defer { manager.stopAll() }

        _ = try manager.endpoint(for: host(), waitTimeout: 2)
        _ = try manager.endpoint(for: host(), waitTimeout: 2)
        XCTAssertEqual(spawnCount, 1, "a still-reachable tunnel must be reused, not respawned")
    }

    func testStopTearsDownProcessAndRemovesSocketFile() throws {
        let expectedSocket = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { _ in true })

        _ = try manager.endpoint(for: host(), waitTimeout: 2)
        // The reachability probe is faked, so drop a real socket file to prove cleanup removes it.
        FileManager.default.createFile(atPath: expectedSocket.path, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedSocket.path))
        XCTAssertTrue(manager.isConnected("devbox"))

        manager.stop(host: "devbox")
        XCTAssertFalse(manager.isConnected("devbox"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedSocket.path),
                       "stop must delete the forwarded socket file")
    }

    func testStopIsNoOpForUnknownHost() {
        let manager = SSHTunnelManager(makeTunnelProcess: nil, reachabilityProbe: { _ in false })
        manager.stop(host: "never-connected") // must not crash
        XCTAssertFalse(manager.isConnected("never-connected"))
    }

    func testStopAllTearsDownEveryTunnel() throws {
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { _ in true })

        _ = try manager.endpoint(for: host(name: "a", target: "rob@a"), waitTimeout: 2)
        _ = try manager.endpoint(for: host(name: "b", target: "rob@b"), waitTimeout: 2)
        XCTAssertTrue(manager.isConnected("a"))
        XCTAssertTrue(manager.isConnected("b"))

        manager.stopAll()
        XCTAssertFalse(manager.isConnected("a"))
        XCTAssertFalse(manager.isConnected("b"))
    }

    // MARK: - Stale-tunnel detection / respawn

    func testStaleTunnelIsTornDownAndRespawned() throws {
        let expectedSocket = HarnessPaths.tunnelSocketURL(forHost: "devbox")
        var spawnCount = 0
        // First spawn exits immediately so the next endpoint() sees a dead tunnel; we still report
        // reachable from the second spawn onward so the call can succeed.
        let manager = SSHTunnelManager(
            makeTunnelProcess: { _, _ in
                spawnCount += 1
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = spawnCount == 1
                    ? ["-c", "exit 0"]
                    : ["-c", "while true; do sleep 1; done"]
                return process
            },
            // Unreachable on the first (immediately-dead) spawn, reachable thereafter.
            reachabilityProbe: { _ in spawnCount >= 2 })
        defer { manager.stopAll() }

        // First call: spawn 1 dies immediately and never gets reachable → notReady.
        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 1))
        XCTAssertFalse(manager.isConnected("devbox"), "a dead tunnel must not be reported connected")

        // Second call: stale entry is gone, spawn 2 comes up reachable.
        let endpoint = try manager.endpoint(for: host(), waitTimeout: 2)
        XCTAssertEqual(endpoint, .unix(path: expectedSocket.path))
        XCTAssertEqual(spawnCount, 2)
    }

    // MARK: - Failure modes

    func testSSHExitingImmediatelyBailsEarlyWithExitedError() {
        let manager = SSHTunnelManager(
            makeTunnelProcess: immediateExitProcessFactory(),
            reachabilityProbe: { _ in false })

        // Generous timeout: the early-bail on process death must throw long before it elapses, and
        // it must throw .exitedEarly (carrying the ssh exit status) — NOT .notReady, which would
        // hide a bad-host/bad-credentials cause behind a generic timeout message.
        let start = Date()
        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 30)) { error in
            guard case let SSHTunnelError.exitedEarly(host, status) = error else {
                return XCTFail("expected .exitedEarly, got \(error)")
            }
            XCTAssertEqual(host, "devbox")
            XCTAssertEqual(status, 0, "the immediate-exit child returns 0; the status must be carried through")
            // The rendered message must read as an early exit, not a timeout.
            let text = "\(error)"
            XCTAssertTrue(text.contains("ssh exited with status"), "message should report the ssh exit, got: \(text)")
            XCTAssertTrue(text.contains("credentials"), "message should point at host/credentials, got: \(text)")
            XCTAssertFalse(text.contains("did not become ready in time"), "must not reuse the timeout wording")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "a dead ssh process should short-circuit, not wait out the full timeout")
        XCTAssertFalse(manager.isConnected("devbox"))
    }

    func testSocketNeverReachableTimesOutWithNotReady() {
        // Process stays alive but the socket never answers → wait out the timeout, then notReady.
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { _ in false })
        defer { manager.stopAll() }

        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 0.5)) { error in
            guard case SSHTunnelError.notReady = error else {
                return XCTFail("expected .notReady, got \(error)")
            }
        }
        // On the notReady path the manager tears its own tunnel down.
        XCTAssertFalse(manager.isConnected("devbox"))
    }

    func testProcessThatFailsToLaunchSurfacesAsNotReady() {
        // A nonexistent executable makes process.run() throw → launchFailed inside spawnTunnel,
        // which propagates out of endpoint(for:).
        let manager = SSHTunnelManager(
            makeTunnelProcess: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/nonexistent/definitely-not-ssh")
                return process
            },
            reachabilityProbe: { _ in false })

        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 1)) { error in
            guard case SSHTunnelError.launchFailed = error else {
                return XCTFail("expected .launchFailed, got \(error)")
            }
        }
        XCTAssertFalse(manager.isConnected("devbox"))
    }

    func testMalformedHostPropagatesInvalidConfigurationFromEndpoint() {
        // An unsafe target reaches the default process builder (the real sshArguments) and throws
        // invalidConfiguration before any child is spawned.
        let manager = SSHTunnelManager()
        XCTAssertThrowsError(try manager.endpoint(
            for: host(target: "-oProxyCommand=evil"), waitTimeout: 1)) { error in
            guard case SSHTunnelError.invalidConfiguration = error else {
                return XCTFail("expected .invalidConfiguration, got \(error)")
            }
        }
    }
}
