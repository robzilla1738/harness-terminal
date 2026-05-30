import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Kitty keyboard protocol (CSI u) + modifyOtherKeys. The #1 invariant: when no program has
/// opted in, encoding is byte-identical to the legacy path (guarded here and by the full
/// `InputEncoderTests` suite).
final class KittyKeyboardTests: XCTestCase {
    private let enc = InputEncoder()

    private func kittyModes(_ flags: UInt8) -> TerminalModes {
        var m = TerminalModes(); m.kittyKeyboardStack = [flags]; return m
    }

    // MARK: Legacy untouched when disabled

    func testLegacyEncodingUnchangedWhenDisabled() {
        let off = TerminalModes()
        XCTAssertEqual(enc.encode(text: "a", modifiers: .control, modes: off), [0x01])     // ^A
        XCTAssertEqual(enc.encode(text: "a", modes: off), Array("a".utf8))
        XCTAssertEqual(enc.encode(.tab, modes: off), [0x09])
        XCTAssertEqual(enc.encode(.escape, modes: off), [0x1B])
        XCTAssertEqual(enc.encode(.enter, modes: off), [0x0D])
        XCTAssertEqual(enc.encode(.backspace, modes: off), [0x7F])
    }

    // MARK: CSI-u when enabled

    func testCtrlLetterBecomesCSIu() {
        let bytes = enc.encode(text: "a", modifiers: .control, modes: kittyModes(1))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[97;5u") // a=97, ctrl mod=5
    }

    func testShiftedLetterUsesUnshiftedKeyCode() {
        // Ctrl+Shift+A: key code is unshifted 'a' (97), shift carried in the modifier (1+1+4=6).
        let bytes = enc.encode(text: "A", modifiers: [.control, .shift], modes: kittyModes(1))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[97;6u")
    }

    func testPlainTextStillLiteralUnlessAllKeysEscape() {
        XCTAssertEqual(enc.encode(text: "a", modes: kittyModes(1)), Array("a".utf8))
        // report-all-keys-as-escape (bit 8) forces CSI-u even for unmodified keys.
        XCTAssertEqual(String(decoding: enc.encode(text: "a", modes: kittyModes(8)), as: UTF8.self), "\u{1b}[97u")
    }

    func testDisambiguationKeysBecomeCSIu() {
        let m = kittyModes(1)
        XCTAssertEqual(String(decoding: enc.encode(.escape, modes: m), as: UTF8.self), "\u{1b}[27u")
        XCTAssertEqual(String(decoding: enc.encode(.tab, modes: m), as: UTF8.self), "\u{1b}[9u")
        XCTAssertEqual(String(decoding: enc.encode(.enter, modes: m), as: UTF8.self), "\u{1b}[13u")
        XCTAssertEqual(String(decoding: enc.encode(.backspace, modes: m), as: UTF8.self), "\u{1b}[127u")
    }

    func testArrowsKeepLegacyCSIFormUnderKitty() {
        // Functional keys stay in their legacy CSI form (modifiers in params) — matching Kitty.
        XCTAssertEqual(enc.encode(.up, modes: kittyModes(1)), enc.encode(.up, modes: TerminalModes()))
    }

    // MARK: modifyOtherKeys

    func testModifyOtherKeysForm() {
        var m = TerminalModes(); m.modifyOtherKeys = 1
        let bytes = enc.encode(text: "a", modifiers: .control, modes: m)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[27;5;97~")
        // Unmodified keys are untouched by modifyOtherKeys.
        XCTAssertEqual(enc.encode(text: "a", modes: m), Array("a".utf8))
    }

    // MARK: Mode dispatch (push / pop / set / query / XTMODKEYS)

    func testPushPopAndQuery() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var responses = Data()
        term.onResponse = { responses.append($0) }
        term.feed("\u{1b}[>5u")             // push flags 5
        XCTAssertEqual(term.modes.kittyKeyboardFlags, 5)
        term.feed("\u{1b}[?u")              // query → CSI ? 5 u
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}[?5u")
        term.feed("\u{1b}[<u")              // pop
        XCTAssertEqual(term.modes.kittyKeyboardFlags, 0)
    }

    func testSetFlagsWithMode() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}[>1u")             // push 1
        term.feed("\u{1b}[=6;2u")           // set bits 6 (OR) → 1|6 = 7
        XCTAssertEqual(term.modes.kittyKeyboardFlags, 7)
        term.feed("\u{1b}[=4;3u")           // clear bit 4 → 7 & ~4 = 3
        XCTAssertEqual(term.modes.kittyKeyboardFlags, 3)
    }

    func testModifyOtherKeysDispatch() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}[>4;2m")           // XTMODKEYS level 2
        XCTAssertEqual(term.modes.modifyOtherKeys, 2)
        term.feed("\u{1b}[>4;0m")
        XCTAssertEqual(term.modes.modifyOtherKeys, 0)
    }

    func testFullResetClearsKittyState() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}[>7u\u{1b}[>4;2m") // set both
        term.feed("\u{1b}c")                // RIS
        XCTAssertEqual(term.modes.kittyKeyboardFlags, 0)
        XCTAssertEqual(term.modes.modifyOtherKeys, 0)
    }
}
