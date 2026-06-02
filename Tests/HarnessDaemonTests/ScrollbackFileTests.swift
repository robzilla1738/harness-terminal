import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Deterministic coverage for the on-disk scrollback persistence (`ScrollbackFile`) — no PTY,
/// no socket, so this runs in the normal `swift test` suite (not behind the live-daemon gate).
/// Uses an isolated `HARNESS_HOME` so `ensureDirectories` / `scrollbackFileURL` resolve into a
/// temp tree instead of the real `~/Library/Application Support`.
final class ScrollbackFileTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-scrollback-\(UUID().uuidString)", isDirectory: true)
        setenv("HARNESS_HOME", home.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    private func url(_ id: String = UUID().uuidString) -> URL {
        HarnessPaths.scrollbackFileURL(forSurfaceID: id)
    }

    func testAppendThenLoadTailRoundTrips() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        file.append(Data("hello ".utf8))
        file.append(Data("world".utf8))
        file.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 64 * 1024)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "hello world")
    }

    func testLoadTailReturnsSuffixWhenLargerThanMax() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        file.append(Data("ABCDEFGHIJ".utf8))
        file.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 4)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "GHIJ")
    }

    func testOpenCompactsExistingLogToRetentionCap() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        try HarnessPaths.ensureDirectories()
        try Data(repeating: UInt8(ascii: "x"), count: cap * 2)
            .write(to: fileURL, options: .atomic)

        _ = ScrollbackFile(url: fileURL, retentionCap: cap)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, cap)
    }

    func testCompactionTrimsToRetentionCap() throws {
        let fileURL = url()
        let cap = 64 * 1024 // the floor; highWater is 2× this
        let file = ScrollbackFile(url: fileURL, retentionCap: cap)
        // Write past the 128 KiB high-water mark in one flush so compaction fires.
        let total = 200 * 1024
        file.append(Data(repeating: UInt8(ascii: "x"), count: total))
        file.flush()

        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        XCTAssertNotNil(size)
        // Compacted back down to ~the retention cap, not the full 200 KiB written.
        XCTAssertLessThanOrEqual(size ?? .max, cap + 1024)
        XCTAssertGreaterThan(size ?? 0, cap / 2)
    }

    func testResetDropsHistory() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        file.append(Data("transient".utf8))
        file.flush()
        XCTAssertFalse(ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096).isEmpty)

        file.reset()
        // reset() is async on the file's queue; a subsequent synchronous flush serializes behind it.
        file.flush()
        XCTAssertTrue(ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096).isEmpty)
    }

    /// A new `ScrollbackFile` over an existing log keeps appending to it (the cross-restart
    /// continuity path), rather than truncating.
    func testReopenAppendsToExistingLog() throws {
        let fileURL = url()
        let first = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        first.append(Data("before-".utf8))
        first.flush()

        let second = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        second.append(Data("after".utf8))
        second.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 64 * 1024)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "before-after")
    }
}
