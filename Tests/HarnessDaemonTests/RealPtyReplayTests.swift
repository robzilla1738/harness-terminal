import Foundation
import XCTest
@testable import HarnessDaemonCore

final class RealPtyReplayTests: XCTestCase {
    func testParkedHistoryComesBackOnSequencedReplayAndTheNextRead() throws {
        let pty = try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/cat",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024
        )
        pty.start()
        defer { pty.close() }

        pty.injectSyntheticOutput(Data("history-line\n".utf8))
        XCTAssertTrue(waitUntil { pty.replay(fromSequence: nil).contains("history-line") })

        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        let parked = pty.replayWithEndSequence(fromSequence: nil)
        XCTAssertTrue(parked.text.contains("history-line"), "sequenced replay includes parked history")
        XCTAssertTrue(pty.childIsAlive)
        XCTAssertFalse(pty.gridIsResident)

        pty.injectSyntheticOutput(Data("next-line\n".utf8))
        XCTAssertTrue(waitUntil {
            let replay = pty.replayWithEndSequence(fromSequence: nil)
            return replay.text.contains("history-line") && replay.text.contains("next-line")
        })
        XCTAssertTrue(pty.childIsAlive)
    }

    func testForegroundPidIsTheRunningProgramNotTheShell() throws {
        let pty = try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024
        )
        pty.start()
        defer { pty.close() }
        pty.write("sleep 30\n")
        XCTAssertTrue(waitUntil {
            guard let probed = pty.probeForegroundProcess() else { return false }
            return probed.executable == "sleep" && probed.pid != pty.currentChildPID
        })
    }

    func testReplayFromSequenceSlicesInsideChunk() {
        let segments = [
            RealPty.ScrollbackReplaySegment(sequence: 1, data: Data("abcdef".utf8)),
            RealPty.ScrollbackReplaySegment(sequence: 7, data: Data("gh".utf8)),
        ]

        let replay = RealPty.replayData(from: segments, fromSequence: 4)

        XCTAssertEqual(String(decoding: replay, as: UTF8.self), "defgh")
    }

    func testReplayFromSequenceAtNextChunkBoundarySkipsPriorChunk() {
        let segments = [
            RealPty.ScrollbackReplaySegment(sequence: 1, data: Data("abcdef".utf8)),
            RealPty.ScrollbackReplaySegment(sequence: 7, data: Data("gh".utf8)),
        ]

        let replay = RealPty.replayData(from: segments, fromSequence: 7)

        XCTAssertEqual(String(decoding: replay, as: UTF8.self), "gh")
    }
}

final class ProcessArgumentsTests: XCTestCase {
    func testParsesProcArgs2Layout() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/nvim".utf8) + [0, 0, 0]
        for argument in ["nvim", "a b.zig", "+12"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("HOME=/x".utf8) + [0]
        XCTAssertEqual(RealPty.parseProcArgs2(bytes), ["nvim", "a b.zig", "+12"])
    }

    func testReadsThisProcessArguments() {
        let arguments = RealPty.processArguments(for: getpid())
        XCTAssertFalse(arguments.isEmpty)
        XCTAssertEqual(arguments.count, CommandLine.arguments.count)
    }
}
