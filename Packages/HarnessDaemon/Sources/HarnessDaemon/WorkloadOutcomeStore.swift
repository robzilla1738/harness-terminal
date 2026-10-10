import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owner-queue catalog of structural launch receipts, independent of layout and
/// scrollback deletion. Never resumes a process after restarting the host. Closed
/// receipts have the same 14-day/500-record boundary as closed execution detail.
final class WorkloadOutcomeStore {
    private struct Catalog: Codable { var version = 1; var outcomes: [WorkloadOutcome] }
    private var outcomes: [UUID: WorkloadOutcome] = [:]
    private let url: URL?
    private var bytes: Data?
    private(set) var failure: String?
    private var loaded = false
    init(url: URL?) {
        self.url = url
        guard let url else { loaded = true; return }
        do {
            bytes = try PrivateFile.read(url)
            if let bytes {
                let catalog = try JSONDecoder().decode(Catalog.self, from: bytes)
                guard catalog.version == 1, catalog.outcomes.count <= 1000,
                      Set(catalog.outcomes.map(\.id)).count == catalog.outcomes.count,
                      catalog.outcomes.allSatisfy({ UUID(uuidString: $0.surfaceID) != nil && $0.acceptedAt.timeIntervalSince1970.isFinite && $0.observedAt.timeIntervalSince1970.isFinite }) else { throw PrivateFile.Failure.unavailable }
                for var outcome in catalog.outcomes {
                    if outcome.state == .running || outcome.state == .reserved {
                        outcome.state = .unknown; outcome.observedAt = .now
                    }
                    outcomes[outcome.id] = outcome
                }
            }
            loaded = true; reconcileAbsentRoots(); prune(); try save()
        } catch { failure = "Workload outcome storage is unavailable. Existing programs are preserved; repair the owned workload-outcomes file before launching more workloads. " + error.localizedDescription }
    }
    func reserve(_ id: UUID, surfaceID: String) throws {
        guard failure == nil, UUID(uuidString: surfaceID) != nil else { throw SessionHostError.refused(failure ?? "Invalid workload surface.") }
        prune()
        guard outcomes[id] == nil else { throw SessionHostError.refused("This workload ID was already accepted. Query its recorded outcome; it will not be launched again.") }
        guard outcomes.values.filter(\.mayBeRunning).count < 500 else { throw SessionHostError.refused("The active workload receipt budget is full. Existing workloads are preserved.") }
        let outcome = WorkloadOutcome(id: id, surfaceID: surfaceID)
        outcomes[id] = outcome
        do { try save() } catch { outcomes.removeValue(forKey: id); failure = error.localizedDescription; throw error }
    }
    func launched(_ id: UUID, pty: RealPty) {
        guard var outcome = outcomes[id] else { return }
        outcome.streamIdentity = pty.streamIdentity; outcome.processGeneration = pty.processGeneration
        outcome.pid = pty.currentChildPID; outcome.kernelIdentity = ProcessScan.generation(pty.currentChildPID)
        outcome.state = .running; outcome.observedAt = .now; outcomes[id] = outcome; persist()
    }
    func launchFailed(_ id: UUID) {
        guard var outcome = outcomes[id], outcome.state == .reserved else { return }
        // A throwing fork/launch path cannot prove whether exec briefly ran.
        outcome.state = .unknown; outcome.observedAt = .now; outcomes[id] = outcome; persist()
    }
    func reaped(_ id: UUID, stream: String, generation: UInt64, status: Int32?) {
        guard var outcome = outcomes[id], outcome.streamIdentity == stream, outcome.processGeneration == generation else { return }
        outcome.state = status == nil ? .unknown : .exited; outcome.exitCode = status
        outcome.observedAt = .now; outcomes[id] = outcome; prune(); persist()
    }
    func requestCancellation(_ id: UUID) throws -> WorkloadOutcome {
        guard var outcome = outcomes[id] else { throw SessionHostError.refused("The workload receipt is unavailable or expired. No process was signaled.") }
        guard outcome.state == .running else { return outcome }
        outcome.cancellationRequested = true; outcome.observedAt = .now; outcomes[id] = outcome
        // Failure to persist does not prevent explicitly requested cancellation;
        // return the unavailable flag and retain the truthful in-memory outcome.
        persist(); return read(id)!
    }
    func read(_ id: UUID) -> WorkloadOutcome? {
        let changed = reconcileAbsentRoots(); prune()
        if loaded, changed || failure != nil { persist() }
        guard var value = outcomes[id] else { return nil }
        value.storageUnavailable = failure != nil; return value
    }
    func maintain() { let before = outcomes.count; let changed = reconcileAbsentRoots(); prune(); if changed || outcomes.count != before || failure != nil { persist() } }
    @discardableResult
    private func reconcileAbsentRoots() -> Bool {
        var changed = false
        for (id, var value) in outcomes where value.state == .unknown && value.processAbsentObservedAt == nil {
            guard let pid = value.pid, pid > 1 else { continue }
            let generationChanged = value.kernelIdentity.map { expected in ProcessScan.generation(pid).map { $0 != expected } ?? false } ?? false
            let absent = kill(pid, 0) != 0 && errno == ESRCH
            if generationChanged || absent || ProcessScan.isZombie(pid) { value.processAbsentObservedAt = .now; value.observedAt = .now; outcomes[id] = value; changed = true }
        }
        return changed
    }
    private func prune() {
        let closed = outcomes.values.filter { !$0.mayBeRunning }.sorted { $0.observedAt > $1.observedAt }
        for (index, record) in closed.enumerated() where index >= 500 || record.observedAt < Date().addingTimeInterval(-14 * 86400) { outcomes.removeValue(forKey: record.id) }
    }
    private func persist() { do { try save() } catch { failure = error.localizedDescription } }
    private func save() throws {
        guard loaded else { throw PrivateFile.Failure.unavailable }
        guard let url else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Catalog(outcomes: outcomes.values.sorted { $0.id.uuidString < $1.id.uuidString }))
        _ = try PrivateFile.replace(url, data: data, expected: bytes, backup: false); bytes = data; failure = nil
    }
}
