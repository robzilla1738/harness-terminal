import Foundation
import HarnessCore

/// Periodically walks each surface's process tree, identifies running agents,
/// and writes the resulting `AgentSnapshot` back into the snapshot. UI clients
/// observe the change via the existing `snapshotChanged` notification.
/// @unchecked Sendable: scan state is confined to the serial `queue`.
public final class AgentScanner: @unchecked Sendable {
    public static let shared = AgentScanner()
    private var timer: DispatchSourceTimer?
    private weak var registry: SurfaceRegistry?
    private let queue = DispatchQueue(label: "com.robert.harness.agent-scanner")

    public func start(registry: SurfaceRegistry) {
        self.registry = registry
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        timer.resume()
        self.timer = timer
    }

    private func scan() {
        registry?.refreshSurfaceMetadata()
        let table = AgentTable.loadFromDisk()
        let changes = AgentDetector.scan(table: table)
        guard !changes.isEmpty, let registry else { return }
        registry.applyAgentChanges(changes)
    }
}
