import Foundation
import XCTest
@testable import HarnessDaemonCore

final class RealPtyReplayTests: XCTestCase {
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
