import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class DockTileRendererTests: XCTestCase {
    func testBadgesFitAndStayCenteredAtEveryDockSize() {
        for size: CGFloat in [32, 64, 128, 256] {
            let bounds = NSRect(x: 3, y: 5, width: size, height: size)
            for count in 1...4 {
                let frames = DockTileRenderer.markFrames(count: count, in: bounds)
                XCTAssertEqual(frames.count, count)
                for frame in frames { XCTAssertTrue(bounds.contains(frame)) }
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertLessThan(left.maxX, right.minX)
                }
                XCTAssertEqual((frames.first!.minX + frames.last!.maxX) / 2, bounds.midX, accuracy: 0.001)
            }
        }
        XCTAssertTrue(DockTileRenderer.markFrames(count: 0, in: .zero).isEmpty)
    }
}
