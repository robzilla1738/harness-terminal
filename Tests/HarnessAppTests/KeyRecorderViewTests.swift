import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class KeyRecorderViewTests: XCTestCase {
    func testFirstResponderKeyDownRecordsControlA() {
        let recorder = KeyRecorderView(initial: "ctrl-b")
        var recorded: String?
        recorder.onChange = { recorded = $0 }

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: keyEvent(raw: "\u{01}", modifiers: .control, keyCode: 0))

        XCTAssertEqual(recorded, "ctrl-a")
        XCTAssertEqual(recorder.value, "ctrl-a")
    }

    func testClickThenKeyDownRecordsControlB() {
        let recorder = KeyRecorderView(initial: "")
        var recorded: String?
        recorder.onChange = { recorded = $0 }

        recorder.mouseDown(with: mouseEvent())
        recorder.keyDown(with: keyEvent(raw: "\u{02}", modifiers: .control, keyCode: 11))

        XCTAssertEqual(recorded, "ctrl-b")
        XCTAssertEqual(recorder.value, "ctrl-b")
    }

    func testEscapeCancelsWithoutChangingValue() {
        let recorder = KeyRecorderView(initial: "ctrl-a")
        var recorded: String?
        recorder.onChange = { recorded = $0 }

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: keyEvent(raw: "\u{1B}", modifiers: [], keyCode: 53))

        XCTAssertNil(recorded)
        XCTAssertEqual(recorder.value, "ctrl-a")
    }

    func testUnrecordableKeyDoesNotChangeValue() {
        let recorder = KeyRecorderView(initial: "ctrl-a")
        var recorded: String?
        recorder.onChange = { recorded = $0 }

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: keyEvent(raw: "", modifiers: .control, keyCode: 0))

        XCTAssertNil(recorded)
        XCTAssertEqual(recorder.value, "ctrl-a")
    }

    private func keyEvent(raw: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: raw,
            charactersIgnoringModifiers: raw,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func mouseEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
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
