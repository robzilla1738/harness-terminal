import Foundation
import HarnessCore
import XCTest
@testable import HarnessDaemonCore
@testable import HarnessTerminalEngine

/// Snapshot (1.17). The parsers are fed by capture, attach and the screen warmer, not by the
/// PTY read loop. A parked pane keeps the child and drops the grids.
final class SnapshotTests: XCTestCase {
    func testDisablingPersistencePreservesParkedScreenInMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = try catPty(scrollbackURL: directory.appendingPathComponent("pane.scroll"))
        defer { pty.close() }
        pty.setParkMaterialForTesting(directory: directory, key: Data(repeating: 7, count: 32))
        pty.injectSyntheticOutput(Data("KEEP_VISIBLE_WHEN_PRIVATE".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("KEEP_VISIBLE_WHEN_PRIVATE") })
        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        let before = try XCTUnwrap(pty.screenFrame())
        XCTAssertTrue(screenText(before).contains("KEEP_VISIBLE_WHEN_PRIVATE"))
        pty.setScrollbackPersistence(enabled: false)
        XCTAssertEqual(pty.screenFrame(), before, "opting out of disk persistence must not blank an idle pane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(pty.id).park").path))
        pty.clearScrollback()
        XCTAssertFalse(screenText(pty.screenFrame()).contains("KEEP_VISIBLE_WHEN_PRIVATE"))
    }

    func testClearingHistoryInvalidatesWarmCaptureAndScreenCaches() throws {
        let pty = try catPty()
        defer { pty.close() }
        let bytes = Data("CLEARED_SECRET\r\n".utf8)
        pty.injectSyntheticOutput(bytes)
        XCTAssertTrue(waitUntil { pty.ringEnd == UInt64(bytes.count + 1) })
        XCTAssertTrue(pty.captureGrid(start: nil, end: nil, joinWrapped: false).contains("CLEARED_SECRET"))
        XCTAssertTrue(screenText(pty.screenFrame()).contains("CLEARED_SECRET"))

        pty.clearScrollback()
        XCTAssertFalse(pty.captureGrid(start: nil, end: nil, joinWrapped: false).contains("CLEARED_SECRET"))
        XCTAssertFalse(screenText(pty.screenFrame()).contains("CLEARED_SECRET"))
        pty.injectSyntheticOutput(Data("FRESH".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("FRESH") })
        XCTAssertFalse(pty.captureGrid(start: nil, end: nil, joinWrapped: false).contains("CLEARED_SECRET"))
        XCTAssertFalse(screenText(pty.screenFrame()).contains("CLEARED_SECRET"))
    }

    func testCatchUpFeedsOnlyTheGapAndResyncsWhenTheRingDropsBytes() {
        let parser = AuthoritativeParser()
        let first = [SnapshotByteSpan(sequence: 1, data: Data("AAA".utf8))]
        parser.catchUp(ring: first, cols: 10, rows: 2)
        let fed = parser.bytesFed
        parser.catchUp(ring: first, cols: 10, rows: 2)
        XCTAssertEqual(parser.bytesFed, fed, "a caught-up snapshot does not reparse the ring")
        XCTAssertEqual(parser.readLoopFeeds, 0)

        let extended = first + [SnapshotByteSpan(sequence: 4, data: Data("B".utf8))]
        parser.catchUp(ring: extended, cols: 10, rows: 2)
        XCTAssertEqual(parser.bytesFed, fed + 1)
        XCTAssertTrue(screenText(parser.frame()).contains("AAAB"))
        XCTAssertEqual(parser.frame()?.sequence, 5)

        let evicted = [SnapshotByteSpan(sequence: 100, data: Data("Z".utf8))]
        parser.catchUp(ring: evicted, cols: 10, rows: 2)
        let text = screenText(parser.frame())
        XCTAssertTrue(text.contains("Z"))
        XCTAssertFalse(text.contains("AAA"))
    }

    func testResizeReflowsExistingScreenInsteadOfReinterpretingCursorMoves() {
        let parser = AuthoritativeParser()
        let bytes = Data("abcdefghijklmnop\r\u{1b}[2Kprompt> ".utf8)
        let ring = [SnapshotByteSpan(sequence: 1, data: bytes)]
        let truth = TerminalEmulator(cols: 10, rows: 4)
        truth.feed(bytes)
        parser.catchUp(ring: ring, cols: 10, rows: 4)
        truth.resize(cols: 20, rows: 6)
        parser.catchUp(ring: ring, cols: 20, rows: 6)
        XCTAssertEqual(parser.terminal?.captureLines(joinWrapped: false), truth.captureLines(joinWrapped: false))
        XCTAssertEqual(parser.bytesFed, bytes.count, "a resize must not parse the retained bytes again")
    }

    func testColdReplayUsesRecordedSizesThroughCursorRedrawAndAlternateScreen() throws {
        let pty = try RealPty(id: UUID().uuidString, cwd: NSTemporaryDirectory(), shell: "/bin/cat",
                              rows: 4, cols: 10)
        defer { pty.close() }
        let truth = TerminalEmulator(cols: 10, rows: 4)
        let first = Data("abcdefghijklmnop\r\u{1b}[2Kprompt> ".utf8)
        pty.injectSyntheticOutput(first)
        truth.feed(first)
        pty.resize(rows: 6, cols: 20)
        truth.resize(cols: 20, rows: 6)
        let second = Data("\r\u{1b}[2Kprompt> echo 界\r\n界\r\n\u{1b}[?1049h\u{1b}[2J\u{1b}[Heditor".utf8)
        pty.injectSyntheticOutput(second)
        truth.feed(second)
        pty.resize(rows: 5, cols: 12)
        truth.resize(cols: 12, rows: 5)
        let third = Data("\u{1b}[5;1Hstatus\u{1b}[?1049l\r\nprompt> ".utf8)
        pty.injectSyntheticOutput(third)
        truth.feed(third)
        XCTAssertTrue(waitUntil { pty.ringEnd == UInt64(first.count + second.count + third.count + 1) })
        let history = pty.attachHistory(fromSequence: nil, chunkLimit: 7)
        let sizes = try XCTUnwrap(history.replaySizes)
        XCTAssertEqual(sizes.map(\.cols), [10, 20, 12])
        let restored = TerminalEmulator(cols: 10, rows: 4)
        for chunk in history.chunks {
            ReplaySize.replay(chunk.data, sequence: chunk.sequence, sizes: sizes,
                              resize: { restored.resize(cols: $0, rows: $1) }, feed: restored.feed)
        }
        XCTAssertEqual(restored.captureLines(joinWrapped: false), truth.captureLines(joinWrapped: false))
        XCTAssertEqual(history.screen?.vt, PaneCapture.screen(truth))
        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        XCTAssertEqual(pty.attachHistory(fromSequence: nil).replaySizes, sizes)
        pty.resize(rows: 7, cols: 25)
        truth.resize(cols: 25, rows: 7)
        XCTAssertTrue(waitUntil { pty.attachHistory(fromSequence: nil).screen?.vt == PaneCapture.screen(truth) },
                      "a resize without output must unpark and rebuild at the recorded boundaries")
    }

    func testRestartRestoresResizeBoundariesBeforeStartingTheNewShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pane.scroll")
        let pty = try RealPty(id: "old", cwd: directory.path, shell: "/bin/cat", rows: 4, cols: 10, scrollbackURL: url, historyProtection: testProtection)
        let first = Data("abcdefghijklmnop\r\u{1b}[2Kprompt> ".utf8)
        pty.injectSyntheticOutput(first)
        pty.resize(rows: 6, cols: 20)
        let second = Data("echo hello\r\nhello\r\nprompt> ".utf8)
        pty.injectSyntheticOutput(second)
        XCTAssertTrue(waitUntil { pty.ringEnd == UInt64(first.count + second.count + 1) })
        pty.flushScrollback()
        pty.close()
        let restored = try RealPty(id: "new", cwd: directory.path, shell: "/bin/cat", rows: 8, cols: 30, scrollbackURL: url, historyProtection: testProtection)
        defer { restored.close() }
        let truth = TerminalEmulator(cols: 10, rows: 4)
        truth.feed(first)
        truth.resize(cols: 20, rows: 6)
        truth.feed(second)
        truth.feed(Data(RealPty.restoreSeparator.utf8))
        truth.resize(cols: 30, rows: 8)
        XCTAssertEqual(restored.attachHistory(fromSequence: nil).screen?.vt, PaneCapture.screen(truth))
    }

    func testCapturedFishRedrawTraceMatchesIncrementalTerminalAfterReattach() throws {
        struct Trace: Decodable {
            struct Event: Decodable { var cols: UInt16; var rows: UInt16; var data: Data }
            var events: [Event]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fish-resize-replay.json")
        let trace = try JSONDecoder().decode(Trace.self, from: Data(contentsOf: url))
        let truth = TerminalEmulator(cols: 40, rows: 8)
        var sizes: [ReplaySize] = []
        var bytes = Data()
        var reproducedLegacyDefect = false
        for event in trace.events {
            let sequence = UInt64(bytes.count + 1)
            if sizes.last?.cols != event.cols || sizes.last?.rows != event.rows {
                if sizes.last?.sequence == sequence { sizes.removeLast() }
                sizes.append(ReplaySize(sequence: sequence, cols: event.cols, rows: event.rows))
            }
            truth.resize(cols: Int(event.cols), rows: Int(event.rows))
            truth.feed(event.data)
            bytes.append(event.data)
            let legacy = TerminalEmulator(cols: Int(event.cols), rows: Int(event.rows))
            legacy.feed(bytes)
            reproducedLegacyDefect = reproducedLegacyDefect
                || legacy.captureLines(joinWrapped: false) != truth.captureLines(joinWrapped: false)
            let restored = AuthoritativeParser()
            restored.catchUp(ring: [SnapshotByteSpan(sequence: 1, data: bytes)],
                             cols: Int(event.cols), rows: Int(event.rows), sizes: sizes)
            XCTAssertEqual(restored.frame()?.vt, PaneCapture.screen(truth),
                           "reattachment must match at every captured resize boundary")
        }
        let parser = AuthoritativeParser()
        let ring = [SnapshotByteSpan(sequence: 1, data: bytes)]
        parser.catchUp(ring: ring, cols: 40, rows: 8, sizes: sizes)
        XCTAssertEqual(parser.terminal?.captureLines(joinWrapped: false), truth.captureLines(joinWrapped: false))
        XCTAssertEqual(parser.frame()?.vt, PaneCapture.screen(truth))
        XCTAssertTrue(truth.captureLines(joinWrapped: false).contains { $0.contains("FISH_REPLAY_OK") })
        XCTAssertTrue(reproducedLegacyDefect, "the captured trace must exercise the old replay defect")
        parser.releaseGrid()
        parser.catchUp(ring: ring, cols: 40, rows: 8, sizes: sizes)
        XCTAssertEqual(parser.frame()?.vt, PaneCapture.screen(truth), "cold and warm restoration agree")
    }

    /// Kitty animation commands (chunked frames included) parse in the authoritative grid like
    /// any other output, and the screen around them is captured intact.
    func testKittyAnimationCommandsLeaveTheCapturedScreenIntact() {
        let parser = AuthoritativeParser()
        let pixel = Data([255, 0, 0, 255]).base64EncodedString()
        let bytes = "before\r\n\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\"
            + "\u{1b}_Ga=f,i=1,f=32,s=1,v=1,z=40,m=1;\(pixel.prefix(4))\u{1b}\\\u{1b}_Gm=0;\(pixel.dropFirst(4))\u{1b}\\"
            + "\u{1b}_Ga=c,i=1,r=2,c=1\u{1b}\\\u{1b}_Ga=a,i=1,s=3,v=1\u{1b}\\after"
        parser.catchUp(ring: [SnapshotByteSpan(sequence: 1, data: Data(bytes.utf8))], cols: 20, rows: 4)
        let text = screenText(parser.frame())
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertEqual(parser.terminal?.readGrid().images.count, 1, "the animated image is placed once")
    }

    func testScreenFramePaintsTheSameScreenAndRoundTripsThroughThePark() throws {
        let source = TerminalEmulator(cols: 20, rows: 3)
        source.feed(Data("plain \u{1b}[1;31mred\u{1b}[0m after\r\n\u{1b}[?1h\u{1b}[?2004hnext".utf8))
        let vt = PaneCapture.screen(source)
        let painted = TerminalEmulator(cols: 20, rows: 3)
        painted.feed(vt)
        XCTAssertEqual(painted.captureLines(joinWrapped: false), source.captureLines(joinWrapped: false))
        XCTAssertEqual(painted.readGrid().cursor.row, source.readGrid().cursor.row)
        XCTAssertEqual(painted.readGrid().cursor.col, source.readGrid().cursor.col)
        XCTAssertTrue(painted.modes.cursorKeysApplication)
        XCTAssertTrue(painted.modes.bracketedPaste)
        let after = try XCTUnwrap(painted.readGrid().cell(row: 0, col: 11))
        XCTAssertFalse(after.bold, "a reset follows the styled run")
        XCTAssertTrue(try XCTUnwrap(painted.readGrid().cell(row: 0, col: 6)).bold)

        let frame = ScreenFrame(vt: vt, sequence: 42)
        XCTAssertEqual(ScreenFrame.decode(frame.encoded()), frame)
    }

    func testAttachHistoryResumesInsideTheRingAndResyncsOutsideIt() throws {
        let pty = try catPty()
        pty.start()
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("first\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("first") })
        let full = pty.attachHistory(fromSequence: nil)
        XCTAssertTrue(full.resync, "no resume point: start over")
        XCTAssertTrue(full.chunks.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains("first"))

        pty.injectSyntheticOutput(Data("second\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("second") })
        let resumed = pty.attachHistory(fromSequence: full.endSequence)
        XCTAssertFalse(resumed.resync)
        let text = resumed.chunks.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        XCTAssertTrue(text.contains("second"))
        XCTAssertFalse(text.contains("first"), "a resume sends only what was missed")
        XCTAssertEqual(resumed.chunks.first?.sequence, full.endSequence)

        XCTAssertTrue(pty.attachHistory(fromSequence: resumed.endSequence + 1_000).resync, "a point past the end resyncs")
        let small = pty.attachHistory(fromSequence: nil, chunkLimit: 3)
        XCTAssertTrue(small.chunks.allSatisfy { $0.data.count <= 3 })
        let joined = { (history: AttachHistory) in history.chunks.map(\.data).reduce(Data(), +) }
        XCTAssertEqual(joined(small), joined(full) + joined(resumed), "chunking keeps every byte in order")
    }

    func testAResyncCarriesTheScreenAtTheHistoryEndAndKeepsItReady() throws {
        let pty = try catPty()
        pty.start()
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("\u{1b}]2;t\u{07}on screen\r\n\u{1b}[?2004h".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("on screen") })

        let full = pty.attachHistory(fromSequence: nil)
        let screen = try XCTUnwrap(full.screen)
        XCTAssertEqual(screen.sequence, full.endSequence, "the screen is the history's last state")
        XCTAssertTrue(screenText(screen).contains("on screen"))
        XCTAssertTrue(String(decoding: screen.vt, as: UTF8.self).contains("\u{1b}[?2004h"), "with the program's modes")
        XCTAssertTrue(pty.screenGrid.resident, "the screen stays for the next attach")
        XCTAssertFalse(pty.gridIsResident, "and no grid with history is built for it")
        XCTAssertNil(pty.attachHistory(fromSequence: full.endSequence).screen, "a resume continues what the client shows")

        let parsed = pty.screenGrid.bytesFed
        let screenOnly = pty.attachHistory(history: false, fromSequence: nil)
        XCTAssertTrue(screenOnly.chunks.isEmpty)
        XCTAssertEqual(screenOnly.screen, screen)
        XCTAssertEqual(screenOnly.endSequence, screen.sequence, "live output takes up where the screen ends")
        XCTAssertEqual(pty.screenGrid.bytesFed, parsed, "the next attach parses nothing")
    }

    /// The screen grid keeps one line of history, and paints the same screen as the full grid:
    /// through scrolling, a scroll region, and the alternate screen and back.
    func testTheScreenGridPaintsWhatTheFullGridDoesWithoutItsHistory() {
        let full = AuthoritativeParser()
        let screen = AuthoritativeParser(historyLines: 1)
        var ring: [SnapshotByteSpan] = []
        var sequence: UInt64 = 1
        let parts = [
            (0 ..< 500).map { "\u{1b}[3\($0 % 7)mline \($0)\u{1b}[0m\r\n" }.joined(),
            "\u{1b}[?1049h\u{1b}[H\u{1b}[2Jeditor\u{1b}[5;20r\u{1b}[20;1H" + String(repeating: "x\n", count: 40),
            "\u{1b}[r\u{1b}[?1049lback\r\n\u{1b}[?2004h",
        ]
        for part in parts {
            ring.append(SnapshotByteSpan(sequence: sequence, data: Data(part.utf8)))
            sequence += UInt64(part.utf8.count)
            full.catchUp(ring: ring, cols: 40, rows: 10)
            screen.catchUp(ring: ring, cols: 40, rows: 10)
            XCTAssertEqual(screen.frame(), full.frame())
        }
        XCTAssertTrue(screenText(screen.frame()).contains("line 499"))
        XCTAssertEqual(screen.terminal?.captureLines(joinWrapped: false).count, 11, "one line of history")
    }

    /// Nobody attached: output is parsed into the screen in the background, so an attach finds it
    /// ready. While a client watches, the screen waits; it catches up once the client leaves.
    func testAnUnwatchedPaneKeepsItsScreenCurrentAndAWatchedOneCatchesUpWhenItsClientLeaves() throws {
        let pty = try catPty()
        pty.start()
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("unwatched\r\n".utf8))
        XCTAssertTrue(waitUntil { pty.screenGrid.fedThrough == pty.ringEnd && pty.ringEnd > 1 }, "caught up with no attach")
        let parsed = pty.screenGrid.bytesFed
        XCTAssertTrue(screenText(pty.attachHistory(fromSequence: nil).screen).contains("unwatched"))
        XCTAssertEqual(pty.screenGrid.bytesFed, parsed, "the attach parses nothing")

        let seen = OutputAccumulator()
        let token = pty.subscribe { data, _ in _ = seen.appendAndContains(String(decoding: data, as: UTF8.self), marker: "") }
        pty.injectSyntheticOutput(Data("watched\r\n".utf8))
        XCTAssertTrue(waitUntil { seen.contains("watched") })
        XCTAssertLessThan(pty.screenGrid.fedThrough, pty.ringEnd, "a watched pane is not parsed twice")
        pty.cancelSubscription(token: token)
        XCTAssertTrue(waitUntil { pty.screenGrid.fedThrough == pty.ringEnd }, "the last client leaving catches it up")
        XCTAssertTrue(screenText(pty.screenFrame()).contains("watched"))
    }

    func testParkedRingCompressesTerminalOutputAndRoundTrips() {
        let output = Data((0 ..< 2_000).map { "\u{1b}[32mline \($0) of a long build log\u{1b}[0m\r\n" }.joined().utf8)
        let ring = ParkedRing(sequence: 7, bytes: output)
        XCTAssertEqual(ring.bytes, output)
        XCTAssertEqual(ring.rawCount, output.count)
        if RingCodec.compress(output) != nil { // LZ4 is Apple's; elsewhere the ring stays as it is
            XCTAssertLessThan(ring.stored.count, output.count / 3, "terminal output compresses well")
        }
        let tiny = ParkedRing(sequence: 1, bytes: Data("x".utf8))
        XCTAssertFalse(tiny.compressed, "bytes that don't shrink are kept as they are")
        XCTAssertEqual(tiny.bytes, Data("x".utf8))
    }

    func testUnparkingKeepsHistoryAndClearingAParkedPaneForgetsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-park-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = try catPty(scrollbackURL: directory.appendingPathComponent("scrollback.log"))
        pty.start()
        defer { pty.close() }
        pty.setParkMaterialForTesting(directory: directory, key: Data(repeating: 3, count: 32))
        let line = String(repeating: "x", count: 200) + "\n"
        for _ in 0 ..< 400 { pty.injectSyntheticOutput(Data(line.utf8)) }
        XCTAssertTrue(waitUntil { pty.scrollbackByteCount >= 60 * 1024 })
        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        pty.injectSyntheticOutput(Data("woke\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).hasSuffix("woke\n") })
        XCTAssertGreaterThan(pty.replay(fromSequence: nil).count, 32 * 1024, "one new byte past the cap trims old bytes, not the whole history")

        let before = pty.attachHistory(fromSequence: nil).endSequence
        pty.parkIfIdle(now: Date().addingTimeInterval(240))
        pty.clearScrollback()
        XCTAssertFalse(pty.replay(fromSequence: nil).contains("xxxx"), "clearing forgets the parked ring too")
        pty.injectSyntheticOutput(Data("fresh\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("fresh") })
        XCTAssertGreaterThanOrEqual(pty.attachHistory(fromSequence: nil).chunks.first?.sequence ?? 0, before, "sequences keep counting up")
    }

    func testLegacyCheckpointMigrationVerifiesNewProtectionBeforeRemovingOldKey() throws {
        let key = Data(repeating: 9, count: 32)
        let plain = ScreenFrame(vt: Data("park-me".utf8), sequence: 42).encoded()
        let sealed = try XCTUnwrap(SnapshotCipher.seal(plain: plain, key: key))
        XCTAssertEqual(SnapshotCipher.open(sealed: sealed, key: key), plain)
        XCTAssertNil(SnapshotCipher.open(sealed: sealed, key: Data(repeating: 1, count: 32)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-snap-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString, url = directory.appendingPathComponent(id + ".park"), keyURL = directory.appendingPathComponent("snapshot.key")
        try sealed.write(to: url); try key.write(to: keyURL)
        XCTAssertNotNil(HistoryMigration.checkpoints(directory: directory, legacyKeyURL: keyURL, protection: .unavailable("Locked")))
        XCTAssertEqual(try Data(contentsOf: url), sealed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        let protection = testProtection
        XCTAssertNil(HistoryMigration.checkpoints(directory: directory, legacyKeyURL: keyURL, protection: protection))
        XCTAssertEqual(try protection.open(Data(contentsOf: url), identity: "checkpoint:" + id, sequence: 42), plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        var corrupt = sealed; corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: url); try key.write(to: keyURL)
        XCTAssertNotNil(HistoryMigration.checkpoints(directory: directory, legacyKeyURL: keyURL, protection: protection))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testReadLoopDoesNotFeedTheParserAndCaptureDoes() throws {
        let pty = try catPty()
        pty.start()
        defer { pty.close() }
        let tee = OutputAccumulator()
        let token = pty.subscribe { data, _ in
            _ = tee.appendAndContains(String(decoding: data, as: UTF8.self), marker: "tee-line")
        }
        defer { pty.cancelSubscription(token: token) }

        let before = pty.authoritativeBytesFed
        pty.injectSyntheticOutput(Data("tee-line\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("tee-line") })
        XCTAssertEqual(pty.authoritativeBytesFed, before)
        XCTAssertFalse(pty.readLoopRunsAuthoritativeParser)
        XCTAssertTrue(tee.contains("tee-line"))

        let captured = pty.captureFormatted(format: "text", trim: true, unwrap: false)
        XCTAssertTrue(captured.contains("tee-line"))
        XCTAssertGreaterThan(pty.authoritativeBytesFed, before)
        XCTAssertFalse(pty.readLoopRunsAuthoritativeParser)
    }

    func testParkDropsTheGridKeepsTheChildAndANewClientSeesTheScreen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-park-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = try catPty(scrollbackURL: directory.appendingPathComponent("scrollback.log"))
        pty.start()
        defer { pty.close() }
        let key = Data(repeating: 4, count: 32)
        pty.setParkMaterialForTesting(directory: directory, key: key)
        pty.injectSyntheticOutput(Data("park-me\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("park-me") })

        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        XCTAssertTrue(pty.childIsAlive)
        XCTAssertFalse(pty.gridIsResident)
        XCTAssertFalse(pty.screenGrid.resident, "parking lets the screen grid go too")
        let url = directory.appendingPathComponent("\(pty.id).park")
        let sealed = try Data(contentsOf: url)
        #if canImport(CryptoKit)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("park-me"), "the file is ciphertext")
        #else
        XCTAssertTrue(String(decoding: sealed, as: UTF8.self).contains("park-me"), "Linux uses the documented plaintext fallback")
        #endif
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let frame = try XCTUnwrap(pty.screenFrame())
        XCTAssertTrue(screenText(frame).contains("park-me"))
        XCTAssertFalse(pty.screenGrid.resident, "serving the parked screen does not bring the grid back")

        XCTAssertNotNil(pty.parkedFootprint, "the ring is held packed while parked")
        XCTAssertTrue(pty.replay(fromSequence: nil).contains("park-me"), "reading a parked ring decompresses a copy")
        XCTAssertNotNil(pty.parkedFootprint, "and leaves it parked")
        pty.injectSyntheticOutput(Data("woke\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("woke") })
        XCTAssertNil(pty.parkedFootprint, "output unparks the ring")
        XCTAssertTrue(pty.replay(fromSequence: nil).contains("park-me\nwoke") || pty.replay(fromSequence: nil).contains("park-me\r\nwoke"),
                      "the old bytes come back in front of the new ones")

        pty.setScrollbackPersistence(enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        pty.parkIfIdle(now: Date().addingTimeInterval(240))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(pty.childIsAlive)
        XCTAssertTrue(screenText(pty.screenFrame()).contains("woke"), "with nothing on disk the parked screen is kept in memory")
        XCTAssertFalse(pty.screenGrid.resident)
    }

    func testPtyDrainComparisonKeepsTheParserOffTheReadThread() throws {
        let measured = PtyDrainComparison.measure(byteCount: 32 * 1024, repeats: 8)
        print("PTY_DRAIN append_ns=\(measured.appendNanos) parse_ns=\(measured.parseNanos) parser_on_read_thread=false")
        XCTAssertGreaterThan(measured.appendNanos, 0)
        XCTAssertGreaterThan(measured.parseNanos, 0)
        let pty = try catPty()
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("x".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("x") })
        XCTAssertFalse(pty.readLoopRunsAuthoritativeParser)
    }

    /// A screen-only capture renders the same from the full grid, from the screen grid, and from
    /// the parked screen's VT painted into a fresh grid, in every format, and it is the last rows
    /// of the full capture (what the thumbnails used to cut out of it).
    func testScreenCapturesMatchAcrossGridsAndThePark() {
        let lines: [String] = (0 ..< 300).map { "\u{1b}[3\($0 % 8);4\(($0 + 3) % 8)mline \($0)\u{1b}[0m plain\r\n" }
        let corpus: [String] = [
            lines.joined(),
            "wide 日本語テキスト and e\u{301}combined 👍🏽 " + String(repeating: "界", count: 30) + "\r\n",
            String(repeating: "soft-wrapped words ", count: 9) + "\r\n" + String(repeating: "x", count: 39) + "界tail\r\n",
            "\u{1b}[1;3;4:3;9;53;58;2;10;20;30mstyles\u{1b}[0m \u{1b}[2;5;7;8mmore\u{1b}[0m\r\n",
            "\u{1b}[44mblue to the end\u{1b}[K\u{1b}[0m\r\n\u{1b}[31;4mred underlined blanks\u{1b}[K   \u{1b}[0m\r\n",
            "\u{1b}[38;5;202;48;2;1;2;3mcolors\u{1b}[0m \u{1b}(0lqqk\u{1b}(B drawn\r\n",
            "a\tb\ttabbed\r\n\u{1b}[2Aover\u{1b}[2B\r\nfamily 👨‍👩‍👧 done\r\n",
            String(repeating: "z", count: 45) + "\u{1b}[2K\r\n",
            "\u{1b}[?1049h\u{1b}[H\u{1b}[2Jeditor \u{1b}[7mstatus\u{1b}[0m\u{1b}[3;8r\u{1b}[8;1H" + String(repeating: "y\n", count: 12),
            "\u{1b}[r\u{1b}[?1049lback on the main screen\r\n",
        ]
        let full = AuthoritativeParser()
        let screen = AuthoritativeParser(historyLines: 1)
        var ring: [SnapshotByteSpan] = []
        var sequence: UInt64 = 1
        for part in corpus {
            ring.append(SnapshotByteSpan(sequence: sequence, data: Data(part.utf8)))
            sequence += UInt64(part.utf8.count)
            full.catchUp(ring: ring, cols: 40, rows: 10)
            screen.catchUp(ring: ring, cols: 40, rows: 10)
            guard let fullTerm = full.terminal, let screenTerm = screen.terminal, let frame = full.frame() else {
                return XCTFail("no grid")
            }
            let painted = TerminalEmulator(cols: 40, rows: 10)
            painted.feed(frame.vt)
            for format in ["text", "vt", "html"] {
                for trim in [false, true] {
                    for unwrap in [false, true] {
                        let expected = PaneCapture.render(term: fullTerm, format: format, trim: trim, unwrap: unwrap, history: false)
                        let label = "\(format) trim \(trim) unwrap \(unwrap) after \(part.prefix(12))"
                        XCTAssertEqual(PaneCapture.render(term: screenTerm, format: format, trim: trim, unwrap: unwrap, history: false), expected, label)
                        XCTAssertEqual(PaneCapture.render(term: painted, format: format, trim: trim, unwrap: unwrap, history: false), expected, "parked: \(label)")
                    }
                }
            }
            let lines = PaneCapture.render(term: fullTerm, format: "vt", trim: false, unwrap: false).components(separatedBy: "\n")
            XCTAssertEqual(
                PaneCapture.render(term: fullTerm, format: "vt", trim: false, unwrap: false, history: false),
                lines.suffix(10).joined(separator: "\n")
            )
        }
    }

    /// A screen capture reads the screen grid and builds no grid with history; it is the last
    /// rows of a full capture. A full capture's grid goes once it sits unused for the hold, and
    /// captures that keep coming keep it.
    func testAScreenCaptureBuildsNoHistoryGridAndAFullCapturesGridGoesAfterItsHold() throws {
        let pty = try catPty()
        pty.start()
        defer { pty.close() }
        pty.historyGridHold = 1
        pty.injectSyntheticOutput(Data((0 ..< 60).map { "row \($0)\r\n" }.joined().utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("row 59") })

        let screen = pty.captureFormatted(format: "vt", trim: false, unwrap: false, screen: true)
        XCTAssertFalse(pty.gridIsResident, "no history parsed for the screen")
        XCTAssertTrue(screen.contains("row 59"))
        XCTAssertFalse(screen.contains("row 0"))
        let full = pty.captureFormatted(format: "vt", trim: false, unwrap: false)
        XCTAssertTrue(full.contains("row 0"))
        XCTAssertEqual(full.components(separatedBy: "\n").suffix(24).joined(separator: "\n"), screen)
        XCTAssertTrue(pty.gridIsResident)

        let polling = Date()
        while Date().timeIntervalSince(polling) < 1.5 {
            _ = pty.captureGrid(start: -2, end: nil, joinWrapped: false)
            XCTAssertTrue(pty.gridIsResident, "a capture that keeps coming keeps the grid")
            usleep(100_000)
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !pty.gridIsResident }, "an unused grid goes after its hold")
    }

    /// A parked pane answers a screen capture from the screen kept at the park: it stays parked,
    /// with no grid in the heap, persisted or not.
    func testAParkedPaneAnswersAScreenCaptureWithoutAGrid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-park-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for persisted in [true, false] {
            let pty = try catPty()
            pty.start()
            defer { pty.close() }
            if persisted { pty.setParkMaterialForTesting(directory: directory, key: Data(repeating: 5, count: 32)) }
            pty.injectSyntheticOutput(Data("\u{1b}[1mparked\u{1b}[0m screen\r\n".utf8))
            XCTAssertTrue(waitUntil { pty.screenGrid.fedThrough == pty.ringEnd && pty.ringEnd > 1 })
            let live = ["text", "vt", "html"].map { pty.captureFormatted(format: $0, trim: true, unwrap: true, screen: true) }

            pty.parkIfIdle(now: Date().addingTimeInterval(120))
            let parked = ["text", "vt", "html"].map { pty.captureFormatted(format: $0, trim: true, unwrap: true, screen: true) }
            XCTAssertEqual(parked, live, "persisted \(persisted)")
            XCTAssertNotNil(pty.parkedFootprint, "still parked")
            XCTAssertFalse(pty.screenGrid.resident)
            XCTAssertFalse(pty.gridIsResident)
        }
    }

    /// What a client painting `frame` would show.
    private func screenText(_ frame: ScreenFrame?) -> String {
        guard let frame else { return "" }
        let term = TerminalEmulator(cols: 80, rows: 24)
        term.feed(frame.vt)
        return term.captureLines(joinWrapped: false).joined(separator: "\n")
    }

    private var testProtection: HistoryProtection {
        #if os(macOS)
        return try! HistoryProtection(keyMaterial: Data(repeating: 29, count: 32))
        #else
        return .system()
        #endif
    }

    private func catPty(scrollbackURL: URL? = nil) throws -> RealPty {
        try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/cat",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024,
            scrollbackURL: scrollbackURL, historyProtection: testProtection
        )
    }
}

final class PastedFilesTests: XCTestCase {
    func testWritesAnOwnerOnlyFileWithASafeName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case let .success(path) = PastedFiles.write(Data("hi".utf8), named: "../../etc/shot.png", in: directory) else {
            return XCTFail("expected a path")
        }
        XCTAssertTrue(path.hasPrefix(directory.path))
        XCTAssertTrue(path.hasSuffix("-shot.png"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value, 0o600)
        let target = directory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .failure = PastedFiles.write(Data("private".utf8), named: "secret.png", in: link) else { return XCTFail("Must not follow an upload directory link") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        guard case .failure = PastedFiles.write(Data(count: PastedFiles.maxBytes + 1), named: "big", in: directory) else {
            return XCTFail("too big")
        }
    }
}

final class PtyInputWriterTests: XCTestCase {
    /// A pipe stands in for a PTY nobody reads: the writer fills it, keeps the rest without
    /// blocking, and finishes in order once the reader drains it.
    func testAFullPTYHoldsInputWithoutBlockingAndDeliversItInOrder() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        let writeEnd = fds[1]
        let writer = PtyInputWriter(queue: DispatchQueue(label: "test.writer"))
        let master = { (dup(writeEnd), UInt64(1)) }
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        let started = Date()
        for _ in 0 ..< 4 { writer.write(chunk, master: master()) }
        writer.write(Data("END".utf8), master: master())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "write never blocks the caller")

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(10)
        while !received.suffix(3).elementsEqual(Data("END".utf8)), Date() < deadline {
            let n = read(fds[0], &buffer, buffer.count)
            if n > 0 { received.append(contentsOf: buffer[0 ..< n]) }
        }
        XCTAssertEqual(received.count, 4 * chunk.count + 3)
        XCTAssertEqual(received.suffix(3), Data("END".utf8))
    }
}
