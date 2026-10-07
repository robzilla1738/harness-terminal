import AppKit
import HarnessCore
import XCTest
@testable import HarnessTerminalKit

@MainActor
final class ScriptKeyConsumerTests: XCTestCase {
    func testExclusiveModeSwallowsKeysAndRunsTheAction() {
        let manifest = ScriptManifest(
            generation: 1,
            hash: "h",
            actions: [ScriptAction(name: "nudge", title: "Nudge left", source: "init.lua")],
            bindingCount: 2,
            bindings: [
                ScriptBindingRecord(spec: "ctrl+r", enter: "resize", layer: ScriptLayer.configFile.rawValue, source: "init.lua"),
                ScriptBindingRecord(spec: "resize/left", action: "nudge", layer: ScriptLayer.configFile.rawValue, source: "init.lua"),
                ScriptBindingRecord(spec: "cmd+shift+=", action: "nudge", layer: ScriptLayer.configFile.rawValue, source: "init.lua"),
            ],
            modes: [ScriptModeRecord(name: "resize", exclusive: true, once: false)]
        )
        let stamp = Date(timeIntervalSince1970: 10)
        var ran: [ScriptRequest] = []
        let consumer = ScriptKeyConsumer(
            manifest: { manifest },
            modified: { stamp },
            perform: { ran.append($0) }
        )
        XCTAssertFalse(consumer.consume(key(characters: "x", flags: [], keyCode: 0x07)))
        XCTAssertFalse(consumer.consume(key(characters: "\u{01}", flags: .control, keyCode: 0x00)))
        XCTAssertTrue(consumer.consume(key(characters: "r", flags: .control, keyCode: 0x0F)))
        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(consumer.consume(key(characters: "x", flags: [], keyCode: 0x07)))
        XCTAssertTrue(ran.isEmpty, "an exclusive mode does not deliver an unbound key")
        let left = key(characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), flags: [], keyCode: 0x7B)
        XCTAssertTrue(consumer.consume(left))
        XCTAssertEqual(ran, [.action("nudge")])
        XCTAssertTrue(consumer.consume(key(characters: "\u{1B}", flags: [], keyCode: 0x35)))
        XCTAssertFalse(consumer.consume(key(characters: "x", flags: [], keyCode: 0x07)))
    }

    func testShiftedEqualUsesTheUnshiftedKeyAndThePhysicalCode() {
        let event = key(characters: "+", flags: [.command, .shift], keyCode: 0x18)
        XCTAssertEqual(ScriptChordEvent.named(event)?.key, "=")
        XCTAssertEqual(ScriptChordEvent.named(event)?.modifiers, [.command, .shift])
        XCTAssertEqual(ScriptChordEvent.physical(event)?.key, "Equal")
        XCTAssertEqual(ScriptChordEvent.physical(event)?.physical, true)
        let manifest = ScriptManifest(
            generation: 1,
            hash: "h",
            actions: [],
            bindingCount: 1,
            bindings: [ScriptBindingRecord(spec: "cmd+shift+=", action: "plus", layer: 1, source: "init.lua")],
            modes: []
        )
        var ran: [ScriptRequest] = []
        let consumer = ScriptKeyConsumer(manifest: { manifest }, modified: { Date(timeIntervalSince1970: 1) }, perform: { ran.append($0) })
        XCTAssertTrue(consumer.consume(event))
        XCTAssertEqual(ran, [.action("plus")])
    }

    func testAFunctionBindingIsConsumedAndRunByTheCLI() {
        let manifest = ScriptManifest(
            generation: 1, hash: "h", actions: [], bindingCount: 1,
            bindings: [ScriptBindingRecord(spec: "cmd+k", function: true, layer: 1, source: "init.lua")]
        )
        var ran: [ScriptRequest] = []
        let consumer = ScriptKeyConsumer(manifest: { manifest }, modified: { Date(timeIntervalSince1970: 1) }, perform: { ran.append($0) })
        XCTAssertTrue(consumer.consume(key(characters: "k", flags: .command, keyCode: 0x28)))
        XCTAssertEqual(ran, [.binding("cmd+k")])
    }

    func testControlAUsesTheHardwareKey() {
        let event = key(characters: "\u{01}", flags: .control, keyCode: 0x00)
        XCTAssertEqual(ScriptChordEvent.named(event)?.key, "a")
        XCTAssertEqual(ScriptChordEvent.named(event)?.modifiers, [.control])
        XCTAssertEqual(ScriptChordEvent.physical(event)?.key, "KeyA")
    }

    private func key(characters: String, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
