import Foundation
import XCTest
@testable import HarnessCore

final class ReplaySizeTests: XCTestCase {
    func testReplayAppliesBoundariesInsideChunksAndAtTheEnd() {
        let sizes = [ReplaySize(sequence: 1, cols: 10, rows: 4),
                     ReplaySize(sequence: 4, cols: 20, rows: 6),
                     ReplaySize(sequence: 7, cols: 30, rows: 8)]
        var events: [String] = []
        ReplaySize.replay(Data("abcdef".utf8), sequence: 1, sizes: sizes,
                          resize: { events.append("\($0)x\($1)") },
                          feed: { events.append(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(events, ["10x4", "abc", "20x6", "def", "30x8"])
        events.removeAll()
        ReplaySize.replay(Data("ef".utf8), sequence: 5, sizes: sizes,
                          resize: { events.append("\($0)x\($1)") },
                          feed: { events.append(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(events, ["20x6", "ef", "30x8"])
    }

    func testMalformedGeometryAndUnorderedBoundariesAreRejected() {
        XCTAssertTrue(ReplaySize.validated([ReplaySize(sequence: 1, cols: 65535, rows: 65535)]).isEmpty)
        XCTAssertTrue(ReplaySize.validated([ReplaySize(sequence: 1, cols: 0, rows: 24)]).isEmpty)
        XCTAssertTrue(ReplaySize.validated([ReplaySize(sequence: 2, cols: 80, rows: 24),
                                           ReplaySize(sequence: 1, cols: 100, rows: 30)]).isEmpty)
        XCTAssertTrue(ReplaySize.validated([ReplaySize(sequence: 1, cols: 80, rows: 24),
                                           ReplaySize(sequence: 1, cols: 100, rows: 30)]).isEmpty)
    }

    func testAttachReplyRemainsCompatibleWithOlderDaemons() throws {
        let legacy = Data(#"{"epoch":"old","resync":true,"endSequence":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AttachReply.self, from: legacy).replaySizes)
        let reply = AttachReply(epoch: "new", resync: true, endSequence: 2,
                                replaySizes: [ReplaySize(sequence: 1, cols: 80, rows: 24)])
        XCTAssertEqual(try JSONDecoder().decode(AttachReply.self, from: JSONEncoder().encode(reply)), reply)
    }
}
