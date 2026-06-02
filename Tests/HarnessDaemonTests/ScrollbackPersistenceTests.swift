import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// End-to-end persistence: a real `forkpty` shell writes output, the surface persists its
/// scrollback to disk, and a *fresh* `RealPty` over the same file replays that history — the
/// "daemon restart isn't a blank session" path. Live (spawns a shell), so gated like the other
/// PTY tests behind `HARNESS_LIVE_DAEMON_TESTS=1`.
final class ScrollbackPersistenceTests: XCTestCase {
    private var scrollbackURL: URL!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        scrollbackURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-scroll-\(UUID().uuidString).scroll")
    }

    override func tearDownWithError() throws {
        if let scrollbackURL { try? FileManager.default.removeItem(at: scrollbackURL) }
    }

    private func makePty(id: String) throws -> RealPty {
        try RealPty(
            id: id,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024,
            scrollbackURL: scrollbackURL
        )
    }

    func testHistoryReplaysAfterRespawnFromDisk() throws {
        let surfaceID = UUID().uuidString
        let marker = "HARNESS_PERSIST_MARKER"

        // First "daemon run": spawn, produce output containing the marker, persist, tear down.
        let first = try makePty(id: surfaceID)
        let saw = expectation(description: "marker observed in live output")
        saw.assertForOverFulfill = false
        let acc = OutputAccumulator()
        _ = first.subscribe { data, _ in
            if acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) { saw.fulfill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { first.write("echo \(marker)\n") }
        wait(for: [saw], timeout: 8)
        first.flushScrollback() // graceful-shutdown flush
        first.close()

        // Second "daemon run": a brand-new surface over the same persisted file must replay history.
        let second = try makePty(id: surfaceID)
        defer { second.close() }
        XCTAssertTrue(
            second.replay(fromSequence: nil).contains(marker),
            "reattach after restart should replay persisted scrollback, not start blank"
        )
    }
}
