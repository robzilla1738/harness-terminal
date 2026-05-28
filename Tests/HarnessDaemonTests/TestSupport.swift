import Foundation
import XCTest

/// Live daemon/PTY integration tests spawn real shells and bind real sockets in-process.
/// That is reliable on a real macOS host but fragile inside the heavily-threaded XCTest
/// runner (fork hazards, dispatchMain, lingering shells), so they are opt-in. Gate them
/// here and run with `HARNESS_LIVE_DAEMON_TESTS=1 swift test`. The deterministic logic
/// (IPC codec, paths, SessionEditor) is always covered in HarnessCoreTests.
func skipUnlessLiveDaemonTests() throws {
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["HARNESS_LIVE_DAEMON_TESTS"] == "1",
        "Set HARNESS_LIVE_DAEMON_TESTS=1 to run live daemon/PTY integration tests."
    )
}

/// Thread-safe text accumulator for asserting on streamed PTY output. The subscription
/// callbacks run off the test thread (and may be `@Sendable`), so the shared buffer
/// can't be a captured `var` — this reference type guards it with a lock instead.
final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    /// Append a chunk and report whether `marker` is now present.
    func appendAndContains(_ chunk: String, marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        return text.contains(marker)
    }
}
