import Foundation
import XCTest

/// Live daemon/PTY integration tests spawn real shells and bind real sockets in-process.
/// That is reliable on a real macOS host but fragile inside the heavily-threaded XCTest
/// runner (fork hazards, dispatchMain, lingering shells), so they are opt-in. Gate them
/// here and run with `HARNESS_LIVE_DAEMON_TESTS=1 swift test`. The deterministic logic
/// (IPC codec, paths, SessionEditor) is always covered in HarnessCoreTests.
/// The daemon *executable* ignores SIGPIPE (`HarnessDaemonMain`), but the XCTest process running
/// these live tests in-process does not — so a PTY/socket write that races teardown (a closing
/// slave / disconnecting client) raises SIGPIPE and kills the whole run with "Exited with unexpected
/// signal code 13", intermittently reddening CI. A PTY master can't use `SO_NOSIGPIPE` the way the
/// sockets do, so match the daemon and ignore SIGPIPE process-wide. Initialized at most once.
let testSIGPIPEIgnored: Void = { signal(SIGPIPE, SIG_IGN) }()

func skipUnlessLiveDaemonTests() throws {
    _ = testSIGPIPEIgnored
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["HARNESS_LIVE_DAEMON_TESTS"] == "1",
        "Set HARNESS_LIVE_DAEMON_TESTS=1 to run live daemon/PTY integration tests."
    )
}

/// Deadline-poll `condition` — the event-driven replacement for fixed settle sleeps and
/// hand-rolled `for _ in 0..<N { usleep }` loops (whose effective timeouts were opaque
/// iteration×interval products, sometimes too short on a loaded CI runner). Returns as
/// soon as the condition holds; on deadline it returns the condition's final value so the
/// caller's assertion fails with ITS message instead of a generic timeout. Generous
/// default: waiting longer never slows a passing test (it returns on the first true).
@discardableResult
func waitUntil(
    timeout: TimeInterval = 10,
    pollIntervalMicros: useconds_t = 20_000,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(pollIntervalMicros)
    }
    return condition()
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

    /// Whether `marker` has been seen so far (for asserting absence).
    func contains(_ marker: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return text.contains(marker)
    }

    /// Everything accumulated so far (for parsing values out of the stream, not just markers).
    var snapshot: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Thread-safe single-value box for capturing an off-thread callback's payload
/// (e.g. the exit status `RealPty.onExit` delivers).
final class AtomicBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value?) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Value? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

/// Thread-safe integer counter for asserting how many times an off-thread callback
/// (e.g. `RealPty.onExit`) fired.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}
