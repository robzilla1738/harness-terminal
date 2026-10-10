import Foundation
import HarnessCore
import HarnessTerminalEngine
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// All child ownership lives here. Its queue orders creation, accepted control operations,
/// resize records, leases, and handover; output parsing/replay retain the existing PTY locks.
final class SessionHostStore: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.harness.session-host.owner")
    static let capabilities = ["workload-stdin-v1", "workload-outcomes-v1"]
    let epoch = UUID().uuidString
    var applicationCheckpoint: Data?
    var activeGeneration: UUID?
    var generations: Set<UUID> = []
    var ptys: [String: RealPty] = [:]
    private var pipes: [String: TerminalOutputPipe] = [:]
    private var retiringPtys: [ObjectIdentifier: RealPty] = [:]
    private var retirementMonitor: DispatchSourceTimer?
    var pendingRetirementCount: Int {
        retiringPtys.values.reduce(0) { $0 + $1.ownedChildCount }
            + ptys.values.reduce(0) { $0 + max(0, $1.ownedChildCount - ($1.childIsAlive ? 1 : 0)) }
    }
    private func retainRetiring(_ pty: RealPty) {
        guard pty.ownedChildCount > 0 else { return }
        retiringPtys[ObjectIdentifier(pty)] = pty
        guard retirementMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            retiringPtys = retiringPtys.filter { $0.value.ownedChildCount > 0 }
            if retiringPtys.isEmpty { retirementMonitor?.cancel(); retirementMonitor = nil; onRetirementComplete?() }
        }
        retirementMonitor = timer; timer.resume()
    }
    func waitForOwnedChildren(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let done = queue.sync { ptys.values.allSatisfy { $0.ownedChildCount == 0 } && pendingRetirementCount == 0 && livePipeCount == 0 }
            if done { return true }
            usleep(20_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private var finishingPipes: [ObjectIdentifier: TerminalOutputPipe] = [:]
    var livePipeCount: Int { pipes.count + finishingPipes.count }
    func stopOwnedPipes() { for pipe in Array(pipes.values) + Array(finishingPipes.values) { pipe.stop() } }
    let workloads: WorkloadOutcomeStore
    let closedHistory: ClosedHistoryStore
    init(snapshotURL: URL = HarnessPaths.snapshotURL, sessionsDirectory: URL = HarnessPaths.sessionsDirectory, historyDirectory: URL = HarnessPaths.scrollbackDirectory) {
        workloads = WorkloadOutcomeStore(url: sessionsDirectory.appendingPathComponent("workload-outcomes.json"))
        let url = snapshotURL
        let protected: Set<String>
        let layoutBytes: Data?
        do { layoutBytes = try PrivateFile.read(url) }
        catch {
            closedHistory = ClosedHistoryStore(catalogURL: sessionsDirectory.appendingPathComponent("closed-history.json"), historyDirectory: historyDirectory, unavailable: "Closed-history retention is unavailable because layout ownership could not be read. Files are retained for repair. " + error.localizedDescription)
            return
        }
        if let bytes = layoutBytes {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let snapshot = (try? decoder.decode(SessionSnapshot.self, from: bytes)) ?? (try? JSONDecoder().decode(SessionSnapshot.self, from: bytes)) {
                protected = Set(snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allSurfaceIDs().map(\.uuidString) })
            } else {
                // Unknown layout ownership must not classify files as closed.
                closedHistory = ClosedHistoryStore(catalogURL: sessionsDirectory.appendingPathComponent("closed-history.json"), historyDirectory: historyDirectory, unavailable: "Closed-history retention is unavailable because layout ownership could not be decoded. Repair the layout before retrying history recovery; programs are preserved."); return
            }
        } else { protected = [] }
        closedHistory = ClosedHistoryStore(catalogURL: sessionsDirectory.appendingPathComponent("closed-history.json"), historyDirectory: historyDirectory, protectedSurfaces: protected)
    }
    var subscriptions: [ObjectIdentifier: (String, UUID, SessionHostChannel)] = [:]
    private struct RetryWindow {
        var highWater: UInt64 = 0
        var results: [UInt64: (sequence: UInt64, id: UUID, result: SessionHostResult)] = [:]
        var floor: UInt64 { highWater > 4096 ? highWater - 4096 : 0 }
    }
    private var results: [UUID: RetryWindow] = [:]
    private let requestSlots = DispatchSemaphore(value: 256)
    private let querySlots = DispatchSemaphore(value: 4)
    private let queryQueue = DispatchQueue(label: "com.harness.session-host.queries", qos: .userInitiated, attributes: .concurrent)
    private var exited: [String: (status: Int32?, at: Date)] = [:]
    var onSurfaceExit: ((String, Int32?) -> Void)?
    var onRetirementComplete: (() -> Void)?
    func handle(_ request: SessionHostRequest, channel: SessionHostChannel) {
        guard requestSlots.wait(timeout: .now()) == .success else { channel.closeChannel(); return }
        queue.async { [self] in
            var transferred = false
            defer { if !transferred { requestSlots.signal() } }
            guard request.version == SessionHostRequest.protocolVersion, generations.contains(request.generation) else {
                reply(.error("Session host protocol or daemon generation is not authorized."), channel); return
            }
            if request.operation.mutation, request.generation != activeGeneration {
                reply(.error("This daemon does not hold the active mutation lease. Work remains running."), channel); return
            }
            if let id = request.operation.querySurface {
                guard let pty = ptys[id] else { reply(.error("The shell has closed or this surface does not exist."), channel); return }
                guard querySlots.wait(timeout: .now()) == .success else { reply(.error("Terminal queries are busy; retry after the current captures complete."), channel); return }
                transferred = true
                queryQueue.async { [self, pty] in
                    defer { querySlots.signal(); requestSlots.signal() }
                    reply(executeQuery(request.operation, pty: pty), channel)
                }
                return
            }
            if request.operation.mutation {
                let window = results[request.generation] ?? RetryWindow()
                guard request.operationSequence > window.floor else {
                    reply(.error("This operation is outside the retained retry window; its outcome is uncertain and it will not be executed again."), channel); return
                }
                if let prior = window.results[request.operationSequence % 4096], prior.sequence == request.operationSequence {
                    reply(prior.id == request.operationID ? prior.result : .error("Operation sequence identity was reused."), channel); return
                }
            }
            let result = execute(request.operation, channel: channel)
            if request.operation.mutation {
                var window = results[request.generation] ?? RetryWindow()
                window.highWater = max(window.highWater, request.operationSequence)
                window.results[request.operationSequence % 4096] = (request.operationSequence, request.operationID, result)
                results[request.generation] = window
            }
            reply(result, channel)
        }
    }
    private func executeQuery(_ operation: HostedPtyOperation, pty: RealPty) -> SessionHostResult {
        switch operation {
        case .state: return .state(HostedPtyState(pty))
        case let .capture(_, format, trim, unwrap, screen): return .text(pty.captureFormatted(format: format, trim: trim, unwrap: unwrap, screen: screen))
        case let .captureScrollback(_, history): return .text(pty.captureScrollback(includeHistory: history))
        case let .captureGrid(_, start, end, join): return .text(pty.captureGrid(start: start, end: end, joinWrapped: join))
        case let .captureRange(_, start, end, escapes): return .text(pty.captureRange(start: start, end: end, escapeSequences: escapes))
        case .processTree: return .text(pty.processTreeJSON())
        case let .replay(_, sequence): let replay = pty.replayWithEndSequence(fromSequence: sequence); return .replay(replay.text, replay.endSequence)
        case let .history(_, history, sequence, limit, screen, checkpoint):
            return .history(pty.attachHistory(history: history, fromSequence: sequence, chunkLimit: min(max(limit, 4096), 1 << 20), screenOnResync: screen, includeCheckpoint: checkpoint))
        case .checkpoint:
            guard let checkpoint = pty.withMobileHistory({ try? $0.checkpoint() }),
                  let data = try? PropertyListEncoder().encode(checkpoint), data.count <= 8 << 20 else {
                return .error("Parser checkpoint exceeds the handover budget or is unavailable; retain the current daemon.")
            }
            return .checkpoint(data)
        case let .commandOutput(_, span, maximum):
            do { return .commandOutput(try pty.commandOutput(span: span, maximumBytes: maximum)) }
            catch { return .error(error.localizedDescription) }
        default: return .error("This operation is not a concurrent terminal query.")
        }
    }
    private func finishSurface(_ id: String, pty: RealPty?, status: Int32?) {
        if let pipe = pipes.removeValue(forKey: id) {
            if let token = pipe.token { pty?.cancelSubscription(token: token) }
            finishingPipes[ObjectIdentifier(pipe)] = pipe; pipe.finish()
        }
        if let pty { retainRetiring(pty) }
        ptys.removeValue(forKey: id)
        exited[id] = (status, .now)
        exited = exited.filter { $0.value.at >= Date().addingTimeInterval(-14 * 86400) }
        if exited.count > 500, let oldest = exited.min(by: { $0.value.at < $1.value.at })?.key { exited.removeValue(forKey: oldest) }
        let finished = subscriptions.filter { $0.value.0 == id }
        for (key, (_, token, channel)) in finished {
            pty?.cancelSubscription(token: token); subscriptions.removeValue(forKey: key)
            reply(.exited(status), channel); channel.closeAfterWrites()
        }
        onSurfaceExit?(id, status)
    }
    func forget(_ channel: SessionHostChannel) {
        queue.async { [self] in
            if let (id, token, _) = subscriptions.removeValue(forKey: ObjectIdentifier(channel)) { ptys[id]?.cancelSubscription(token: token) }
        }
    }
    func grant(_ generation: UUID) {
        activeGeneration = generation
        results = results.filter { generations.contains($0.key) }
    }
    func reply(_ result: SessionHostResult, _ channel: SessionHostChannel) {
        if case let .output(data, sequence) = result, let frame = try? IPCCodec.encodeOutputFrame(data, sequence: sequence) { channel.send(frame) }
        else if let frame = try? IPCCodec.encode(result) { channel.send(frame) }
        else if let frame = try? IPCCodec.encode(SessionHostResult.error("The requested history exceeds the bounded transfer budget.")) { channel.send(frame) }
    }
    private func changePipe(id: String, pty: RealPty, command: String?) throws {
        if let previous = pipes.removeValue(forKey: id) {
            if let token = previous.token { pty.cancelSubscription(token: token) }; finishingPipes[ObjectIdentifier(previous)] = previous; previous.finish()
        }
        guard let command, !command.isEmpty else { return }
        guard command.utf8.count <= 65536, !command.contains("\0") else { throw SessionHostError.refused("The pipe command is invalid or exceeds 64 KiB.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["--terminal-pipe-worker", command]
        let input = Pipe(); process.standardInput = input
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let pipe = try TerminalOutputPipe(process: process, stdin: input.fileHandleForWriting)
        process.terminationHandler = { [weak self, weak pipe, weak pty] _ in
            guard let self, let pipe else { return }
            self.queue.async { [self, pipe, weak pty] in
                if pipes[id] === pipe { pipes.removeValue(forKey: id) }
                finishingPipes.removeValue(forKey: ObjectIdentifier(pipe)); onRetirementComplete?()
                if let token = pipe.token { pty?.cancelSubscription(token: token) }
                pipe.stop()
            }
        }
        do { try process.run(); pipe.didStart() }
        catch { pipe.stop(); throw SessionHostError.refused("The pipe consumer could not be launched; its command was not logged.") }
        pipe.token = pty.subscribe(watching: false) { [weak self, weak pipe, weak pty] data, _ in
            guard let pipe, !pipe.feed(data), pipe.claimFailure() else { return }
            self?.queue.async { [weak self, pipe, weak pty] in
                guard let self, self.pipes[id] === pipe else { return }
                self.pipes.removeValue(forKey: id)
                if let token = pipe.token { pty?.cancelSubscription(token: token) }
                pipe.stop()
                pty?.injectSyntheticOutput(Data("\r\n[Harness: pipe consumer stopped; its bounded input queue overflowed or closed.]\r\n".utf8))
            }
        }
        if process.isRunning { pipes[id] = pipe }
        else {
            if let token = pipe.token { pty.cancelSubscription(token: token) }; pipe.stop()
            throw SessionHostError.refused("The pipe consumer exited during launch.")
        }
    }
    private func execute(_ operation: HostedPtyOperation, channel: SessionHostChannel) -> SessionHostResult {
        switch operation {
        case let .applicationCheckpoint(data):
            guard data.count <= 4 << 20, let value = try? JSONDecoder().decode(DaemonObservationCheckpoint.self, from: data), value.version == DaemonObservationCheckpoint.currentVersion else { return .error("Invalid application checkpoint.") }
            applicationCheckpoint = data; return .ok
        case .inventory: return .inventory(Array(ptys.keys).sorted())
        case .capabilities: return .capabilities(Self.capabilities)
        case let .workloadOutcome(id): return .workloadOutcome(workloads.read(id))
        case let .cancelWorkload(id):
            do {
                let receipt = try workloads.requestCancellation(id)
                guard receipt.state == .running else { return .workloadOutcome(receipt) }
                guard let pty = ptys[receipt.surfaceID], pty.streamIdentity == receipt.streamIdentity,
                      pty.processGeneration == receipt.processGeneration, pty.currentChildPID == receipt.pid,
                      let kernel = receipt.kernelIdentity, ProcessScan.generation(pty.currentChildPID) == kernel else {
                    return .error("The recorded workload no longer owns this process. No process was signaled; inspect its outcome.")
                }
                pty.close(); return .workloadOutcome(workloads.read(id))
            } catch { return .error(error.localizedDescription) }
        case let .create(launch):
            guard ptys[launch.id] == nil else { return .error("A shell already owns this surface identity.") }
            guard UUID(uuidString: launch.id) != nil, TerminalGeometry.isValid(cols: Int(launch.cols), rows: Int(launch.rows)),
                  launch.scrollbackURL == nil || launch.scrollbackURL == HarnessPaths.scrollbackFileURL(forSurfaceID: launch.id),
                  launch.initialStandardInput.map({ $0.count <= 32 << 10 && launch.launchArgumentsOverride != nil }) ?? true else {
                return .error("Invalid shell identity, dimensions, or history location.")
            }
            let retainedHistory = closedHistory.retained(launch.id)
            do {
                if let workloadID = launch.workloadID {
                    guard launch.initialStandardInput != nil else { return .error("A workload requires explicit prepared stdin.") }
                    try workloads.reserve(workloadID, surfaceID: launch.id)
                }
                let pty = try RealPty(id: launch.id, cwd: launch.cwd, shell: launch.shell, rows: launch.rows, cols: launch.cols,
                    scrollbackBytes: launch.scrollbackBytes, extraEnvironment: launch.extraEnvironment,
                    termProgram: launch.termProgram, termProgramVersion: launch.termProgramVersion,
                    scrollbackURL: launch.scrollbackURL, launchArgumentsOverride: launch.launchArgumentsOverride, initialStandardInput: launch.initialStandardInput, retainedHistory: retainedHistory)
                closedHistory.adopted(launch.id)
                ptys[launch.id] = pty; exited.removeValue(forKey: launch.id)
                pty.onExit = { [weak self, weak pty] status in
                    guard let self else { return }
                    self.queue.async { [weak self, weak pty] in
                        guard let self, self.ptys[launch.id] === pty else { return }
                        self.closedHistory.retain(pty?.retainedHistory, surfaceID: launch.id)
                        self.finishSurface(launch.id, pty: pty, status: status)
                    }
                }
                if let workloadID = launch.workloadID {
                    let stream = pty.streamIdentity
                    pty.onReaped = { [weak self] generation, status in
                        self?.queue.async { [weak self] in self?.workloads.reaped(workloadID, stream: stream, generation: generation, status: status) }
                    }
                    workloads.launched(workloadID, pty: pty)
                    // Prepared workloads run once even if the requesting daemon
                    // disconnects before wiring its terminal observation.
                    pty.start()
                }
                return .state(HostedPtyState(pty))
            } catch {
                if let workloadID = launch.workloadID { workloads.launchFailed(workloadID) }
                return .error("Shell creation failed: \(error.localizedDescription)")
            }
        case let .adopt(id): return ptys[id].map { .state(HostedPtyState($0)) } ?? .ok
        default: break
        }
        let id: String
        switch operation {
        case let .adopt(value), let .state(value), let .start(value), let .close(value), let .clear(value),
             let .flush(value), let .deleteHistory(value), let .warm(value), let .processTree(value), let .checkpoint(value): id = value
        case let .pipe(value, _), let .input(value, _), let .inject(value, _), let .persist(value, _), let .budget(value, _),
             let .replay(value, _), let .captureScrollback(value, _), let .subscribe(value, _): id = value
        case let .resize(value, _, _), let .respawn(value, _, _), let .park(value, _, _): id = value
        case let .insertResume(value, _, _), let .automaticResume(value, _, _): id = value
        case let .commandOutput(value, _, _): id = value
        case let .insertExplanation(value, _, _, _): id = value
        case let .captureGrid(value, _, _, _), let .captureRange(value, _, _, _): id = value
        case let .capture(value, _, _, _, _): id = value
        case let .history(value, _, _, _, _, _): id = value
        case .applicationCheckpoint, .inventory, .create, .workloadOutcome, .cancelWorkload, .capabilities: return .error("Invalid operation")
        }
        guard let pty = ptys[id] else {
            if case .persist(_, false) = operation {
                guard UUID(uuidString: id) != nil else { return .error("Invalid history identity.") }
                closedHistory.purge(id)
                let history = HarnessPaths.scrollbackFileURL(forSurfaceID: id)
                do {
                    for file in [history, history.appendingPathExtension("sizes"), history.deletingLastPathComponent().appendingPathComponent(id + ".park")] {
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                    return .ok
                } catch { return .error("Closed history could not be removed: " + error.localizedDescription) }
            }
            if case .subscribe = operation, let notice = exited[id] { return .exited(notice.status) }
            return .error("The shell has closed or this surface does not exist.")
        }
        switch operation {
        case .state, .capture, .captureScrollback, .captureGrid, .captureRange, .processTree, .replay, .history, .checkpoint, .commandOutput:
            return .error("Terminal queries must run on their bounded worker queue.")
        case .start: pty.start()
        case let .input(_, data):
            guard !pty.usesPreparedStandardInput else { return .error("This workload consumes its prepared stdin only. Open a fresh shell or a resumed interactive agent to send input.") }
            return pty.write(data) ? .ok : .error("The pane input queue is full or closed; input was not accepted.")
        case let .automaticResume(_, command, identity):
            do { try pty.insertResume(command, expectedIdentity: identity, submit: true) }
            catch { return .error(error.localizedDescription) }
        case let .insertResume(_, command, identity):
            do { try pty.insertResume(command, expectedIdentity: identity) }
            catch { return .error(error.localizedDescription) }
        case let .insertExplanation(_, text, pid, generation):
            do { try pty.insertExplanation(text, agentPID: pid, agentGeneration: generation) }
            catch { return .error(error.localizedDescription) }
        case let .inject(_, data): pty.injectSyntheticOutput(data)
        case let .resize(_, rows, cols):
            guard TerminalGeometry.isValid(cols: Int(cols), rows: Int(rows)) else { return .error("Invalid terminal dimensions.") }
            guard pty.resize(rows: rows, cols: cols) else { return .error("Resize could not be confirmed within the bounded input queue. Inspect the current size before retrying; shells remain running.") }
        case let .pipe(_, command):
            do { try changePipe(id: id, pty: pty, command: command) }
            catch { return .error(error.localizedDescription) }
        case .close:
            // The PTY remains owned until its ordered exit callback has delivered
            // the cancellation drain. Closing subscriptions here would discard tail bytes.
            pty.close()
        case let .respawn(_, clear, cwd):
            guard pty.ownedChildCount < 64 else { return .error("This pane has too many child processes still retiring from earlier respawns. Its current process was preserved; wait for retirement before retrying.") }
            guard !pty.usesPreparedStandardInput else { return .error("This pane owns a prepared one-shot workload. Its process was preserved; start a new workload or open a fresh shell to run another command.") }
            guard pty.respawn(clearHistory: clear, fallbackCwd: cwd) else { return .error("The previous shell was stopped, but its replacement could not be launched. Inspect the pane and choose a valid shell before retrying.") }
            return .state(HostedPtyState(pty))
        case .clear: pty.clearScrollback(); pty.injectSyntheticOutput(Data("\u{1b}[3J".utf8))
        case let .persist(_, enabled): pty.setScrollbackPersistence(enabled: enabled)
        case .flush: pty.flushScrollback()
        case .deleteHistory: pty.deletePersistedScrollback()
        case let .budget(_, bytes): pty.setScrollbackBytes(bytes)
        case let .park(_, now, threshold): pty.parkIfIdle(now: now, threshold: threshold)
        case .warm: pty.warmScreen()
        case let .subscribe(_, watching):
            let key = ObjectIdentifier(channel)
            if let (oldID, token, _) = subscriptions.removeValue(forKey: key) { ptys[oldID]?.cancelSubscription(token: token) }
            let token = pty.subscribe(watching: watching) { [weak self, weak channel] data, sequence in
                guard let self, let channel else { return }; self.reply(.output(data, sequence), channel)
            }
            subscriptions[key] = (id, token, channel)
        case .applicationCheckpoint, .inventory, .adopt, .create, .workloadOutcome, .cancelWorkload, .capabilities: break
        }
        return .ok
    }
}
