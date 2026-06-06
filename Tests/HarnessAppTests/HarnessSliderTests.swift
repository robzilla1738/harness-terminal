import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class HarnessSliderTests: XCTestCase {
    /// Stand-in for the settings flow: `action` mirrors the live (no-save) apply on every drag tick;
    /// `onCommit` mirrors the single persist at the end of the gesture.
    private final class Recorder: NSObject {
        var applyCount = 0
        var commitCount = 0
        @objc func apply() { applyCount += 1 }
    }

    func testContinuousDragAppliesEveryTickButCommitsOnce() {
        let slider = HarnessSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.minValue = 0
        slider.maxValue = 100
        slider.layoutSubtreeIfNeeded()

        let recorder = Recorder()
        slider.target = recorder
        slider.action = #selector(Recorder.apply)
        slider.onCommit = { recorder.commitCount += 1 }

        // Press, then drag across the track, then release — the gesture an opacity/blur drag makes.
        slider.mouseDown(with: drag(at: 10, in: slider))
        for x in stride(from: 20, through: 180, by: 20) {
            slider.mouseDragged(with: drag(at: CGFloat(x), in: slider))
        }
        slider.mouseUp(with: drag(at: 190, in: slider))

        // Live apply fired on every tick (down + drags + up), persist fired exactly once.
        XCTAssertGreaterThan(recorder.applyCount, 1, "live apply should fire on each drag tick")
        XCTAssertEqual(recorder.commitCount, 1, "persistence must happen exactly once, on mouse-up")
        // Final value reflects the release position (near the right edge → near maxValue).
        XCTAssertGreaterThan(slider.doubleValue, 80)
    }

    func testCommitFiresEvenOnAPlainClickWithoutDrag() {
        let slider = HarnessSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.layoutSubtreeIfNeeded()

        let recorder = Recorder()
        slider.onCommit = { recorder.commitCount += 1 }

        slider.mouseDown(with: drag(at: 100, in: slider))
        slider.mouseUp(with: drag(at: 100, in: slider))

        XCTAssertEqual(recorder.commitCount, 1, "a click that sets a value must still persist once")
    }

    private func drag(at x: CGFloat, in slider: HarnessSlider) -> NSEvent {
        // The slider reads `locationInWindow` and converts it; with no window the conversion is the
        // identity, so a window-space x maps directly to the slider's local x.
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: x, y: slider.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
