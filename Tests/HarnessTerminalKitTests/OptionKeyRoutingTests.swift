import AppKit
import HarnessCore
import HarnessTerminalEngine
import XCTest

@testable import HarnessTerminalKit

/// The Option-key routing seam (#155): `effectiveTextModifiers` decides whether a held Option
/// reaches the encoder as Meta (Esc-prefix / Kitty alt bit) or is dropped so the input context
/// composes the layout's character (@, |, é, dead keys). Side-split modes read the
/// device-dependent modifier bits, synthesized here via raw flag values.
@MainActor
final class OptionKeyRoutingTests: XCTestCase {
    // NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK — the per-side Option device bits.
    private let leftBit = NSEvent.ModifierFlags(rawValue: 0x20)
    private let rightBit = NSEvent.ModifierFlags(rawValue: 0x40)
    private var leftOption: NSEvent.ModifierFlags { NSEvent.ModifierFlags.option.union(leftBit) }
    private var rightOption: NSEvent.ModifierFlags { NSEvent.ModifierFlags.option.union(rightBit) }

    private func strip(
        _ mods: KeyModifiers, mode: OptionAsMetaMode, flags: NSEvent.ModifierFlags
    ) -> KeyModifiers {
        HarnessTerminalSurfaceView.effectiveTextModifiers(mods, mode: mode, eventFlags: flags)
    }

    func testComposedStripsOptionFromTextPath() {
        XCTAssertEqual(strip([.option], mode: .composed, flags: .option), [])
        XCTAssertEqual(strip([.option, .shift], mode: .composed, flags: [.option, .shift]), [.shift])
    }

    func testMetaKeepsOption() {
        XCTAssertEqual(strip([.option], mode: .meta, flags: .option), [.option])
        XCTAssertEqual(strip([.option, .shift], mode: .meta, flags: [.option, .shift]), [.option, .shift])
    }

    func testControlOptionComboNeverComposesSoOptionStays() {
        XCTAssertEqual(
            strip([.option, .control], mode: .composed, flags: [.option, .control]),
            [.option, .control]
        )
    }

    func testNonOptionModifiersPassThroughUntouched() {
        XCTAssertEqual(strip([.control], mode: .composed, flags: .control), [.control])
        XCTAssertEqual(strip([.shift], mode: .composed, flags: .shift), [.shift])
        XCTAssertEqual(strip([], mode: .composed, flags: []), [])
    }

    func testLeftMetaOnlySplitsBySide() {
        // Left Option held → Meta; right Option held → composes.
        XCTAssertEqual(strip([.option], mode: .leftMetaOnly, flags: leftOption), [.option])
        XCTAssertEqual(strip([.option], mode: .leftMetaOnly, flags: rightOption), [])
    }

    func testRightMetaOnlySplitsBySide() {
        XCTAssertEqual(strip([.option], mode: .rightMetaOnly, flags: rightOption), [.option])
        XCTAssertEqual(strip([.option], mode: .rightMetaOnly, flags: leftOption), [])
    }

    func testBothSidesHeldMetaWins() {
        let both = leftOption.union(rightBit)
        XCTAssertEqual(strip([.option], mode: .leftMetaOnly, flags: both), [.option])
        XCTAssertEqual(strip([.option], mode: .rightMetaOnly, flags: both), [.option])
    }

    func testSidedModeWithoutDeviceBitsHonorsMetaIntent() {
        // Synthesized events (no NX device bits) under a side-split mode keep Meta — the
        // user opted into *some* Meta; silently composing would break their bindings.
        XCTAssertEqual(strip([.option], mode: .leftMetaOnly, flags: .option), [.option])
        XCTAssertEqual(strip([.option], mode: .rightMetaOnly, flags: .option), [.option])
    }

    func testOptionActsAsMetaTruthTable() {
        XCTAssertTrue(HarnessTerminalSurfaceView.optionActsAsMeta(.meta, eventFlags: .option))
        XCTAssertFalse(HarnessTerminalSurfaceView.optionActsAsMeta(.composed, eventFlags: .option))
        XCTAssertTrue(HarnessTerminalSurfaceView.optionActsAsMeta(.leftMetaOnly, eventFlags: leftOption))
        XCTAssertFalse(HarnessTerminalSurfaceView.optionActsAsMeta(.leftMetaOnly, eventFlags: rightOption))
        XCTAssertFalse(HarnessTerminalSurfaceView.optionActsAsMeta(.rightMetaOnly, eventFlags: leftOption))
        XCTAssertTrue(HarnessTerminalSurfaceView.optionActsAsMeta(.rightMetaOnly, eventFlags: rightOption))
    }

    func testEncoderContractUnchangedByMode() {
        // The fix strips at the view seam; the encoder's Meta contract is untouched. With
        // `.option` present the text path still Esc-prefixes; with it stripped, plain bytes.
        let encoder = InputEncoder()
        XCTAssertEqual(encoder.encode(text: "l", modifiers: [.option]), [0x1B, 0x6C])
        XCTAssertEqual(encoder.encode(text: "l", modifiers: []), [0x6C])
    }
}
