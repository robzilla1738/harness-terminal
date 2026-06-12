import Foundation
import XCTest
@testable import HarnessTerminalKit

/// The echo-latency sampler: keyDown arms one pending sample; the FIRST present after it
/// consumes it (within the attribution window), later presents don't double-count, and a
/// present long after the keystroke (no echo came back) drops the sample instead of
/// mis-attributing a blink tick as typing latency.
final class EchoLatencySignpostTests: XCTestCase {
    func testKeystrokeIsConsumedByTheFirstPresent() {
        let signposter = FrameSignposter(enabled: true)
        signposter.noteKeystroke(at: 1_000)
        XCTAssertTrue(signposter.testingHasPendingKeystroke)

        signposter.recordPresent(nanos: 100, at: 4_000_000) // 4ms later — within the window
        XCTAssertFalse(signposter.testingHasPendingKeystroke)
        XCTAssertEqual(signposter.testingEchoSampleCount, 1)

        signposter.recordPresent(nanos: 100, at: 8_000_000) // no pending — no second sample
        XCTAssertEqual(signposter.testingEchoSampleCount, 1)
    }

    func testStalePresentDropsTheSampleInsteadOfMisattributing() {
        let signposter = FrameSignposter(enabled: true)
        signposter.noteKeystroke(at: 0)
        // 600ms later: outside the 500ms window — the keystroke produced no echo (dead key /
        // swallowed shortcut) and this present is something else (blink, scroll).
        signposter.recordPresent(nanos: 100, at: 600_000_000)
        XCTAssertFalse(signposter.testingHasPendingKeystroke)
        XCTAssertEqual(signposter.testingEchoSampleCount, 0)
    }

    func testRepeatedKeystrokesRearmTheSample() {
        let signposter = FrameSignposter(enabled: true)
        signposter.noteKeystroke(at: 1_000)
        signposter.noteKeystroke(at: 2_000_000) // held key: latest press is the one measured
        signposter.recordPresent(nanos: 100, at: 5_000_000)
        XCTAssertEqual(signposter.testingEchoSampleCount, 1)
    }

    func testDisabledSignposterIsInert() {
        let signposter = FrameSignposter(enabled: false)
        signposter.noteKeystroke(at: 1_000)
        XCTAssertFalse(signposter.testingHasPendingKeystroke)
        signposter.recordPresent(nanos: 100, at: 2_000)
        XCTAssertEqual(signposter.testingEchoSampleCount, 0)
    }
}
