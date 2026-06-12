import Foundation
import XCTest
@testable import HarnessTerminalKit
import HarnessCore

/// The trigger scan's cost on the output path, A/B: the same flood fed through the surface
/// with no rules (the production default — one nil check per chunk) vs the full 32-rule cap.
/// Receipts, not gates (bench discipline: compare 5-run medians across branches).
@MainActor
final class TriggerScanBenchmarks: XCTestCase {
    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_BENCHMARKS"] == "1",
            "Set HARNESS_BENCHMARKS=1 to run performance benchmarks."
        )
    }

    private func drainFlood(rules: [TriggerRule]) -> UInt64 {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.applyTriggerRules(rules)
        let line = "build output line with some text that mostly does not match anything 0123\r\n"
        let chunk = Data(String(repeating: line, count: 200).utf8)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< 50 { view.receive(chunk) } // 10k lines total
        view.testingWaitForEmulatorIdle()
        return DispatchTime.now().uptimeNanoseconds &- start
    }

    func testTriggerScanOverheadUnderFlood() throws {
        try skipUnlessEnabled()
        let maxRules = (0 ..< 32).map { i in
            TriggerRule(pattern: i % 2 == 0 ? "ERROR\(i)" : "^warn-\(i):.*$",
                        match: i % 2 == 0 ? .literal : .regex,
                        action: .highlight)
        }
        let typical = (0 ..< 4).map { TriggerRule(pattern: "ERROR\($0)") }
        _ = drainFlood(rules: []) // warm caches/atlas paths
        let off = drainFlood(rules: [])
        let few = drainFlood(rules: typical)
        let on = drainFlood(rules: maxRules)
        print(#"{"benchmark":"trigger_scan_flood_10k_lines","off_nanos":\#(off),"on_4_literals_nanos":\#(few),"on_32_rules_nanos":\#(on),"overhead_4_pct":\#(Int((Double(few) / Double(off) - 1) * 100)),"overhead_32_pct":\#(Int((Double(on) / Double(off) - 1) * 100))}"#)
        // Sanity ceiling only — a >3× blowup means the budget regressed, not weather.
        XCTAssertLessThan(Double(on), Double(off) * 3, "trigger scan overhead implausibly high")
    }
}
