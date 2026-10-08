import Foundation
import XCTest
@testable import HarnessDaemonCore
@testable import HarnessTerminalEngine

/// Snapshot (1.17). The parser is fed by capture and attach, not by the PTY read
/// loop. A parked pane keeps the child and drops the grid.
final class SnapshotTests: XCTestCase {
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

    func testCipherRoundTripAndFileKeyIsOwnerReadWrite() throws {
        let key = Data(repeating: 9, count: 32)
        let plain = Data("park-me".utf8)
        let sealed = try XCTUnwrap(SnapshotCipher.seal(plain: plain, key: key))
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(SnapshotCipher.open(sealed: sealed, key: key), plain)
        XCTAssertNil(SnapshotCipher.open(sealed: sealed, key: Data(repeating: 1, count: 32)))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-snap-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = SnapshotKeyStore.fileLoadOrCreate(directory: directory)
        XCTAssertEqual(created.count, 32)
        XCTAssertEqual(SnapshotKeyStore.fileLoadOrCreate(directory: directory), created)
        let path = directory.appendingPathComponent("snapshot.key").path
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.uint16Value, UInt16(0o600))
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
        let url = directory.appendingPathComponent("\(pty.id).park")
        let sealed = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("park-me"), "the file is ciphertext")
        let frame = try XCTUnwrap(pty.screenFrame())
        XCTAssertTrue(screenText(frame).contains("park-me"))
        XCTAssertFalse(pty.gridIsResident, "serving the parked screen does not bring the grid back")

        pty.setScrollbackPersistence(enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        pty.parkIfIdle(now: Date().addingTimeInterval(240))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(pty.childIsAlive)
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

    /// What a client painting `frame` would show.
    private func screenText(_ frame: ScreenFrame?) -> String {
        guard let frame else { return "" }
        let term = TerminalEmulator(cols: 80, rows: 24)
        term.feed(frame.vt)
        return term.captureLines(joinWrapped: false).joined(separator: "\n")
    }

    private func catPty(scrollbackURL: URL? = nil) throws -> RealPty {
        try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/cat",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024,
            scrollbackURL: scrollbackURL
        )
    }
}
