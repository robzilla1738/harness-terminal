import Foundation
import HarnessCore

/// Periodically walks each surface's process tree, identifies running agents,
/// and writes the resulting `AgentSnapshot` back into the snapshot. UI clients
/// observe the change via the existing `snapshotChanged` notification.
/// @unchecked Sendable: scan state (timer, registry, scanInFlight) is confined
/// to the serial `queue`. The timer fires on that same `queue` (passed as the
/// queue to `makeTimerSource`), so a plain `var` Bool is safe as an in-flight
/// guard — no additional lock needed.
public final class AgentScanner: @unchecked Sendable {
    public static let shared = AgentScanner()
    private var timer: DispatchSourceTimer?
    private weak var registry: SurfaceRegistry?
    private let queue = DispatchQueue(label: "com.robert.harness.agent-scanner")
    /// True while a `scan()` body is executing. The timer fires on `queue` (serial), so
    /// this plain Bool is only ever read or written by one execution context at a time.
    /// When the previous scan is still running at the next tick we skip the tick rather
    /// than queuing a second concurrent scan behind it — otherwise a sustained slowdown
    /// (e.g. a large process tree, a slow disk) would back up scan work indefinitely.
    private var scanInFlight = false

    public func start(registry: SurfaceRegistry) {
        self.registry = registry
        timer?.cancel() // idempotent: a second start() must not leak the prior timer
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        timer.resume()
        self.timer = timer
    }

    /// Stop the periodic scan (orderly daemon shutdown / between tests). Safe to call repeatedly.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func scan() {
        // Skip this tick if the previous scan hasn't finished yet. Runs on the serial
        // `queue`, so `scanInFlight` is only ever accessed from one thread at a time.
        guard !scanInFlight else { return }
        scanInFlight = true
        defer { scanInFlight = false }
        registry?.refreshSurfaceMetadata()
        let table = AgentTable.loadFromDisk()
        let changes = AgentDetector.scan(table: table)
        guard !changes.isEmpty, let registry else { return }
        registry.applyAgentChanges(changes)
    }
}
