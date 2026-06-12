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

    func testAppendFallbackPreservesExistingLogWhenOpenForWritingFails() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024)
        file.append(Data("first".utf8))
        file.flush()

        // Make the file unopenable for writing so appendToDisk takes the atomic-rewrite
        // fallback. The fallback must rewrite existing+new — not replace the whole log
        // with just the pending chunk.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        file.append(Data("second".utf8))
        file.flush()

        let loaded = try Data(contentsOf: fileURL)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "firstsecond")
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

    /// Regression: a gapless flood used to grow the in-RAM `pending` buffer without bound
    /// (the debounce perpetually re-armed and never fired). The size cap must force flushes
    /// mid-flood so bytes reach disk and RAM stays bounded — verified here via correctness:
    /// the newest output survives and the file is compacted, despite no flush during the loop.
    func testSustainedFloodStaysBoundedAndPersistsCorrectTail() throws {
        let fileURL = url()
        let cap = 64 * 1024
        let file = ScrollbackFile(url: fileURL, retentionCap: cap)
        // ~1 MiB in 4 KiB chunks, NO flush between — far past both the retention cap and the
        // 256 KiB pending cap, so the size cap (not the timer) must drive persistence.
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024)
        for _ in 0..<256 { file.append(chunk) }
        let marker = Data("END-OF-FLOOD".utf8)
        file.append(marker)
        file.flush() // serializes behind every queued append; drains whatever the cap left

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
        // Compacted to ~the retention cap, NOT the ~1 MiB produced.
        XCTAssertLessThanOrEqual(size, cap + 1024)
        // The most-recent bytes survive the flood + compaction.
        let tail = ScrollbackFile.loadTail(url: fileURL, maxBytes: cap)
        XCTAssertTrue(tail.suffix(marker.count).elementsEqual(marker),
                      "most-recent output must survive the flood")
    }

    /// `retentionCap == 0` requests unlimited scrollback: the on-disk log keeps everything,
    /// bounded only by the large safety ceiling. Output far past the normal 64 KiB floor / 128 KiB
    /// high-water must NOT be compacted away (contrast `testCompactionTrimsToRetentionCap`).
    func testUnlimitedRetentionKeepsEverythingBelowSafetyCeiling() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 0) // 0 = unlimited
        // ~1 MiB — far past the normal floor/high-water, but trivially under the 512 MiB safety
        // ceiling, so nothing is trimmed.
        let total = 1 * 1024 * 1024
        file.append(Data(repeating: UInt8(ascii: "x"), count: total))
        let marker = Data("END".utf8)
        file.append(marker)
        file.flush()

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
        XCTAssertEqual(size, total + marker.count,
                       "unlimited scrollback must keep the whole log below the safety ceiling")
        // And the full tail is replayable.
        let tail = ScrollbackFile.loadTail(url: fileURL, maxBytes: ScrollbackFile.unlimitedSafetyCap)
        XCTAssertEqual(tail.count, total + marker.count)
    }

    /// Compaction must keep the *byte-exact* suffix of everything ever appended — the streamed
    /// tail copy may not drop, duplicate, or reorder a single byte at chunk boundaries.
    func testCompactionKeepsByteExactSuffix() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        let file = ScrollbackFile(url: fileURL, retentionCap: cap)
        // A non-repeating stream so any offset error shows up: 200 KiB of a 251-byte cycle
        // (coprime with the chunk sizes in play), appended in odd-sized chunks.
        var stream = Data(capacity: 200 * 1024)
        for i in 0 ..< 200 * 1024 { stream.append(UInt8(i % 251)) }
        var offset = 0
        var chunkLen = 1
        while offset < stream.count {
            let end = min(offset + chunkLen, stream.count)
            file.append(stream.subdata(in: offset ..< end))
            offset = end
            chunkLen = chunkLen * 3 % 9973 + 7
        }
        file.flush()

        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertLessThanOrEqual(onDisk.count, cap, "compaction ran")
        XCTAssertTrue(onDisk.elementsEqual(stream.suffix(onDisk.count)),
                      "on-disk log must be the exact suffix of the appended stream")
    }

    /// The compacted log must stay owner-only — the temp file is created 0600 before any
    /// content lands in it, so secrets in scrollback are never world-readable, even briefly.
    func testCompactionPreservesOwnerOnlyPermissions() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        let file = ScrollbackFile(url: fileURL, retentionCap: cap)
        file.append(Data(repeating: UInt8(ascii: "x"), count: cap * 3))
        file.flush()

        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms & 0o777, 0o600)
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
