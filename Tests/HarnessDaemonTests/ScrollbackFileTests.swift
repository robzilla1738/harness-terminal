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
    private var protection: HistoryProtection {
        #if os(macOS)
        return try! HistoryProtection(keyMaterial: Data(repeating: 23, count: 32))
        #else
        return .system()
        #endif
    }

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

    func testUnavailableKeyProtectsLegacyOriginalWithoutPlaintextFallback() throws {
        let fileURL = url(), original = Data("legacy private output".utf8)
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        file.append(Data("new bounded memory output".utf8)); file.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertTrue(file.loadTail(maxBytes: 1024).contains(Data("new bounded memory output".utf8)))
        XCTAssertNotNil(file.unavailableReason)
    }

    func testClosedHistorySurvivesUnlockAndOptOutCannotResurrectIt() throws {
        let owner = ClosedHistoryStore(maximumBytes: 64 * 1024)
        let id = UUID().uuidString, fileURL = url()
        var live: ScrollbackFile? = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        live!.append(Data("closed private output".utf8))
        owner.retain(live, surfaceID: id); live = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let closed = try XCTUnwrap(owner.recoveryFiles().first)
        try closed.recover(protection: protection)
        XCTAssertEqual(closed.loadTail(maxBytes: 1024), Data("closed private output".utf8))
        owner.purge(id)
        closed.append(Data("must not return".utf8)); closed.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(owner.take(id))

        let second = ScrollbackFile(url: url(), retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        second.append(Data("reopened history".utf8)); owner.retain(second, surfaceID: id)
        let reopened = try XCTUnwrap(owner.take(id))
        XCTAssertEqual(reopened.loadTail(maxBytes: 1024), Data("reopened history".utf8))
        reopened.append(Data(" continued".utf8))
        try reopened.recover(protection: protection)
        XCTAssertEqual(reopened.loadTail(maxBytes: 1024), Data("reopened history continued".utf8))
    }

    func testInterruptedAppendRecoversOnlyAuthenticatedPrefix() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("complete".utf8)); file.flush()
        let prefix = try Data(contentsOf: fileURL)
        file.append(Data("interrupted".utf8)); file.flush()
        let full = try Data(contentsOf: fileURL)
        try Data(full.dropLast(7)).write(to: fileURL)
        let recovered = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertNil(recovered.unavailableReason)
        XCTAssertEqual(try Data(contentsOf: fileURL), prefix)
        recovered.append(Data(" appended".utf8)); recovered.flush()
        XCTAssertEqual(recovered.loadTail(maxBytes: 1024), Data("complete appended".utf8))

        var corrupt = try Data(contentsOf: fileURL)
        corrupt[70] ^= 1
        try corrupt.write(to: fileURL)
        let refused = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertNotNil(refused.unavailableReason)
        refused.append(Data("must not overwrite evidence".utf8)); refused.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testUnavailableKeyPreservesPlaintextUntilVerifiedConversionAndOptOutRemovesIt() throws {
        let fileURL = url()
        let original = Data("legacy private history".utf8)
        try original.write(to: fileURL)
        let unavailable = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        unavailable.append(Data("memory only".utf8)); unavailable.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let migrated = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertNil(migrated.unavailableReason)
        XCTAssertEqual(migrated.loadTail(maxBytes: 1024), original)
        #if os(macOS)
        XCTAssertNil(try Data(contentsOf: fileURL).range(of: original))
        #endif
        migrated.setSuspended(true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testKeyRecoveryImportsBoundedMemoryWithResizeOrderingAndRefusesCorruption() throws {
        let fileURL = url()
        try Data("old ".utf8).write(to: fileURL)
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        file.recordSize(cols: 80, rows: 24); file.append(Data("private captured output".utf8))
        file.recordSize(cols: 100, rows: 30); file.append(Data(" after resize".utf8)); file.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("old ".utf8))
        XCTAssertThrowsError(try file.recover(protection: .unavailable("Still locked")))
        try file.recover(protection: protection)
        XCTAssertNil(file.unavailableReason)
        XCTAssertEqual(file.loadTail(maxBytes: 1024), Data("old private captured output after resize".utf8))
        XCTAssertEqual(file.replaySizesForTail(maxBytes: 1024), [ReplaySize(sequence: 5, cols: 80, rows: 24), ReplaySize(sequence: 28, cols: 100, rows: 30)])
        file.append(Data(" continued".utf8)); file.flush()
        let restored = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertEqual(restored.loadTail(maxBytes: 1024), Data("old private captured output after resize continued".utf8))
        #if os(macOS)
        XCTAssertNil(try Data(contentsOf: fileURL).range(of: Data("private captured output".utf8)))
        #endif
        var corrupt = try Data(contentsOf: fileURL); corrupt[70] ^= 1; try corrupt.write(to: fileURL)
        let locked = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: .unavailable("Locked"))
        locked.append(Data("new memory".utf8)); locked.flush()
        XCTAssertThrowsError(try locked.recover(protection: protection))
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testResizeHistorySurvivesRestartTailTrimmingAndCompaction() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.recordSize(cols: 10, rows: 4)
        file.append(Data(repeating: 65, count: 40 * 1024))
        file.recordSize(cols: 20, rows: 6)
        file.append(Data(repeating: 66, count: 40 * 1024))
        file.flush()
        let restored = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertEqual(restored.replaySizesForTail(maxBytes: 64 * 1024), [
            ReplaySize(sequence: 1, cols: 10, rows: 4),
            ReplaySize(sequence: 24 * 1024 + 1, cols: 20, rows: 6),
        ])
        XCTAssertEqual(restored.replaySizesForTail(maxBytes: 1024), [ReplaySize(sequence: 1, cols: 20, rows: 6)])
        restored.recordSize(cols: 30, rows: 8)
        restored.flush() // a resize with no output is persisted too
        let again = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertEqual(again.replaySizesForTail(maxBytes: 1024).last,
                       ReplaySize(sequence: 1025, cols: 30, rows: 8))
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        again.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("sizes").path))
    }

    func testReplacementLogRejectsOldResizeOffsetsAndOptOutRemovesThem() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.recordSize(cols: 10, rows: 4)
        file.append(Data("old".utf8))
        file.flush()
        try Data("replacement".utf8).write(to: fileURL, options: .atomic)
        let replacement = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertTrue(replacement.replaySizesForTail(maxBytes: 1024).isEmpty)
        replacement.append(Data("new".utf8), size: ReplaySize(sequence: 0, cols: 20, rows: 6))
        replacement.flush()
        replacement.setSuspended(true)
        replacement.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("sizes").path))
        replacement.setSuspended(false)
        replacement.append(Data("fresh".utf8), size: ReplaySize(sequence: 0, cols: 30, rows: 8))
        replacement.flush()
        let restored = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        XCTAssertEqual(restored.replaySizesForTail(maxBytes: 1024), [ReplaySize(sequence: 1, cols: 30, rows: 8)])
    }

    func testLiveRetentionChangeKeepsNewBudgetAndCompactsWhenReduced() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.setRetentionCap(512 * 1024)
        file.append(Data(repeating: 65, count: 256 * 1024))
        file.flush()
        XCTAssertEqual(ScrollbackFile.loadTail(url: fileURL, maxBytes: 512 * 1024, protection: protection).count, 256 * 1024)
        file.setRetentionCap(64 * 1024)
        file.flush()
        XCTAssertEqual(ScrollbackFile.loadTail(url: fileURL, maxBytes: 512 * 1024, protection: protection).count, 64 * 1024)
        XCTAssertLessThanOrEqual(ScrollbackBudget.rawBytes(forLines: Int.max), ScrollbackBudget.unlimitedSafetyCapBytes)
    }

    /// The flush timer is armed once per batch (not re-armed per chunk) and still fires on its
    /// own — including after a `reset()` cancelled the previously armed timer.
    func testDebouncedFlushFiresWithoutExplicitFlushAfterReset() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("stale".utf8))
        file.reset() // cancels the armed timer
        file.append(Data("one ".utf8))
        file.append(Data("two".utf8))
        let deadline = Date().addingTimeInterval(3)
        while ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096, protection: protection).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(String(decoding: ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096, protection: protection), as: UTF8.self), "one two")
    }

    func testAppendThenLoadTailRoundTrips() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("hello ".utf8))
        file.append(Data("world".utf8))
        file.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 64 * 1024, protection: protection)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "hello world")
    }

    func testAppendPreservesExistingHistoryWhenOwnerPermissionsAreRestored() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("first".utf8))
        file.flush()

        // Reassert owner-only permissions without replacing the existing history.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        file.append(Data("second".utf8))
        file.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 64 * 1024, protection: protection)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "firstsecond")
    }

    func testLoadTailReturnsSuffixWhenLargerThanMax() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("ABCDEFGHIJ".utf8))
        file.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 4, protection: protection)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "GHIJ")
    }

    func testOpenCompactsExistingLogToRetentionCap() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        try HarnessPaths.ensureDirectories()
        try Data(repeating: UInt8(ascii: "x"), count: cap * 2)
            .write(to: fileURL, options: .atomic)

        _ = ScrollbackFile(url: fileURL, retentionCap: cap, protection: protection)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, cap + 1024)
    }

    func testCompactionTrimsToRetentionCap() throws {
        let fileURL = url()
        let cap = 64 * 1024 // the floor; highWater is 2× this
        let file = ScrollbackFile(url: fileURL, retentionCap: cap, protection: protection)
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
        let file = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        file.append(Data("transient".utf8))
        file.flush()
        XCTAssertFalse(ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096, protection: protection).isEmpty)

        file.reset()
        // reset() is async on the file's queue; a subsequent synchronous flush serializes behind it.
        file.flush()
        XCTAssertTrue(ScrollbackFile.loadTail(url: fileURL, maxBytes: 4096, protection: protection).isEmpty)
    }

    /// Regression: a gapless flood used to grow the in-RAM `pending` buffer without bound
    /// (the debounce perpetually re-armed and never fired). The size cap must force flushes
    /// mid-flood so bytes reach disk and RAM stays bounded — verified here via correctness:
    /// the newest output survives and the file is compacted, despite no flush during the loop.
    func testSustainedFloodStaysBoundedAndPersistsCorrectTail() throws {
        let fileURL = url()
        let cap = 64 * 1024
        let file = ScrollbackFile(url: fileURL, retentionCap: cap, protection: protection)
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
        let tail = ScrollbackFile.loadTail(url: fileURL, maxBytes: cap, protection: protection)
        XCTAssertTrue(tail.suffix(marker.count).elementsEqual(marker),
                      "most-recent output must survive the flood")
    }

    /// `retentionCap == 0` requests unlimited scrollback: the on-disk log keeps everything,
    /// bounded only by the large safety ceiling. Output far past the normal 64 KiB floor / 128 KiB
    /// high-water must NOT be compacted away (contrast `testCompactionTrimsToRetentionCap`).
    func testUnlimitedRetentionKeepsEverythingBelowSafetyCeiling() throws {
        let fileURL = url()
        let file = ScrollbackFile(url: fileURL, retentionCap: 0, protection: protection) // 0 = unlimited
        // ~1 MiB — far past the normal floor/high-water, but trivially under the 512 MiB safety
        // ceiling, so nothing is trimmed.
        let total = 1 * 1024 * 1024
        file.append(Data(repeating: UInt8(ascii: "x"), count: total))
        let marker = Data("END".utf8)
        file.append(marker)
        file.flush()

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
        XCTAssertGreaterThan(size, total + marker.count,
                       "unlimited scrollback must keep the whole log below the safety ceiling")
        // And the full tail is replayable.
        let tail = ScrollbackFile.loadTail(url: fileURL, maxBytes: ScrollbackFile.unlimitedSafetyCap, protection: protection)
        XCTAssertEqual(tail.count, total + marker.count)
    }

    /// Compaction must keep the *byte-exact* suffix of everything ever appended — the streamed
    /// tail copy may not drop, duplicate, or reorder a single byte at chunk boundaries.
    func testCompactionKeepsByteExactSuffix() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        let file = ScrollbackFile(url: fileURL, retentionCap: cap, protection: protection)
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
        XCTAssertLessThanOrEqual(onDisk.count, cap + 1024, "compaction ran")
        let restored = ScrollbackFile.loadTail(url: fileURL, maxBytes: cap, protection: protection)
        XCTAssertEqual(restored.count, cap)
        XCTAssertTrue(restored.elementsEqual(stream.suffix(restored.count)),
                      "on-disk log must be the exact suffix of the appended stream")
    }

    /// The compacted log must stay owner-only — the temp file is created 0600 before any
    /// content lands in it, so secrets in scrollback are never world-readable, even briefly.
    func testCompactionPreservesOwnerOnlyPermissions() throws {
        let fileURL = url()
        let cap = ScrollbackFile.minimumRetentionCap
        let file = ScrollbackFile(url: fileURL, retentionCap: cap, protection: protection)
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
        let first = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        first.append(Data("before-".utf8))
        first.flush()

        let second = ScrollbackFile(url: fileURL, retentionCap: 64 * 1024, protection: protection)
        second.append(Data("after".utf8))
        second.flush()

        let loaded = ScrollbackFile.loadTail(url: fileURL, maxBytes: 64 * 1024, protection: protection)
        XCTAssertEqual(String(decoding: loaded, as: UTF8.self), "before-after")
    }
}
