import XCTest
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessDaemonCore

final class CommandOutputSpanTests: XCTestCase {
    func testOSCAnchorsMatchSplitCommandBoundariesAndEvictedOutputIsExplicit() throws {
        let pty = try RealPty(id: UUID().uuidString, cwd: NSTemporaryDirectory(), shell: "/bin/cat", scrollbackBytes: 1024)
        defer { pty.close() }
        var scanner = PtyStreamScanner()
        let parts = ["prompt\u{1b}]133;", "C\u{7}line 🙂\n\u{1b}]133;D;", "7\u{7}next prompt"]
        var sequence: UInt64 = 1, span: ShellCommandSpan?
        for part in parts {
            let data = Data(part.utf8)
            pty.injectSyntheticOutput(data)
            for item in scanner.scanAnchored(data, sequence: sequence) {
                if case let .osc(133, body, length) = item.event {
                    if body == "C" { span = ShellCommandSpan(surfaceID: pty.id, startSequence: item.endSequence); span?.streamIdentity = pty.streamIdentity }
                    if body == "D;7" { span?.endSequence = item.endSequence - UInt64(length); span?.exitCode = 7 }
                }
            }
            sequence += UInt64(data.count)
        }
        let completed = try XCTUnwrap(span)
        let output = try pty.commandOutput(span: completed, maximumBytes: 1024)
        XCTAssertEqual(output.text, "line 🙂\n"); XCTAssertEqual(output.span.exitCode, 7)
        XCTAssertFalse(output.evicted); XCTAssertFalse(output.truncated)
        var foreign = completed; foreign.streamIdentity = UUID().uuidString
        XCTAssertThrowsError(try pty.commandOutput(span: foreign, maximumBytes: 1024))
        pty.injectSyntheticOutput(Data(repeating: 65, count: 2048))
        let deadline = Date().addingTimeInterval(2)
        while pty.ringStart <= completed.startSequence, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let evicted = try pty.commandOutput(span: completed, maximumBytes: 1024)
        XCTAssertTrue(evicted.evicted); XCTAssertEqual(evicted.text, "")
    }
}
