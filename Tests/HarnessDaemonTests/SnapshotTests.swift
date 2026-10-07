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
        XCTAssertTrue(parser.frame()?.lines.joined().contains("AAAB") == true)

        let evicted = [SnapshotByteSpan(sequence: 100, data: Data("Z".utf8))]
        parser.catchUp(ring: evicted, cols: 10, rows: 2)
        let frame = parser.frame()
        XCTAssertTrue(frame?.lines.joined().contains("Z") == true)
        XCTAssertFalse(frame?.lines.joined().contains("AAA") == true)
        XCTAssertEqual(frame?.lines.count, frame?.rows)
    }

    func testReadyFrameComesBeforeNewestHistoryAndPaintsAFullScreen() {
        let frame = ReadyFrame(
            cols: 4, rows: 2, cursorRow: 0, cursorCol: 1, cursorVisible: true,
            alternateScreen: false, cursorKeysApplication: true, keypadApplication: false,
            lines: ["ab  ", "cd  "], sequence: 8
        )
        let pieces = AttachStream.pieces(
            frame: frame,
            historyNewestFirst: [Data("newest".utf8), Data("oldest".utf8)]
        )
        guard case let .ready(painted) = pieces.first else {
            return XCTFail("the first piece is the screen")
        }
        XCTAssertEqual(painted.lines.count, painted.rows)
        XCTAssertEqual(painted.cursorKeysApplication, true)
        XCTAssertEqual(painted.lines, frame.lines)
        guard pieces.count == 3, case let .history(newest) = pieces[1], case let .history(oldest) = pieces[2] else {
            return XCTFail("history follows the screen, newest first, got \(pieces.count) pieces")
        }
        XCTAssertEqual(String(decoding: newest, as: UTF8.self), "newest")
        XCTAssertEqual(String(decoding: oldest, as: UTF8.self), "oldest")
    }

    func testDesyncedClientMatchesTheAuthoritativeScreenAndLeavesTheOtherClient() {
        let frame = ReadyFrame(
            cols: 5, rows: 1, cursorRow: 0, cursorCol: 5, cursorVisible: true,
            alternateScreen: false, cursorKeysApplication: false, keypadApplication: false,
            lines: ["hello"], sequence: 5
        )
        var client = ["WRONG"]
        let other = ["stable"]
        let returned = DesyncReattach.apply(authoritative: frame, to: &client, other: other)
        XCTAssertEqual(client, ["hello"])
        XCTAssertEqual(returned, other)
        XCTAssertEqual(frame.lines, ["hello"])
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
        XCTAssertNil(ReadyFrame.decode(sealed), "the file is the ciphertext, not the frame")
        let frame = try XCTUnwrap(pty.readyFrameForClient())
        XCTAssertTrue(frame.lines.joined(separator: "\n").contains("park-me"))
        XCTAssertEqual(frame.lines.count, frame.rows)
        XCTAssertFalse(pty.gridIsResident, "serving the parked screen does not bring the grid back")

        let pieces = pty.attachPieces()
        guard case let .ready(painted) = pieces.first else { return XCTFail("ready frame first") }
        XCTAssertEqual(painted.lines.count, painted.rows)
        XCTAssertTrue(painted.lines.joined(separator: "\n").contains("park-me"))
        guard pieces.count > 1, case let .history(newest) = pieces[1] else {
            return XCTFail("history follows the screen")
        }
        XCTAssertTrue(String(decoding: newest, as: UTF8.self).contains("park-me"))
        XCTAssertFalse(pty.gridIsResident)

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
