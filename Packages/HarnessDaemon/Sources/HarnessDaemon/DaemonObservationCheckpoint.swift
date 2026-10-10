import Foundation
import HarnessCore
import HarnessTerminalEngine

struct DaemonObservationCheckpoint: Codable, Sendable {
    static let currentVersion = 1
    var version = Self.currentVersion
    var surfaces: [String: SurfaceObservationCheckpoint]
    var activity: ActivityMemoryCheckpoint?
}
struct SurfaceObservationCheckpoint: Codable, Sendable {
    var nextSequence: UInt64
    var scanner: PtyStreamScanner
    var bell: SurfaceRegistry.BellScanState
    var status: ProgramStatusBook
    var modes: KeyboardModeMirror
    var streamIdentity: String?
    var openCommand: ShellCommandSpan?
    var lastCommand: ShellCommandSpan?
}

extension SurfaceRegistry {
    func observeSurfaceOutput(surfaceKey: String, data: Data, sequence: UInt64, session: SessionPty?) {
        guard observationBudget.reserve(data.count) else {
            monitorLock.lock(); let first = observerRecoveries.insert(surfaceKey).inserted; monitorLock.unlock()
            guard first else { return }
            if let token = session?.monitorSubscription { session?.cancelSubscription(token: token) }
            observationQueue.async { [weak self, weak session] in
                guard let self, let session else { return }
                self.recoverObserver(surfaceKey: surfaceKey, session: session)
            }
            return
        }
        observationQueue.async { [weak self, weak session] in
            guard let self else { return }
            defer { self.observationBudget.release(data.count) }
            self.lock.lock(); let suspended = self.quiesced; self.lock.unlock()
            guard !suspended else { return }
            self.monitorLock.lock(); let floor = self.monitors[surfaceKey]?.lastOutputSequence ?? sequence; self.monitorLock.unlock()
            if sequence > floor {
                self.monitorLock.lock(); let first = self.observerRecoveries.insert(surfaceKey).inserted; self.monitorLock.unlock()
                if first, let session { self.recoverObserver(surfaceKey: surfaceKey, session: session) }
                return
            }
            let skip = floor > sequence ? min(UInt64(data.count), floor - sequence) : 0
            let bytes = Data(data.dropFirst(Int(skip)))
            guard !bytes.isEmpty else { return }
            if let reply = self.noteSurfaceOutput(surfaceKey: surfaceKey, data: bytes, sequence: sequence + skip) { session?.write(reply) }
        }
    }
    func scheduleObserverRecovery(surfaceKey: String, session: SessionPty) {
        monitorLock.lock(); let first = observerRecoveries.insert(surfaceKey).inserted; monitorLock.unlock()
        guard first else { return }
        observationQueue.async { [weak self, weak session] in
            guard let self, let session else { return }; self.recoverObserver(surfaceKey: surfaceKey, session: session)
        }
    }
    func recoverObserver(surfaceKey: String, session: SessionPty) {
        defer { monitorLock.lock(); observerRecoveries.remove(surfaceKey); monitorLock.unlock() }
        lock.lock(); let available = sessions[surfaceKey] === session && !quiesced; lock.unlock()
        guard available else { return }
        monitorLock.lock(); let floor = monitors[surfaceKey]?.lastOutputSequence ?? 1; monitorLock.unlock()
        // Subscribe before backfill. Queued live frames are trimmed against the replay
        // floor when this observation-queue operation completes.
        if let token = session.monitorSubscription { session.cancelSubscription(token: token) }
        do {
            session.monitorSubscription = try session.subscribeSafely(watching: false) { [weak self, weak session] data, sequence in
                self?.observeSurfaceOutput(surfaceKey: surfaceKey, data: data, sequence: sequence, session: session)
            }
        } catch {
            publishObserverFailure("Activity observation is temporarily unavailable; retrying without replaying input. " + error.localizedDescription)
            observationQueue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
                guard let self, let session else { return }; self.scheduleObserverRecovery(surfaceKey: surfaceKey, session: session)
            }
            return
        }
        let replay: AttachHistory
        do { replay = try session.observationReplay(fromSequence: floor) }
        catch {
            publishObserverFailure("Activity replay is temporarily unavailable; its parser checkpoint is retained. " + error.localizedDescription)
            observationQueue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
                guard let self, let session else { return }; self.scheduleObserverRecovery(surfaceKey: surfaceKey, session: session)
            }
            return
        }
        guard !replay.resync, replay.chunks.reduce(0, { $0 + $1.data.count }) <= 32 << 20 else {
            let start = replay.chunks.first?.sequence ?? replay.endSequence
            monitorLock.lock()
            monitors[surfaceKey]?.statusScan = PtyStreamScanner()
            monitors[surfaceKey]?.bellScan = .normal
            monitors[surfaceKey]?.openCommand = nil
            monitors[surfaceKey]?.lastOutputSequence = start
            monitorLock.unlock()
            publishObserverFailure("Some activity output exceeded retained replay. Live terminal output remains available; activity history may have a gap.")
            // Feed retained bytes through the reset parser instead of silently skipping them.
            for chunk in replay.chunks {
                if let reply = noteSurfaceOutput(surfaceKey: surfaceKey, data: chunk.data, sequence: chunk.sequence, replaying: true) { session.write(reply) }
            }
            return
        }
        for chunk in replay.chunks {
            monitorLock.lock(); let next = monitors[surfaceKey]?.lastOutputSequence ?? floor; monitorLock.unlock()
            let skip = next > chunk.sequence ? min(UInt64(chunk.data.count), next - chunk.sequence) : 0
            let bytes = Data(chunk.data.dropFirst(Int(skip)))
            if !bytes.isEmpty, let reply = noteSurfaceOutput(surfaceKey: surfaceKey, data: bytes, sequence: chunk.sequence + skip, replaying: true) { session.write(reply) }
        }
    }
    func publishObserverFailure(_ message: String) {
        lock.lock(); editor.snapshot.activityError = message; editor.snapshot.revision += 1; let revision = editor.snapshot.revision; lock.unlock()
        onSnapshotCommitted?(revision)
    }
    func observationCheckpoint() -> IPCResponse {
        monitorLock.lock()
        let surfaces = monitors.mapValues { monitor in
            SurfaceObservationCheckpoint(nextSequence: monitor.lastOutputSequence, scanner: monitor.statusScan,
                bell: monitor.bellScan, status: monitor.programStatus, modes: monitor.modeMirror,
                streamIdentity: monitor.streamIdentity, openCommand: monitor.openCommand, lastCommand: monitor.lastCommand)
        }
        monitorLock.unlock()
        do {
            let data = try JSONEncoder().encode(DaemonObservationCheckpoint(surfaces: surfaces, activity: try activity.checkpoint()))
            guard data.count <= 4 << 20 else { return .error("Observation checkpoint exceeds the handover budget.") }
            return .text(String(decoding: data, as: UTF8.self))
        } catch { return .error("Observation checkpoint could not be encoded.") }
    }
    func restoreObservations(_ data: Data) -> String? {
        guard data.count <= 4 << 20, let checkpoint = try? JSONDecoder().decode(DaemonObservationCheckpoint.self, from: data), checkpoint.version == DaemonObservationCheckpoint.currentVersion else {
            return "Daemon observation checkpoint is incompatible; retain the current daemon."
        }
        lock.lock(); let live = sessions; lock.unlock()
        var replays: [String: AttachHistory] = [:], total = 0
        for (id, observation) in checkpoint.surfaces {
            guard let pty = live[id] else { continue }
            guard let state = try? pty.liveState(), state.ringStart <= observation.nextSequence else { return "Observation replay was evicted or its owner is unavailable; retain the current daemon." }
            guard let replay = pty.attachHistory(history: true, fromSequence: observation.nextSequence, screenOnResync: false, includeCheckpoint: false), !replay.resync else { return "Session-host observation replay is unavailable or was evicted." }
            total += replay.chunks.reduce(0) { $0 + $1.data.count }
            guard total <= 32 << 20 else { return "Observation replay exceeded the bounded handover budget." }
            replays[id] = replay
        }
        monitorLock.lock()
        for (id, observation) in checkpoint.surfaces {
            var monitor = monitors[id] ?? SurfaceMonitor()
            monitor.statusScan = observation.scanner; monitor.bellScan = observation.bell
            monitor.programStatus = observation.status; monitor.modeMirror = observation.modes
            monitor.streamIdentity = observation.streamIdentity; monitor.openCommand = observation.openCommand; monitor.lastCommand = observation.lastCommand
            monitor.lastOutputSequence = observation.nextSequence; monitor.statusDirty = true
            monitors[id] = monitor
        }
        monitorLock.unlock()
        for (id, replay) in replays {
            let floor = checkpoint.surfaces[id]!.nextSequence
            for chunk in replay.chunks {
                let skip = floor > chunk.sequence ? min(UInt64(chunk.data.count), floor - chunk.sequence) : 0
                let bytes = Data(chunk.data.dropFirst(Int(skip)))
                if !bytes.isEmpty { _ = noteSurfaceOutput(surfaceKey: id, data: bytes, sequence: chunk.sequence + skip, replaying: true) }
            }
        }
        return nil
    }
}

final class ObservationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, entries = 0
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count <= 32 << 20, bytes <= (32 << 20) - count, entries < 32768 else { return false }
        bytes += count; entries += 1; return true
    }
    func release(_ count: Int) { lock.lock(); bytes -= count; entries -= 1; lock.unlock() }
}
