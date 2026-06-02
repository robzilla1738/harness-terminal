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

    func testValidatedSocketPathAcceptsShortHome() throws {
        setenv("HARNESS_HOME", "/tmp/harness-sock-test", 1)
        XCTAssertEqual(try HarnessPaths.validatedSocketPath(), "/tmp/harness-sock-test/harness.sock")
    }

    func testValidatedSocketPathRejectsOverlongHome() {
        // A HARNESS_HOME deep enough to push harness.sock past sun_path (104) must fail clearly,
        // not silently truncate and connect/bind to the wrong socket.
        let deep = "/tmp/" + String(repeating: "x", count: 120)
        setenv("HARNESS_HOME", deep, 1)
        XCTAssertGreaterThanOrEqual(HarnessPaths.socketURL.path.utf8.count, HarnessPaths.maxSocketPathLength)
        XCTAssertThrowsError(try HarnessPaths.validatedSocketPath()) { error in
            guard case HarnessPathsError.socketPathTooLong = error else {
                return XCTFail("expected socketPathTooLong, got \(error)")
            }
        }
    }

    func testWithoutOverrideFallsBackToPlatformDefaultHarnessHome() {
        unsetenv("HARNESS_HOME")
        let path = HarnessPaths.applicationSupport.path
        XCTAssertFalse(path.isEmpty)
        #if canImport(Glibc)
        XCTAssertTrue(path.hasSuffix("/.local/share/harness"), "expected an XDG harness data path, got \(path)")
        #else
        XCTAssertTrue(path.hasSuffix("/Harness"), "expected an Application Support/Harness path, got \(path)")
        #endif
    }

    func testEnsureDirectoriesCreatesOwnerOnlyHome() throws {
        let dir = URL(fileURLWithPath: "/tmp/harness-perms-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        try HarnessPaths.ensureDirectories()
        // The Harness home holds the control socket, session layout, and shell-running hooks;
        // it (and the subdirs we own) must be 0o700 so no other local user can read or tamper.
        for url in [HarnessPaths.applicationSupport, HarnessPaths.sessionsDirectory, HarnessPaths.logsDirectory] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(perms, 0o700, "expected 0o700 on \(url.lastPathComponent), got \(perms.map { String($0, radix: 8) } ?? "nil")")
        }
    }

    func testEnsureDirectoriesTightensPreexistingLoosePermissions() throws {
        let dir = URL(fileURLWithPath: "/tmp/harness-perms-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate a home created by an older build under the default 0o755 umask.
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try HarnessPaths.ensureDirectories()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    // MARK: - Config-file persistence helpers

    func testBackupCorruptFileMovesAsideAndReplacesStaleBackup() throws {
        let dir = URL(fileURLWithPath: "/tmp/harness-corrupt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let backup = file.appendingPathExtension("corrupt")

        try Data("first".utf8).write(to: file)
        XCTAssertTrue(HarnessPaths.backupCorruptFile(at: file, label: "Test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "original moved aside")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "first")

        // A second corruption replaces the stale backup rather than failing on the existing one.
        try Data("second".utf8).write(to: file)
        XCTAssertTrue(HarnessPaths.backupCorruptFile(at: file, label: "Test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "second")
    }

    func testBackupCorruptFileReturnsFalseWhenSourceMissing() {
        // No file to move → the move fails; the helper must report false (not a misleading success)
        // and must not crash.
        let missing = URL(fileURLWithPath: "/tmp/harness-missing-\(UUID().uuidString.prefix(8)).json")
        XCTAssertFalse(HarnessPaths.backupCorruptFile(at: missing, label: "Test"))
    }

    func testAtomicWriteRoundTrips() throws {
        let dir = URL(fileURLWithPath: "/tmp/harness-write-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.json")
        XCTAssertTrue(HarnessPaths.atomicWrite(Data("payload".utf8), to: file, label: "Test"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "payload")
    }
}
