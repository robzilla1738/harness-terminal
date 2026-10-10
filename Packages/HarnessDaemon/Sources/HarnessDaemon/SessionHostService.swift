import Foundation
import HarnessCore
import HarnessTerminalEngine
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The public socket and PTY streams outlive each replaceable application daemon.
public final class SessionHostService: @unchecked Sendable {
    private let store = SessionHostStore()
    private let ownerListener: SessionHostListener
    private let publicListener: SessionHostListener
    private let lifecycleQueue = DispatchQueue(label: "com.harness.session-host.lifecycle")
    private let recoveryQueue = DispatchQueue(label: "com.harness.session-host.history-recovery", qos: .utility)
    private let recoverySlot = DispatchSemaphore(value: 1)
    private let healthQueue = DispatchQueue(label: "com.harness.session-host.health", attributes: .concurrent)
    private let healthSlots = DispatchSemaphore(value: 8)
    private let ownerPath: String
    private let daemonExecutable: URL
    private var active: Worker?
    private var lastCompatible: Worker?
    private var replacing = false
    private var historyRecovering = false
    private var unretired: [UUID: Worker] = [:]
    private var retirementScheduled = false
    private var frontends: [ObjectIdentifier: Frontend] = [:]
    private var ownerChannels: [ObjectIdentifier: SessionHostChannel] = [:]
    private var arbiter = SurfaceSizeArbiter()
    private let started = Date()
    private var stopping = false
    private var shutdownRetryScheduled = false
    private var shutdownWorkerRetry: DispatchSourceTimer?
    private var migrationFailure: String?
    private var historyMaintenance: DispatchSourceTimer?
    private let controlSlots = DispatchSemaphore(value: 256)
    public var onShutdown: (@Sendable () -> Void)?
    private struct Worker: Sendable {
        var process: Process
        var generation: UUID
        var socket: String
        var executable: URL
        var processIdentity: String?
    }
    public init(daemonExecutable: URL) {
        self.daemonExecutable = daemonExecutable
        ownerPath = HarnessPaths.runtimeDirectory.appendingPathComponent("owner.sock").path
        ownerListener = SessionHostListener(path: ownerPath)
        publicListener = SessionHostListener(path: HarnessPaths.socketURL.path)
        store.onRetirementComplete = { [weak self] in self?.continueShutdownWhenRetired() }
        store.onSurfaceExit = { [weak self] id, _ in
            guard let self else { return }
            for frontend in self.frontends.values where frontend.tokens[id] != nil {
                frontend.tokens.removeValue(forKey: id)
                _ = self.arbiter.disconnect(client: frontend.channel.fd, surface: id)
                if frontend.tokens.isEmpty { frontend.channel.closeAfterWrites() }
            }
        }
    }
    public func start() throws {
        try HarnessPaths.ensureDirectories()
        let maintenance = DispatchSource.makeTimerSource(queue: store.queue)
        maintenance.schedule(deadline: .now() + 3600, repeating: 3600)
        maintenance.setEventHandler { [weak self] in self?.store.closedHistory.maintain(); self?.store.workloads.maintain() }
        historyMaintenance = maintenance; maintenance.resume()
        migrationFailure = HistoryMigration.checkpoints(directory: HarnessPaths.scrollbackDirectory,
            legacyKeyURL: HarnessPaths.runtimeDirectory.appendingPathComponent("snapshot.key"), protection: .system())
        // The caller already owns daemon.lock and has proved any prior PID is stale.
        for path in [ownerPath, HarnessPaths.socketURL.path] { if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) } }
        try ownerListener.start { [weak self] channel in
            guard let self else { channel.closeChannel(); return }
            let accepted = self.store.queue.sync { () -> Bool in
                guard self.ownerChannels.count < 4096, !self.stopping else { return false }
                self.ownerChannels[ObjectIdentifier(channel)] = channel; return true
            }
            guard accepted else { channel.closeChannel(); return }
            channel.start(onFrame: { [weak self, weak channel] frame in
                guard let self, let channel, let request = try? JSONDecoder().decode(SessionHostRequest.self, from: frame.dropFirst(4)) else { channel?.closeChannel(); return }
                self.store.handle(request, channel: channel)
            }, onEnd: { [weak self, weak channel] in
                guard let self, let channel else { return }; self.store.forget(channel)
                self.store.queue.async { self.ownerChannels.removeValue(forKey: ObjectIdentifier(channel)) }
            })
        }
        let first = try launch(executable: daemonExecutable, warm: false)
        store.queue.sync { active = first; lastCompatible = first }
        try publicListener.start { [weak self] channel in self?.accept(channel) }
        watch(first)
    }
    private func launch(executable: URL, warm: Bool) throws -> Worker {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else { throw SessionHostError.refused("Candidate daemon is not an executable local file.") }
        let generation = UUID()
        let socket = HarnessPaths.runtimeDirectory.appendingPathComponent("d-\(generation.uuidString.prefix(8)).sock").path
        store.queue.sync { store.generations.insert(generation); if !warm { store.grant(generation) } }
        let process = Process(); process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_SESSION_HOST_SOCKET"] = ownerPath
        environment["HARNESS_SESSION_HOST_PID"] = String(getpid())
        environment["HARNESS_SESSION_HOST_IDENTITY"] = ProcessScan.generation(getpid())
        environment["HARNESS_DAEMON_GENERATION"] = generation.uuidString
        environment["HARNESS_DAEMON_SOCKET"] = socket
        environment["HARNESS_STREAM_EPOCH"] = store.epoch
        environment["HARNESS_DAEMON_WARM"] = warm ? "1" : "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        var worker = Worker(process: process, generation: generation, socket: socket, executable: executable, processIdentity: nil)
        do {
            try process.run()
            let identityDeadline = Date().addingTimeInterval(1)
            while worker.processIdentity == nil, process.isRunning, Date() < identityDeadline {
                worker.processIdentity = ProcessScan.generation(process.processIdentifier)
                if worker.processIdentity == nil { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard worker.processIdentity != nil else { throw SessionHostError.refused("The launched daemon's kernel process identity is unavailable; adoption was refused.") }
            let client = DaemonClient(endpoint: .unix(path: socket))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, process.isRunning {
                if case let .daemonStats(stats) = try? client.request(.daemonStats, timeout: 0.25), stats.compatibility == .compatible {
                    guard stats.supports(DaemonStats.sessionHostWorker), stats.surfaceCount == store.queue.sync(execute: { store.ptys.count }) else {
                        throw SessionHostError.refused("Candidate does not support this session-host protocol or could not adopt every hosted shell.")
                    }
                    guard case .snapshot = try client.request(.getSnapshot, timeout: 1) else { throw SessionHostError.refused("Candidate cannot decode the current layout.") }
                    return worker
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw SessionHostError.refused("Candidate failed compatibility or startup validation; the current daemon and all shells are retained.")
        } catch {
            let startupFailure = error
            do { try retire(worker) } catch { rememberRetirement(worker) }
            _ = store.queue.sync { store.generations.remove(generation) }
            throw startupFailure
        }
    }
    private func watch(_ worker: Worker) {
        worker.process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lifecycleQueue.async { [weak self] in
                guard let self else { return }
                let shouldRecover = self.store.queue.sync { !self.stopping && self.active?.generation == worker.generation && !self.replacing }
                guard shouldRecover else { return }
                guard self.store.queue.sync(execute: { self.unretired.isEmpty }) else {
                    self.store.queue.sync { self.active = nil; self.store.activeGeneration = nil }
                    return
                }
                // A failed daemon does not close masters. Its replacement adopts those
                // same surface identities and parser checkpoints; no input is replayed.
                var candidate: Worker?
                do {
                    let applicationCheckpoint = self.store.queue.sync { self.store.applicationCheckpoint }
                    let replacement = try self.launch(executable: worker.executable, warm: true); candidate = replacement
                    self.store.queue.sync { self.store.grant(replacement.generation); self.active = replacement }
                    guard case .ok = try DaemonClient(endpoint: .unix(path: replacement.socket)).request(.handoverDaemon(phase: .activate, checkpoint: applicationCheckpoint)) else { throw SessionHostError.refused("Recovery activation failed.") }
                    self.store.queue.sync { self.store.generations.remove(worker.generation); self.lastCompatible = replacement }
                    self.watch(replacement)
                } catch {
                    self.store.queue.sync {
                        self.active = nil; self.store.activeGeneration = nil
                        if let candidate { self.store.generations.remove(candidate.generation) }
                    }
                    if let candidate {
                        do { try self.retire(candidate) } catch { self.rememberRetirement(candidate) }
                    }
                    fputs("HarnessSessionHost: daemon unavailable; shells retained (\(error.localizedDescription))\n", harnessStderr)
                }
            }
        }
    }
    /// Retire only a child daemon we launched. PTYs are owned by this process.
    /// Never restore a second ledger writer before the failed candidate has exited.
    private func retire(_ worker: Worker) throws {
        guard worker.process.isRunning else { return }
        let pid = worker.process.processIdentifier
        guard let identity = worker.processIdentity, ProcessScan.generation(pid) == identity else {
            throw SessionHostError.refused("Child daemon retirement could not verify its original process identity; no signal was sent.")
        }
        worker.process.terminate()
        var deadline = Date().addingTimeInterval(2)
        while worker.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if worker.process.isRunning {
            guard ProcessScan.generation(pid) == identity else { throw SessionHostError.refused("Candidate retirement could not verify its process identity.") }
            guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw SessionHostError.refused("Candidate retirement failed; a second daemon will not be activated.") }
            deadline = Date().addingTimeInterval(2)
            while worker.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard !worker.process.isRunning else { throw SessionHostError.refused("The failed candidate has not exited; shells are retained and daemon recovery is waiting.") }
    }
    private func rememberRetirement(_ worker: Worker) {
        let schedule = store.queue.sync { () -> Bool in
            unretired[worker.generation] = worker
            guard !retirementScheduled, !stopping else { return false }
            retirementScheduled = true; return true
        }
        guard schedule else { return }
        lifecycleQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.retryRetirements() }
    }
    private func retryRetirements() {
        let workers = store.queue.sync { Array(unretired.values) }
        for worker in workers {
            do {
                try retire(worker)
                store.queue.sync { unretired.removeValue(forKey: worker.generation); store.generations.remove(worker.generation) }
            } catch { /* Keep the owned reference and deny further adoption until it exits. */ }
        }
        let again = store.queue.sync { () -> Bool in
            retirementScheduled = !unretired.isEmpty && !stopping; return retirementScheduled
        }
        if again { lifecycleQueue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.retryRetirements() } }
    }
    private func replace(executable: URL?, replyTo channel: SessionHostChannel) {
        // Called on the owner queue. Reserve handover before enqueueing it, so a
        // burst cannot schedule repeated upgrades behind an in-flight replacement.
        guard unretired.isEmpty else { send(.error("A previously launched daemon has not retired. Adoption is blocked while its original process identity is checked and retirement is retried; all shells remain running."), channel); return }
        guard !replacing, !historyRecovering, !stopping, let prior = active ?? lastCompatible else { send(.error("Daemon handover or history recovery is in progress, or the daemon is unavailable."), channel); return }
        replacing = true
        lifecycleQueue.async { [self, channel] in
            defer { self.store.queue.sync { self.replacing = false } }
            var candidate: Worker?
            var applicationCheckpoint: Data?
            do {
                if prior.process.isRunning {
                    let oldClient = DaemonClient(endpoint: .unix(path: prior.socket))
                    guard case let .text(state) = try oldClient.request(.handoverDaemon(phase: .prepare), timeout: 5) else { throw SessionHostError.refused("The current daemon could not drain and checkpoint its accepted work.") }
                    applicationCheckpoint = Data(state.utf8)
                } else { applicationCheckpoint = self.store.queue.sync { self.store.applicationCheckpoint } }
                let checkpoints = try self.store.queue.sync { try self.checkpointBudget() }
                let next = try self.launch(executable: executable ?? self.daemonExecutable, warm: true); candidate = next
                try self.store.queue.sync {
                    for (id, end) in checkpoints {
                        guard let pty = self.store.ptys[id] else { continue }
                        let replay = pty.attachHistory(history: true, fromSequence: end)
                        guard !replay.resync, replay.chunks.reduce(0, { $0 + $1.data.count }) <= 8 << 20 else { throw SessionHostError.refused("Handover replay exceeded its retained budget; retain the current daemon.") }
                    }
                    self.store.grant(next.generation); self.active = next
                    self.store.applicationCheckpoint = applicationCheckpoint
                }
                guard case .ok = try DaemonClient(endpoint: .unix(path: next.socket)).request(.handoverDaemon(phase: .activate, checkpoint: applicationCheckpoint), timeout: 5) else { throw SessionHostError.refused("Candidate activation failed.") }
                self.watch(next)
                self.store.queue.sync {
                    self.lastCompatible = next
                    // Terminal frontends have no worker stream and remain attached.
                    for frontend in self.frontends.values { frontend.retireWorker() }
                }
                do {
                    try self.retire(prior)
                    _ = self.store.queue.sync { self.store.generations.remove(prior.generation) }
                    self.send(.ok, channel)
                } catch {
                    // Adoption succeeded. Keep its exclusive lease even if an old,
                    // quiesced worker cannot be retired; rolling back would lose service.
                    self.rememberRetirement(prior)
                    self.send(.error("The replacement daemon is active and shells are intact, but retiring the quiesced previous daemon failed: " + error.localizedDescription), channel)
                }
            } catch {
                let adoptionFailure = error.localizedDescription
                // Revoke the failed candidate first. Its ledger must stop before the
                // previous daemon reopens the store and resumes background services.
                self.store.queue.sync { self.store.activeGeneration = nil; self.active = nil }
                do {
                    if let candidate {
                        do { try self.retire(candidate) } catch { self.rememberRetirement(candidate); throw error }
                    }
                    let restored = prior.process.isRunning ? prior : try self.launch(executable: prior.executable, warm: true)
                    self.store.queue.sync { self.store.grant(restored.generation); self.active = restored; self.lastCompatible = restored }
                    guard case .ok = try DaemonClient(endpoint: .unix(path: restored.socket)).request(.handoverDaemon(phase: .resume, checkpoint: applicationCheckpoint), timeout: 5) else {
                        throw SessionHostError.refused("The previous daemon could not resume its checkpoint.")
                    }
                    self.watch(restored)
                    if let candidate { _ = self.store.queue.sync { self.store.generations.remove(candidate.generation) } }
                    self.send(.error(adoptionFailure + " The previous daemon was restored; all shells remain running."), channel)
                } catch {
                    self.store.queue.sync { self.store.activeGeneration = nil; self.active = nil }
                    self.send(.error(adoptionFailure + " Recovery failed: " + error.localizedDescription + " All session-host shells remain running; retry daemon replacement."), channel)
                }

            }
        }
    }
    private func checkpointBudget() throws -> [String: UInt64] {
        var budget = 0, ends: [String: UInt64] = [:]
        for (id, pty) in store.ptys {
            let history = pty.attachHistory(history: false, fromSequence: nil, includeCheckpoint: true)
            guard let data = history.screen?.checkpoint else { throw SessionHostError.refused("A versioned terminal checkpoint is unavailable.") }
            budget += data.count
            guard budget <= 32 << 20 else { throw SessionHostError.refused("Parser checkpoints exceed the bounded handover budget.") }
            ends[id] = history.endSequence
        }
        return ends
    }
    private func accept(_ channel: SessionHostChannel) {
        let frontend = Frontend(channel: channel)
        let accepted = store.queue.sync { () -> Bool in
            guard frontends.count < 128 else { return false }
            frontends[ObjectIdentifier(channel)] = frontend; return true
        }
        guard accepted else { channel.closeChannel(); return }
        channel.start(onFrame: { [weak self, weak frontend] frame in
            guard let self, let frontend else { return }
            guard self.controlSlots.wait(timeout: .now()) == .success else { frontend.channel.closeChannel(); return }
            self.store.queue.async { defer { self.controlSlots.signal() }; self.handle(frame, frontend: frontend) }
        }, onEnd: { [weak self, weak frontend] in
            guard let self, let frontend else { return }
            self.store.queue.async { self.detach(frontend); self.frontends.removeValue(forKey: ObjectIdentifier(frontend.channel)) }
        })
    }
    private func handle(_ raw: Data, frontend: Frontend) {
        var buffer = raw
        guard let frame = try? IPCCodec.decodeRequestOrInput(from: &buffer) else { send(.error("Unrecognized request."), frontend.channel); return }
        if case let .input(id, data) = frame {
            guard !stopping else { send(.inputRejected("Shutdown is in progress; terminal input was not accepted."), frontend.channel); return }
            if !frontend.readOnly, store.ptys[id]?.write(data) != true, frontend.inputErrors { send(.inputRejected("Input was not accepted."), frontend.channel) }
            return
        }
        guard case let .request(request) = frame, let request else { send(.error("Unrecognized request."), frontend.channel); return }
        let channel = frontend.channel
        if request.requiresLocalOwner, frontend.tunnel { send(.error("This administrative operation requires a local owner connection."), channel); return }
        if stopping {
            switch request {
            case .ping, .daemonStats: break
            default: send(.error("Session-host shutdown is waiting for owned process retirement. Exclusive ownership is retained; no replacement has been started."), channel); return
            }
        }
        switch request {
        case .ping: send(.pong, channel)
        case .handoverDaemon: send(.error("Private daemon handover controls cannot be invoked through the public socket."), channel)
        case let .replaceDaemon(path):
            guard !frontend.tunnel else { send(.error("Daemon replacement requires a local owner connection."), channel); return }
            replace(executable: path.map { URL(fileURLWithPath: $0) }, replyTo: channel)
        case let .shutdownDaemon(empty):
            guard !frontend.tunnel else { send(.error("Session-host restart requires a local owner connection."), channel); return }
            guard !replacing, !historyRecovering else { send(.error("Daemon handover or history recovery is in progress; retry the session-host restart after it finishes."), channel); return }
            guard !empty || (store.ptys.isEmpty && store.livePipeCount == 0 && store.pendingRetirementCount == 0) else { send(.error("Preserved \(store.ptys.count) live shell(s) and \(store.livePipeCount) pipe consumer(s), plus \(store.pendingRetirementCount) child process(es) still retiring."), channel); return }
            stopping = true; store.activeGeneration = nil; send(.ok, channel)
            lifecycleQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in if self?.stop() == true { self?.onShutdown?() } }
        case .retryHistory:
            guard !frontend.tunnel, !replacing, recoverySlot.wait(timeout: .now()) == .success else {
                send(.error("Local history recovery is unavailable or already in progress; programs remain running."), channel); return
            }
            historyRecovering = true
            store.closedHistory.recover(protectedSurfaces: Set(store.ptys.keys))
            let retentionFailure = store.closedHistory.failure
            let ptys = Array(store.ptys.values), closedFiles = store.closedHistory.recoveryFiles(), worker = active
            recoveryQueue.async { [self, channel] in
                defer { store.queue.async { [self] in historyRecovering = false; recoverySlot.signal() } }
                do {
                    let protection = HistoryProtection.system()
                    guard protection.kind != .keyUnavailable else { throw HistoryProtectionError.keyUnavailable(protection.unavailableReason ?? "Unlock the history key first.") }
                    let migration = HistoryMigration.checkpoints(directory: HarnessPaths.scrollbackDirectory,
                        legacyKeyURL: HarnessPaths.runtimeDirectory.appendingPathComponent("snapshot.key"), protection: protection)
                    self.store.queue.sync { self.migrationFailure = migration }
                    var failures = [migration, retentionFailure].compactMap { $0 }
                    for pty in ptys {
                        do { try pty.recoverHistory(protection: protection) }
                        catch { failures.append(error.localizedDescription) }
                    }
                    for file in closedFiles {
                        do { try file.recover(protection: protection) }
                        catch { failures.append(error.localizedDescription) }
                    }
                    if let worker {
                        do {
                            let response = try DaemonClient(endpoint: .unix(path: worker.socket)).request(.retryHistory, timeout: 10)
                            if case let .error(message) = response { failures.append(message) }
                            else if case .ok = response { /* All available stores were attempted. */ }
                            else { failures.append("The application daemon returned an unsupported recovery response.") }
                        } catch { failures.append(error.localizedDescription) }
                    } else { failures.append("The application daemon is unavailable; encrypted terminal capture has resumed.") }
                    if failures.isEmpty { send(.ok, channel) }
                    else { send(.error("Some history remains unavailable; healthy stores resumed encrypted capture. " + Array(Set(failures)).sorted().joined(separator: " ")), channel) }
                } catch { send(.error("History recovery did not complete; shells remain running. " + error.localizedDescription), channel) }
            }
        case .daemonStats:
            guard healthSlots.wait(timeout: .now()) == .success else { send(.error("Session-host health requests are busy; programs remain running."), channel); return }
            let closedHistoryEvicted = store.closedHistory.evicted, closedHistoryFailure = store.closedHistory.failure
            let ptys = store.ptys, worker = active, epoch = store.epoch, count = frontends.count, migrationFailure = migrationFailure, pipeCount = store.livePipeCount, pendingRetirements = store.pendingRetirementCount, shutdownPending = stopping, daemonRetirements = unretired.count
            healthQueue.async { [self, channel] in
                defer { self.healthSlots.signal() }
                var stats: DaemonStats
                if let worker, case let .daemonStats(value) = try? DaemonClient(endpoint: .unix(path: worker.socket)).request(.daemonStats, timeout: 1) { stats = value; stats.daemonAvailable = true }
                else {
                    stats = DaemonStats(pid: getpid(), uptimeSeconds: Date().timeIntervalSince(self.started), surfaceCount: ptys.count, totalScrollbackBytes: ptys.values.reduce(0) { $0 + $1.scrollbackByteCount }, clientCount: count, subscriberCount: 0, snapshotRevision: 0, capabilities: [DaemonStats.attachStream], protocolLevel: HarnessVersion.protocolLevel)
                    stats.daemonAvailable = false
                }
                stats.daemonPID = stats.daemonAvailable == true ? worker?.process.processIdentifier : nil
                stats.pid = getpid(); stats.sessionHostPID = getpid(); stats.sessionHostBuild = HarnessVersion.build; stats.sessionHostProtocolLevel = SessionHostRequest.protocolVersion; stats.sessionHostCapabilities = [DaemonStats.workloadInput]; stats.sessionHostVersion = HarnessVersion.short; stats.epoch = epoch
                stats.surfaceCount = ptys.count; stats.clientCount = count; stats.pipeConsumerCount = pipeCount; stats.pendingProcessRetirements = pendingRetirements; stats.shutdownPending = shutdownPending; stats.pendingDaemonRetirements = daemonRetirements
                let reasons = Array(Set(ptys.values.compactMap(\.historyUnavailable))).sorted()
                if !reasons.isEmpty { stats.historyUnavailable = Array(Set([stats.historyUnavailable].compactMap { $0 } + reasons)).sorted().joined(separator: " ") }
                if let closedHistoryFailure { stats.historyUnavailable = [stats.historyUnavailable, closedHistoryFailure].compactMap { $0 }.joined(separator: " ") }
                if closedHistoryEvicted { stats.historyUnavailable = [stats.historyUnavailable, "Closed-session history was removed under the retention limits."].compactMap { $0 }.joined(separator: " ") }
                if let migrationFailure { stats.historyUnavailable = [stats.historyUnavailable, migrationFailure].compactMap { $0 }.joined(separator: " ") }
                if ptys.values.contains(where: { $0.historyProtection == .keyUnavailable }) { stats.historyProtection = .keyUnavailable }
                stats.capabilities = (stats.capabilities ?? []) + [DaemonStats.sessionHost]
                self.send(.daemonStats(stats), channel)
            }
        case let .attachStream(attach): attachStream(attach, frontend)
        case let .subscribeSurfaceOutput(id, label): subscribe(id, label: label, readOnly: false, frontend: frontend)
        case let .subscribeSurfaceOutputReadOnly(id, label): subscribe(id, label: label, readOnly: true, frontend: frontend)
        case let .cancelSubscription(id), let .detachSurface(id):
            if let token = frontend.tokens.removeValue(forKey: id) { store.ptys[id]?.cancelSubscription(token: token) }
            let size = arbiter.disconnect(client: channel.fd, surface: id)
            let applied = applyDisconnectedSize(size, surface: id)
            send(applied ? .ok : .error("Detached, but the remaining client size could not be applied. Resize the remaining pane to retry."), channel)
            ownership(id)
        case let .sendData(id, data): send(frontend.readOnly ? .ok : store.ptys[id]?.write(data) == true ? .ok : .error("Input was not accepted."), channel)
        case let .send(id, text): send(frontend.readOnly ? .ok : store.ptys[id]?.write(text) == true ? .ok : .error("Input was not accepted."), channel)
        case let .resizeSurface(id, rows, cols):
            guard TerminalGeometry.isValid(cols: Int(cols), rows: Int(rows)) else { send(.error("Invalid terminal dimensions."), channel); return }
            guard store.ptys[id] != nil else { send(.error("Surface not found."), channel); return }
            let previousArbiter = arbiter
            if !frontend.readOnly, let size = arbiter.vote(client: channel.fd, surface: id, rows: rows, cols: cols), store.ptys[id]?.resize(rows: size.rows, cols: size.cols) != true { arbiter = previousArbiter; send(.error("Resize could not be confirmed; inspect the current pane size before retrying."), channel); return }
            send(.ok, channel); ownership(id)
        case let .identifyClient(label): frontend.label = label; send(.clientID(frontend.id), channel)
        case let .presentClient(kind, version, _, tunnel): frontend.kind = kind; frontend.version = version; frontend.tunnel = tunnel; send(.ok, channel)
        case .listClients:
            send(.clients(frontends.values.map { ClientSummary(id: $0.id, label: $0.label, attachedSurfaceIDs: Array($0.tokens.keys), connectedAt: $0.connectedAt, kind: $0.kind, version: $0.version, principalUID: UInt32(getuid()), tunnel: $0.tunnel, age: Date().timeIntervalSince($0.connectedAt)) }), channel)
        case let .detachClient(id):
            guard let target = frontends.values.first(where: { $0.id == id }), target !== frontend else { send(.error("Client is unavailable or is the caller."), channel); return }
            target.channel.closeChannel(); send(.ok, channel)
        case let .takeSurface(id, clientID):
            guard let target = clientID.flatMap({ id in frontends.values.first { $0.id == id } }) ?? (clientID == nil ? frontend : nil) else { send(.error("Client not found."), channel); return }
            let previousArbiter = arbiter
            let taken = arbiter.take(client: target.channel.fd, surface: id)
            guard taken.accepted else { send(.error("Attach and submit a size before taking ownership."), channel); return }
            if let size = taken.size, store.ptys[id]?.resize(rows: size.rows, cols: size.cols) != true { arbiter = previousArbiter; send(.error("Size ownership was retained because the requested size could not be applied."), channel); return }
            send(.ok, channel); ownership(id)
        case let .setSurfaceSizeMode(mode):
            let previousArbiter = arbiter
            for (id, size) in arbiter.setMode(mode) {
                guard store.ptys[id]?.resize(rows: size.rows, cols: size.cols) == true else {
                    arbiter = previousArbiter
                    send(.error("Size mode change could not be completed; previous voting rules remain. Some panes may already have resized. Inspect their current sizes."), channel); return
                }
                ownership(id)
            }
            forward(raw, frontend)
        default: forward(raw, frontend)
        }
    }
    private func subscribe(_ id: String, label: String?, readOnly: Bool, frontend: Frontend) {
        guard let pty = store.ptys[id] else { send(.error("Surface not found."), frontend.channel); return }
        frontend.readOnly = readOnly; frontend.label = label ?? frontend.label
        if let old = frontend.tokens[id] { pty.cancelSubscription(token: old) }
        let token = pty.subscribe { [weak frontend] data, sequence in frontend?.output(data, sequence: sequence) }
        frontend.tokens[id] = token; send(.ok, frontend.channel)
    }
    private func attachStream(_ attach: AttachRequest, _ frontend: Frontend) {
        guard let pty = store.ptys[attach.surfaceID] else { send(.error("Surface not found."), frontend.channel); return }
        frontend.readOnly = attach.readOnly; frontend.inputErrors = attach.inputErrors == true; frontend.stream = true
        frontend.label = attach.label ?? frontend.label
        frontend.beginAttach()
        if let old = frontend.tokens[attach.surfaceID] { pty.cancelSubscription(token: old) }
        frontend.tokens[attach.surfaceID] = pty.subscribe(onResize: attach.geometryEvents == true ? { [weak frontend] size in frontend?.resize(size) } : nil) { [weak frontend] data, sequence in frontend?.output(data, sequence: sequence) }
        let history = pty.attachHistory(history: attach.history, fromSequence: attach.epoch == store.epoch ? attach.fromSequence : nil, screenOnResync: attach.screenOnResync == true, includeCheckpoint: attach.checkpoint == true)
        if attach.checkpoint == true, history.resync, history.screen?.checkpoint == nil { send(.error("Terminal checkpoint unavailable or exceeds its transfer budget."), frontend.channel); detach(frontend); return }
        let reply = AttachReply(epoch: store.epoch, resync: history.resync, endSequence: history.endSequence, screen: attach.checkpoint == true ? nil : history.screen?.vt, inputErrors: attach.inputErrors, replaySizes: history.replaySizes, checkpoint: history.screen?.checkpoint)
        frontend.finishAttach(reply: reply, chunks: history.chunks)
        ownership(attach.surfaceID)
    }
    private func ownership(_ id: String) {
        for frontend in frontends.values where frontend.stream && frontend.tokens[id] != nil {
            if let size = store.ptys[id]?.currentSize() {
                let value = SizeOwnership(surfaceID: id, owner: arbiter.mode == .smallest || arbiter.owner(of: id) == frontend.channel.fd, rows: UInt16(size.rows), cols: UInt16(size.cols), mode: arbiter.mode, clientID: frontend.id, responder: arbiter.responder(of: id) == frontend.channel.fd)
                send(.sizeOwnership(value), frontend.channel)
            }
        }
    }
    private func applyDisconnectedSize(_ size: SurfaceSize?, surface: String) -> Bool {
        guard let size, let pty = store.ptys[surface] else { return true }
        return pty.resize(rows: size.rows, cols: size.cols)
    }

    private func detach(_ frontend: Frontend) {
        // Votes belong to the connection, not its output subscriptions. A startup
        // resize RPC can vote without subscribing; leaving that vote behind pins
        // every later window to the disconnected client's smaller dimensions.
        let affected = arbiter.surfaces(for: frontend.channel.fd).union(frontend.tokens.keys)
        for (id, token) in frontend.tokens { store.ptys[id]?.cancelSubscription(token: token) }
        let sizes = arbiter.disconnect(client: frontend.channel.fd)
        for id in affected {
            if !applyDisconnectedSize(sizes[id], surface: id) {
                for client in frontends.values where client !== frontend && client.tokens[id] != nil {
                    send(.error("The remaining pane size could not be applied after another client disconnected. Resize the pane to retry."), client.channel)
                }
            }
            ownership(id)
        }
        frontend.tokens.removeAll(); frontend.worker?.closeChannel(); frontend.worker = nil
    }
    private func forward(_ frame: Data, _ frontend: Frontend) {
        guard let active else { send(.error("Application daemon is unavailable. Shells and terminal streams remain running."), frontend.channel); return }
        if frontend.worker == nil {
            do {
                let worker = SessionHostChannel(fd: try EndpointConnector.connect(.unix(path: active.socket)))
                frontend.worker = worker
                worker.start(onFrame: { [weak frontend] frame in frontend?.channel.send(frame) }, onEnd: { [weak frontend, weak worker] in
                    guard let frontend, let worker else { return }; self.store.queue.async {
                        guard frontend.worker === worker else { return }
                        frontend.worker = nil
                        if frontend.tokens.isEmpty { frontend.channel.closeChannel() }
                        else { self.send(.error("Application daemon was replaced; terminal stream remains attached."), frontend.channel) }
                    }
                })
            } catch { send(.error("Application daemon is unavailable. Work remains running."), frontend.channel); return }
        }
        frontend.worker?.send(frame)
    }
    private func send(_ response: IPCResponse, _ channel: SessionHostChannel) { if let frame = try? IPCCodec.encode(IPCReply(response: response)) { channel.send(frame) } }
    private func continueShutdownWhenRetired() {
        // Called on the owner queue after child/pipe retirement, including a
        // kernel exit observed after the initial bounded shutdown attempt.
        guard stopping, !shutdownRetryScheduled, store.ptys.isEmpty, store.pendingRetirementCount == 0, store.livePipeCount == 0 else { return }
        shutdownRetryScheduled = true
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            if stop() { onShutdown?() }
            else { store.queue.async { self.shutdownRetryScheduled = false } }
        }
    }
    @discardableResult
    public func stop() -> Bool {
        let workers = store.queue.sync { () -> [Worker] in
            stopping = true
            var workers = unretired
            if let active { workers[active.generation] = active }
            if let lastCompatible { workers[lastCompatible.generation] = lastCompatible }
            self.active = nil; store.activeGeneration = nil
            historyMaintenance?.cancel(); historyMaintenance = nil
            for pty in store.ptys.values { pty.flushScrollback(); pty.close() }
            store.stopOwnedPipes()
            for frontend in frontends.values { frontend.channel.closeChannel() }
            for channel in ownerChannels.values { channel.closeChannel() }
            return Array(workers.values)
        }
        // Reap owned workers outside the owner queue. Their shutdown may still issue
        // host requests; closing the listener does not itself prove child exit.
        ownerListener.stop()
        var survivors: [UUID: Worker] = [:]
        for worker in workers {
            do { try retire(worker) }
            catch { survivors[worker.generation] = worker; fputs("HarnessSessionHost: child retirement incomplete: \(error.localizedDescription)\n", harnessStderr) }
        }
        let survivorsSnapshot = survivors
        store.queue.sync {
            unretired = survivorsSnapshot
            if !survivorsSnapshot.isEmpty, shutdownWorkerRetry == nil {
                let timer = DispatchSource.makeTimerSource(queue: store.queue)
                timer.schedule(deadline: .now() + 5, repeating: 10)
                timer.setEventHandler { [weak self] in self?.continueShutdownWhenRetired() }
                shutdownWorkerRetry = timer; timer.resume()
            } else if survivorsSnapshot.isEmpty { shutdownWorkerRetry?.cancel(); shutdownWorkerRetry = nil }
        }
        guard store.waitForOwnedChildren(timeout: 4), survivors.isEmpty else {
            fputs("HarnessSessionHost: shutdown is waiting for owned child retirement; exclusive ownership is retained.\n", harnessStderr)
            return false
        }
        publicListener.stop(); return true
    }
}

private final class Frontend: @unchecked Sendable {
    let channel: SessionHostChannel, id = UUID(), connectedAt = Date()
    var label = "client", kind = "client", version = "", tunnel = false
    var readOnly = false, inputErrors = false, stream = false
    var tokens: [String: UUID] = [:]
    var worker: SessionHostChannel?
    private let outputLock = NSLock()
    private var held: [TerminalStreamFrame]?
    private var heldBytes = 0, floor: UInt64 = 0
    init(channel: SessionHostChannel) { self.channel = channel }
    func retireWorker() { guard let prior = worker else { return }; worker = nil; prior.closeChannel(); if tokens.isEmpty { channel.closeChannel() } }
    func beginAttach() { outputLock.lock(); held = []; heldBytes = 0; outputLock.unlock() }
    func output(_ data: Data, sequence: UInt64) { deliver(.output(data, sequence)) }
    func resize(_ size: ReplaySize) { deliver(.resize(size)) }
    private func deliver(_ event: TerminalStreamFrame) {
        outputLock.lock(); defer { outputLock.unlock() }
        if held != nil {
            guard heldBytes <= (8 << 20) - event.cost, held!.count < 32768 else { channel.closeChannel(); return }
            held?.append(event); heldBytes += event.cost
        } else if event.sequence >= floor, let frame = event.wire { channel.send(frame) }
    }

    func finishAttach(reply: AttachReply, chunks: [RealPty.ScrollbackReplaySegment]) {
        outputLock.lock(); defer { outputLock.unlock() }
        if let frame = try? IPCCodec.encode(IPCReply(response: .attached(reply))) { channel.send(frame) }
        for chunk in chunks { if let frame = try? IPCCodec.encodeOutputFrame(chunk.data, sequence: chunk.sequence) { channel.send(frame) } }
        floor = reply.endSequence
        for event in held ?? [] where event.sequence >= floor { if let frame = event.wire { channel.send(frame) } }
        held = nil; heldBytes = 0
    }
}
