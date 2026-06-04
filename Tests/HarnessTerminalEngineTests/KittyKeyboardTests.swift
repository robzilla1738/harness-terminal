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

    func testArrowsStayLegacyEvenUnderReportAllKeys() {
        // report-all-keys (0b1000) moves *text/control* keys to CSI-u but functional keys (arrows)
        // already are escape codes — they keep their legacy CSI form.
        XCTAssertEqual(enc.encode(.up, modes: kittyModes(0b1000)), enc.encode(.up, modes: TerminalModes()))
    }

    func testKittySupersedesDECCKMForCursorKeys() {
        // DECCKM (application cursor keys) must be ignored while any Kitty flags are active: a
        // Kitty-mode parser reads `ESC O A` as Alt+O A. Ghostty's kitty path never consults DECCKM.
        var m = kittyModes(1)
        m.cursorKeysApplication = true
        XCTAssertEqual(String(decoding: enc.encode(.up, modes: m), as: UTF8.self), "\u{1b}[A")
        XCTAssertEqual(String(decoding: enc.encode(.down, modes: m), as: UTF8.self), "\u{1b}[B")
        XCTAssertEqual(String(decoding: enc.encode(.home, modes: m), as: UTF8.self), "\u{1b}[H")
        XCTAssertEqual(String(decoding: enc.encode(.end, modes: m), as: UTF8.self), "\u{1b}[F")
        // Kitty off: DECCKM honored as before.
        var legacy = TerminalModes()
        legacy.cursorKeysApplication = true
        XCTAssertEqual(String(decoding: enc.encode(.up, modes: legacy), as: UTF8.self), "\u{1b}OA")
    }

    func testFunctionKeysF1toF4UnderKitty() {
        // Under Kitty, F1/F2/F4 take the CSI specials (P/Q/S) instead of SS3, and F3 becomes
        // `CSI 13~` — its CSI `R` form would collide with the cursor position report.
        let m = kittyModes(1)
        XCTAssertEqual(String(decoding: enc.encode(.f1, modes: m), as: UTF8.self), "\u{1b}[P")
        XCTAssertEqual(String(decoding: enc.encode(.f2, modes: m), as: UTF8.self), "\u{1b}[Q")
        XCTAssertEqual(String(decoding: enc.encode(.f3, modes: m), as: UTF8.self), "\u{1b}[13~")
        XCTAssertEqual(String(decoding: enc.encode(.f4, modes: m), as: UTF8.self), "\u{1b}[S")
        XCTAssertEqual(String(decoding: enc.encode(.f3, modifiers: .shift, modes: m), as: UTF8.self), "\u{1b}[13;2~")
        // Kitty off: unchanged SS3 forms (guarded fully by InputEncoderTests).
        XCTAssertEqual(String(decoding: enc.encode(.f3, modes: TerminalModes()), as: UTF8.self), "\u{1b}OR")
    }

    // MARK: Event types (flag 0b10)

    private func str(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testEventTypesOnCSIuSpecialKeys() {
        let m = kittyModes(0b11) // disambiguate + report-event-types
        XCTAssertEqual(str(enc.encode(.tab, event: .press, modes: m)), "\u{1b}[9u")          // press implicit
        XCTAssertEqual(str(enc.encode(.tab, event: .repeat, modes: m)), "\u{1b}[9;1:2u")     // repeat
        XCTAssertEqual(str(enc.encode(.tab, event: .release, modes: m)), "\u{1b}[9;1:3u")    // release
    }

    func testEventTypesOnLegacyFunctionalKeys() {
        let m = kittyModes(0b11)
        // Unmodified release needs the mods field present (defaults to 1) to carry the event.
        XCTAssertEqual(str(enc.encode(.up, event: .release, modes: m)), "\u{1b}[1;1:3A")
        // Press stays the bare legacy form (press is implicit).
        XCTAssertEqual(str(enc.encode(.up, event: .press, modes: m)), "\u{1b}[A")
        // With a modifier + release: CSI 1 ; <mod> : 3 A.
        XCTAssertEqual(str(enc.encode(.up, modifiers: .shift, event: .release, modes: m)), "\u{1b}[1;2:3A")
        // tilde-form key (PageUp) + release.
        XCTAssertEqual(str(enc.encode(.pageUp, event: .release, modes: m)), "\u{1b}[5;1:3~")
    }

    func testEventTypesIgnoredWithoutFlag() {
        // Without the report-event-types flag, release/repeat are not encoded specially.
        let m = kittyModes(1)
        XCTAssertEqual(str(enc.encode(.tab, event: .release, modes: m)), "\u{1b}[9u")
        XCTAssertEqual(enc.encode(.up, event: .release, modes: m), enc.encode(.up, modes: TerminalModes()))
    }

    // MARK: Alternate keys (flag 0b100)

    func testAlternateShiftedKey() {
        // report-all (8) + alternate (4): Shift+a reports unshifted 97 with shifted 65.
        let m = kittyModes(0b1100)
        XCTAssertEqual(str(enc.encode(text: "a", shifted: "A", modifiers: .shift, modes: m)), "\u{1b}[97:65;2u")
    }

    func testAlternateOmittedWhenNoShift() {
        // No shift held → no shifted-key field even with the flag on.
        let m = kittyModes(0b1100)
        XCTAssertEqual(str(enc.encode(text: "a", shifted: "A", modifiers: [], modes: m)), "\u{1b}[97u")
    }

    // MARK: Associated text (flag 0b10000)

    func testAssociatedTextField() {
        // report-all (8) + associated-text (16): plain 'a' → key 97, empty mods field, text 97.
        let m = kittyModes(0b11000)
        XCTAssertEqual(
            str(enc.encode(text: "a", shifted: "a", event: .press, associatedText: "a", modes: m)),
            "\u{1b}[97;;97u"
        )
    }

    // MARK: Kitty CSI-u functional / modifier keys (Private-Use-Area codepoints)

    func testFunctionalAndModifierCodepoints() {
        let m = kittyModes(0b1001) // disambiguate + report-all
        XCTAssertEqual(str(enc.encode(.f13, modes: m)), "\u{1b}[57376u")
        XCTAssertEqual(str(enc.encode(.capsLock, modes: m)), "\u{1b}[57358u")
        XCTAssertEqual(str(enc.encode(.menu, modes: m)), "\u{1b}[57363u")
        XCTAssertEqual(str(enc.encode(.leftShift, modes: m)), "\u{1b}[57441u")
        XCTAssertEqual(str(enc.encode(.rightSuper, modes: m)), "\u{1b}[57450u")
        // Modifier-key release under event reporting carries the event sub-field.
        XCTAssertEqual(str(enc.encode(.leftControl, event: .release, modes: kittyModes(0b1011))), "\u{1b}[57442;1:3u")
    }

    func testF13UsesLegacyTildeWhenKittyOff() {
        // F13–F20 have xterm legacy `CSI <n>~` forms used when Kitty is disabled…
        XCTAssertEqual(str(enc.encode(.f13, modes: TerminalModes())), "\u{1b}[25~")
        XCTAssertEqual(str(enc.encode(.f20, modes: TerminalModes())), "\u{1b}[34~")
        // …but switch to the Kitty CSI-u codepoint once a program opts in.
        XCTAssertEqual(str(enc.encode(.f13, modes: kittyModes(1))), "\u{1b}[57376u")
    }

    func testModifierAndLockKeysEmitNothingWhenDisabled() {
        // Keys with no legacy encoding produce no bytes in legacy mode.
        XCTAssertEqual(enc.encode(.leftShift, modes: TerminalModes()), [])
        XCTAssertEqual(enc.encode(.capsLock, modes: TerminalModes()), [])
        XCTAssertEqual(enc.encode(.menu, modes: TerminalModes()), [])
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
