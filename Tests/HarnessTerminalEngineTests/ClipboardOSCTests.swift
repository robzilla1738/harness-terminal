import CHarnessBase64
import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// OSC 52 (`set-clipboard`): a program copies to the system clipboard by writing
/// `ESC ] 52 ; c ; <base64> BEL`. The engine decodes and reports the text; the
/// consumer (GUI / compositor) gates on the `set-clipboard` option.
final class ClipboardOSCTests: XCTestCase {
    private func encoded(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    func testOSC52SetsClipboard() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        term.feed("\u{1b}]52;c;\(encoded("hello world"))\u{07}")
        XCTAssertEqual(captured, "hello world")
    }

    func testOSC52WithStringTerminator() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        // ST (ESC \) terminator instead of BEL.
        term.feed("\u{1b}]52;c;\(encoded("via ST"))\u{1b}\\")
        XCTAssertEqual(captured, "via ST")
    }

    func testOSC52QueryIsIgnored() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var fired = false
        term.onSetClipboard = { _ in fired = true }
        term.feed("\u{1b}]52;c;?\u{07}")
        XCTAssertFalse(fired, "a clipboard query must not fire a set")
    }

    func testOSC52IgnoresInvalidBase64() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var fired = false
        term.onSetClipboard = { _ in fired = true }
        term.feed("\u{1b}]52;c;@@not-base64@@\u{07}")
        XCTAssertFalse(fired)
    }

    /// The payload crosses a feed boundary, so the parser must copy rather than borrow
    /// a pointer that dies when the first feed returns.
    func testOSC52SplitAcrossFeedsStillSetsClipboard() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        let full = Array("\u{1b}]52;c;\(encoded("hello world"))\u{07}".utf8)
        let mid = full.count / 2
        term.feed(Array(full[..<mid]))
        XCTAssertNil(captured)
        term.feed(Array(full[mid...]))
        XCTAssertEqual(captured, "hello world")
    }

    /// ST's ESC is the last byte of the first feed. The payload has to survive until `\`.
    func testOSC52StringTerminatorSplitAcrossFeeds() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        term.feed(Array("\u{1b}]52;c;\(encoded("via ST"))\u{1b}".utf8))
        XCTAssertNil(captured)
        term.feed(Array("\\".utf8))
        XCTAssertEqual(captured, "via ST")
    }

    /// Lengths that hit the arm64 chunk loop, the scalar tail, and both padding sizes.
    /// 600 KiB is the clipboard benchmark body: under the 1 MiB OSC cap, no `=` padding.
    func testOSC52LengthsRoundTrip() {
        let lengths = [1, 2, 3, 4, 15, 16, 17, 31, 32, 47, 48, 49, 600 * 1024]
        for length in lengths {
            var raw = [UInt8]()
            raw.reserveCapacity(length)
            for i in 0 ..< length { raw.append(UInt8(0x20 + (i % 0x5F))) }
            let term = HarnessGridTerminal(cols: 80, rows: 24)!
            var captured: String?
            term.onSetClipboard = { captured = $0 }
            var osc = Array("\u{1b}]52;c;".utf8)
            osc.append(contentsOf: Data(raw).base64EncodedString().utf8)
            osc.append(0x07)
            term.feed(osc)
            XCTAssertEqual(captured, String(bytes: raw, encoding: .utf8), "length \(length)")
        }
    }

    /// The feed test still passes if this decoder fails open onto Foundation.
    /// Lock the decoder itself on the benchmark body: 600 KiB of printable ASCII,
    /// base64 length 819200, no padding, high bit clear.
    func testStrictDecoderMatchesFoundationOnClipboardBody() {
        let length = 600 * 1024
        var raw = [UInt8]()
        raw.reserveCapacity(length)
        for i in 0 ..< length { raw.append(UInt8(0x20 + (i % 0x5F))) }
        let encoded = Data(Data(raw).base64EncodedString().utf8)
        XCTAssertEqual(Data(base64Encoded: encoded), Data(raw))
        var decoded = Data(count: length + 16)
        var nonASCII: Int32 = 1
        let count: Int = encoded.withUnsafeBytes { src in
            decoded.withUnsafeMutableBytes { dst in
                harness_base64_decode(
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    encoded.count,
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    &nonASCII
                )
            }
        }
        XCTAssertEqual(count, length)
        XCTAssertEqual(nonASCII, 0)
        XCTAssertEqual(Data(decoded.prefix(count)), Data(raw))
    }

    func testOSC52RejectsInvalidUTF8() {
        let payloads = [Data([0xFF, 0xFF]), Data(repeating: 0xFF, count: 32)]
        for raw in payloads {
            let term = HarnessGridTerminal(cols: 80, rows: 24)!
            var captured: String?
            term.onSetClipboard = { captured = $0 }
            term.feed("\u{1b}]52;c;\(raw.base64EncodedString())\u{07}")
            XCTAssertNil(captured, "invalid UTF-8 of \(raw.count) bytes must not set the clipboard")
        }
    }

    func testAReadAsksTheHostAndAReplayedReadDoesNot() {
        let term = TerminalEmulator(cols: 20, rows: 2)
        var asked: [String] = []
        term.onClipboardRead = { asked.append($0) }
        term.feed("\u{1b}]52;c;?\u{07}")
        XCTAssertEqual(asked, ["c"])
        term.isReplaying = true
        term.feed("\u{1b}]52;c;?\u{07}")
        XCTAssertEqual(asked, ["c"], "history doesn't ask again")
        XCTAssertEqual(String(decoding: TerminalEmulator.clipboardReply(selection: "c", text: "hi"), as: UTF8.self), "\u{1b}]52;c;aGk=\u{1b}\\")
    }
}
