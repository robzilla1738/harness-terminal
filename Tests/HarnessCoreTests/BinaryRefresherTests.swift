import XCTest
@testable import HarnessCore

final class BinaryRefresherTests: XCTestCase {
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
        // Remove-then-copy must land on a fresh inode: the kernel caches code signatures by
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
