import XCTest
@testable import HarnessTerminalEngine

/// Unit tests for the ring buffer that backs scrollback: logical index 0 is always the oldest,
/// dropping the front advances a head index (no shift), and iteration runs oldest → newest.
final class HistoryRingBufferTests: XCTestCase {
    func testAppendAndCount() {
        var ring = HistoryRingBuffer<Int>()
        XCTAssertTrue(ring.isEmpty)
        for i in 0 ..< 5 { ring.append(i) }
        XCTAssertEqual(ring.count, 5)
        XCTAssertFalse(ring.isEmpty)
    }

    func testRandomAccessOldestIsZero() {
        var ring = HistoryRingBuffer<Int>()
        for i in 10 ..< 15 { ring.append(i) } // 10,11,12,13,14
        XCTAssertEqual(ring[0], 10, "logical 0 is the oldest")
        XCTAssertEqual(ring[4], 14, "last index is the newest")
    }

    func testIterationOldestToNewest() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 6 { ring.append(i) }
        XCTAssertEqual(Array(ring), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(ring.enumerated().map { $0.offset }, Array(0 ..< 6))
        XCTAssertEqual(ring.enumerated().map { $0.element }, [0, 1, 2, 3, 4, 5])
    }

    func testRemoveFirstDropsOldestInOrder() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 6 { ring.append(i) } // 0..5
        ring.removeFirst(2)                  // drop 0,1
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring[0], 2, "new oldest")
        XCTAssertEqual(Array(ring), [2, 3, 4, 5])
    }

    func testRemoveFirstDefaultDropsOne() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 3 { ring.append(i) }
        ring.removeFirst()
        XCTAssertEqual(Array(ring), [1, 2])
    }

    func testRemoveFirstClampsToCount() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 3 { ring.append(i) }
        ring.removeFirst(99)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }

    func testAppendAfterDropReusesAndKeepsOrder() {
        // Drive head past the start of the backing store, then keep appending: order must hold.
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 4 { ring.append(i) }   // 0,1,2,3
        ring.removeFirst(3)                    // -> 3
        for i in 4 ..< 8 { ring.append(i) }    // 3,4,5,6,7
        XCTAssertEqual(Array(ring), [3, 4, 5, 6, 7])
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring[ring.count - 1], 7)
    }

    func testGrowthPreservesOrderWhenHeadWrapped() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 8 { ring.append(i) }
        ring.removeFirst(6)                    // 6,7 ; head advanced near the end
        for i in 8 ..< 40 { ring.append(i) }   // forces several growths while head != 0
        XCTAssertEqual(Array(ring), Array(6 ..< 40))
    }

    func testSubscriptSetterMutatesInPlace() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 4 { ring.append(i) }
        ring[2] = 99
        XCTAssertEqual(Array(ring), [0, 1, 99, 3])
    }

    func testRemoveAll() {
        var ring = HistoryRingBuffer<Int>()
        for i in 0 ..< 5 { ring.append(i) }
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        ring.append(42)
        XCTAssertEqual(Array(ring), [42])
    }

    func testInitFromSequence() {
        let ring = HistoryRingBuffer([7, 8, 9])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(Array(ring), [7, 8, 9])
        XCTAssertEqual(ring[0], 7)
    }
}
