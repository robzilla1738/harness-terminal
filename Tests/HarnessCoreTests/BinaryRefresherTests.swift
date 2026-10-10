import XCTest
@testable import HarnessCore

final class BinaryRefresherTests: XCTestCase {
    #if os(macOS)
    func testHelperInstallPreservesBundleAndRejectsDamagedReplacement() throws {
        let dir = try makeDir()
        let bundle = dir.appendingPathComponent("source/HarnessDaemon.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/HarnessDaemon")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let metadata: [String: String] = ["CFBundleExecutable": "HarnessDaemon", "CFBundleIdentifier": "com.robert.harness.fixture.daemon", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        // Opaque fixture proves that installation retains the whole bundle; it
        // does not claim to authorize Keychain access or validate an Apple profile.
        let profile = Data("opaque profile fixture".utf8)
        try profile.write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        let signing = Process(); signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", bundle.path]
        signing.standardError = FileHandle.nullDevice
        try signing.run(); signing.waitUntilExit(); XCTAssertEqual(signing.terminationStatus, 0)
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent("HarnessDaemon")
        try write("previous executable", to: destination)
        try BinaryRefresher.copyExecutable(from: executable, to: destination)
        let installed = try XCTUnwrap(BinaryRefresher.ownedHelperBundle(forInstalledExecutable: destination))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/embedded.provisionprofile")), profile)
        XCTAssertEqual(HarnessToolLocator.companion("HarnessSessionHost", to: destination), bin.appendingPathComponent(".tool-bundles/HarnessSessionHost.app/Contents/MacOS/HarnessSessionHost"))
        let running = Process(); running.executableURL = destination
        try running.run(); running.waitUntilExit(); XCTAssertEqual(running.terminationStatus, 0)
        var original = try Data(contentsOf: destination)
        XCTAssertFalse(try BinaryRefresher.refreshIfChanged(source: executable, destination: destination))
        let renewedProfile = Data("renewed opaque profile fixture".utf8)
        try renewedProfile.write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        let renewal = Process(); renewal.executableURL = signing.executableURL; renewal.arguments = signing.arguments
        renewal.standardError = FileHandle.nullDevice
        try renewal.run(); renewal.waitUntilExit(); XCTAssertEqual(renewal.terminationStatus, 0)
        XCTAssertTrue(try BinaryRefresher.refreshIfChanged(source: executable, destination: destination), "a renewed signed profile updates the complete bundle")
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/embedded.provisionprofile")), renewedProfile)
        original = try Data(contentsOf: destination)
        try Data("damaged profile with unchanged executable".utf8).write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        XCTAssertThrowsError(try BinaryRefresher.refreshIfChanged(source: executable, destination: destination), "resource-only differences must be checked even when executable bytes match")
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try renewedProfile.write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        try FileManager.default.removeItem(at: destination)
        try BinaryRefresher.copyExecutable(from: installed.appendingPathComponent("Contents/MacOS/HarnessDaemon"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original, "reinstall repairs the stable public alias")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/usr/bin/true")
        XCTAssertThrowsError(try BinaryRefresher.copyExecutable(from: executable, to: destination))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/usr/bin/true", "an unrelated alias is preserved")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: ".tool-bundles/HarnessDaemon.app/Contents/MacOS/HarnessDaemon")
        try write("damaged replacement", to: executable)
        XCTAssertThrowsError(try BinaryRefresher.copyExecutable(from: executable, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/embedded.provisionprofile")), renewedProfile)
    }
    #endif

    func testFailedCopyPreservesInstalledBinary() throws {
        let dir = try makeDir()
        let destination = dir.appendingPathComponent("installed")
        try write("working executable", to: destination)
        let original = try inode(destination)
        XCTAssertThrowsError(try BinaryRefresher.copyExecutable(from: dir.appendingPathComponent("missing"), to: destination))
        XCTAssertEqual(try inode(destination), original)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "working executable")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["installed"])
    }
    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hbr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ bytes: String, to url: URL) throws {
        try Data(bytes.utf8).write(to: url)
    }

    private func inode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? -1
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testDifferingContentsAreRefreshedWithNewInodeAndExecutableBits() throws {
        let dir = try makeDir()
        let source = dir.appendingPathComponent("source")
        let dest = dir.appendingPathComponent("dest")
        try write("new daemon", to: source)
        try write("old daemon", to: dest)
        // Hard-link the pre-refresh file so its inode stays allocated through the refresh —
        // otherwise the filesystem can hand the freed inode number straight back to the new
        // file (observed on Linux ext4) and the inequality below would be flaky.
        let keeper = dir.appendingPathComponent("keeper")
        try FileManager.default.linkItem(at: dest, to: keeper)

        XCTAssertTrue(try BinaryRefresher.refreshIfChanged(source: source, destination: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new daemon")
        XCTAssertEqual(try mode(dest), 0o755)
        // Atomic replacement must land on a fresh inode: the kernel caches code signatures by
        // vnode, so overwriting in place gets the next daemon launch killed (OS_REASON_CODESIGNING).
        XCTAssertNotEqual(try inode(dest), try inode(keeper),
                          "refresh must replace the inode, not overwrite in place")
        XCTAssertEqual(try String(contentsOf: keeper, encoding: .utf8), "old daemon",
                       "the old inode must be untouched — proof we didn't write through it")
    }

    func testIdenticalContentsAreLeftAlone() throws {
        let dir = try makeDir()
        let source = dir.appendingPathComponent("source")
        let dest = dir.appendingPathComponent("dest")
        try write("same bytes", to: source)
        try write("same bytes", to: dest)
        let originalInode = try inode(dest)

        XCTAssertFalse(try BinaryRefresher.refreshIfChanged(source: source, destination: dest))
        XCTAssertEqual(try inode(dest), originalInode, "an up-to-date copy must not be touched")
    }

    func testMissingSourceIsANoOp() throws {
        let dir = try makeDir()
        let dest = dir.appendingPathComponent("dest")
        try write("installed", to: dest)

        XCTAssertFalse(try BinaryRefresher.refreshIfChanged(
            source: dir.appendingPathComponent("nope"), destination: dest))
        XCTAssertFalse(try BinaryRefresher.refreshIfChanged(source: nil, destination: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "installed")
    }

    /// The never-create guard: launch-time refresh only updates copies an installer already
    /// put there — it must not create a bin/ install as a side effect.
    func testMissingDestinationIsANoOp() throws {
        let dir = try makeDir()
        let source = dir.appendingPathComponent("source")
        let dest = dir.appendingPathComponent("dest")
        try write("new daemon", to: source)

        XCTAssertFalse(try BinaryRefresher.refreshIfChanged(source: source, destination: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "refresh must never create an install that wasn't there")
    }

    func testCopyExecutableInPlaceStillSetsPermissions() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("binary")
        try write("payload", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try BinaryRefresher.copyExecutable(from: file, to: file)
        XCTAssertEqual(try mode(file), 0o755)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "payload")
    }
}
