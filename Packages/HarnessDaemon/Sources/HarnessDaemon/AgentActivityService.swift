import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Interpretation belongs to the replaceable daemon. The PTY owner supplies stable
/// process generations and terminal sequence anchors without owning provider state.
final class AgentActivityService: @unchecked Sendable {
    let store: ActivityStore
    let hostID: UUID
    private let queue = DispatchQueue(label: "com.harness.agent-activity")
    private let repositoryQueue = DispatchQueue(label: "com.harness.activity-repositories", qos: .utility)
    private let repositorySlots = DispatchSemaphore(value: 64)
    private var identifyingRepositories: Set<UUID> = []
    private let slots = DispatchSemaphore(value: 512)
    private var active: [UUID: AgentRun] = [:]
    private var accepting: Bool
    let hostIdentityFailure: String?
    private var failure: String?
    private let projectionLock = NSLock()
    private var projection: [String: AgentRun] = [:]
    private var overflowReported = false
    private var lastPrune = Date()
    private var processMonitor: DispatchSourceTimer?
    private var processCursor: UUID?
    private var privateSurfaces: Set<String> = []
    var onTranscript: (@Sendable (AgentRun, String) -> Void)?
    var onChange: (@Sendable (AgentRun) -> Void)?
    init(store: ActivityStore? = nil, warm: Bool = false, hostID: UUID? = nil) {
        self.store = store ?? ActivityStore(writable: !warm)
        let identity: (UUID, String?) = hostID.map { ($0, nil) } ?? Self.loadHostID()
        self.hostID = identity.0; hostIdentityFailure = identity.1
        accepting = !warm && hostIdentityFailure == nil
        do { try reloadActive() } catch { failure = error.localizedDescription }
        if !warm { do { try self.store.prune() } catch { failure = error.localizedDescription } }
        queue.sync { startProcessMonitor() }
    }
    private static func loadHostID() -> (UUID, String?) {
        func failed() -> (UUID, String?) {
            (UUID(), "Stable host identity could not be loaded or saved. Durable activity capture is disabled; existing programs remain running. Repair the owned host-id file, then replace the application daemon.")
        }
        let directory = HarnessPaths.applicationSupport
        let url = directory.appendingPathComponent("host-id")
        let lockFD = open(directory.appendingPathComponent("host-id.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { return failed() }; defer { close(lockFD) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              fchmod(lockFD, 0o600) == 0, flock(lockFD, LOCK_EX) == 0 else { return failed() }
        defer { _ = flock(lockFD, LOCK_UN) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 {
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  fchmod(fd, 0o600) == 0 else { return failed() }
            if info.st_size == 36 {
                var bytes = [UInt8](repeating: 0, count: 36)
                guard read(fd, &bytes, bytes.count) == bytes.count, let id = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else { return failed() }
                return (id, nil)
            }
            guard info.st_size == 0 else { return failed() }
        } else if errno != ENOENT { return failed() }
        let id = UUID(), data = Data(id.uuidString.utf8)
        let stage = directory.appendingPathComponent(".host-id-" + UUID().uuidString)
        let stagedFD = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard stagedFD >= 0 else { return failed() }
        defer { close(stagedFD); _ = unlink(stage.path) }
        guard data.withUnsafeBytes({ write(stagedFD, $0.baseAddress, $0.count) }) == data.count,
              fsync(stagedFD) == 0, rename(stage.path, url.path) == 0 else { return failed() }
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { return failed() }; defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { return failed() }
        return (id, nil)
    }

    private func reloadActive() throws {
        var offset = 0
        active.removeAll()
        repeat {
            let page = try store.list(activeOnly: true, offset: offset, limit: 500)
            for run in page.runs { active[run.id] = run }
            guard let next = page.nextOffset else { break }; offset = next
        } while true
        privateSurfaces = []
        for run in active.values {
            if try store.object(Bool.self, kind: "capture-policy", id: run.surfaceID) == true { privateSurfaces.insert(run.surfaceID) }
        }
        projectionLock.lock()
        projection.removeAll()
        for run in active.values.filter({ $0.parentRunID == nil }).sorted(by: { $0.startedAt < $1.startedAt }) { projection[run.surfaceID] = run }
        projectionLock.unlock()
    }
    func workingProcesses() -> [(pid: Int32, generation: String)] {
        queue.sync { active.values.compactMap { run in
            guard run.process == .running, run.turn == .working, run.parentRunID == nil, let pid = run.pid else { return nil }
            return (pid, run.processGeneration)
        } }
    }
    func observe(surfaceID: String, paneID: String?, snapshot: AgentSnapshot?, at: Date = .now, persistence: Bool = true) {
        let generation = snapshot.flatMap { ProcessScan.generation($0.pid) }
        guard slots.wait(timeout: .now()) == .success else { markOverflow(); return }
        queue.async { [self] in
            defer { slots.signal() }
            guard accepting else { return }
            do {
                if !persistence {
                    privateSurfaces.insert(surfaceID)
                    if try store.object(Bool.self, kind: "capture-policy", id: surfaceID) != true {
                        try store.saveObjects([LedgerObject(kind: "capture-policy", id: surfaceID, value: true)])
                        try store.removeCapturedText(surfaceID: surfaceID)
                    }
                }
                if at.timeIntervalSince(lastPrune) >= 3600 { try store.prune(now: at); lastPrune = at }
                if let snapshot, let generation {
                    let existing = active.values.first { $0.surfaceID == surfaceID && $0.provider == snapshot.kind && $0.processGeneration == generation && $0.parentRunID == nil }
                    var run = existing ?? AgentRun(hostID: hostID, surfaceID: surfaceID, paneID: paneID,
                        processGeneration: generation, pid: snapshot.pid, provider: snapshot.kind, at: at)
                    if !privateSurfaces.contains(surfaceID), run.directory == nil, let directory = ProcessScan.workingDirectory(snapshot.pid) {
                        run.directory = directory; run.directorySource = .process
                    }
                    if existing == nil { try store.save(run) }
                    do {
                        let kind: RunEventKind = run.source == .process && snapshot.activity == .working && run.turn != .working ? .turnStarted : .processObserved
                        // A heuristic observation is retained as freshness, not invented
                        // turn completion when output goes quiet.
                        let event = RunEvent(runID: run.id, kind: kind, source: .process, at: at)
                        try record(event, reducing: &run)
                    }
                    active[run.id] = run
                    identifyRepository(run)
                    if existing == nil || existing?.turn != run.turn || existing?.attention != run.attention { publish(run) }
                }
                for prior in Array(active.values) where prior.surfaceID == surfaceID && prior.parentRunID == nil {
                    try reconcileProcess(prior, at: at)
                }
            } catch { failure = error.localizedDescription }
        }
    }
    func registerLaunch(id: UUID, surfaceID: String, paneID: String, pid: Int32, generation: String, provider: AgentKind, specification: AgentLaunchSpecification, startedAt: Date, outcome: WorkloadOutcome? = nil) throws {
        try queue.sync {
            guard accepting else { throw LedgerError.noLease }
            if let existing = try store.run(id) {
                guard existing.surfaceID == surfaceID, existing.processGeneration == generation else { throw FanoutError.identity }; return
            }
            var run = AgentRun(hostID: hostID, surfaceID: surfaceID, paneID: paneID, processGeneration: generation, pid: pid, provider: provider, profile: specification.profile, at: startedAt)
            run.id = id; run.profileSource = .launch; run.directory = specification.directory; run.directorySource = .launch; run.launch = specification
            try record(RunEvent(runID: id, kind: .turnStarted, source: .launch), reducing: &run)
            if let outcome, outcome.state == .exited {
                try record(RunEvent(runID: id, kind: .processExited, source: .exit, at: max(run.observedAt, outcome.observedAt), exitCode: outcome.exitCode), reducing: &run)
            } else { active[id] = run }
            publish(run)
        }
    }
    func report(_ report: HookReport, paneID: String?, generation: String, pid: Int32, sequence: UInt64, streamIdentity: String? = nil, launch: AgentLaunchSpecification? = nil) throws -> AgentRun {
        guard slots.wait(timeout: .now()) == .success else { throw LedgerError.limit }
        defer { slots.signal() }
        return try queue.sync {
            guard accepting else { throw LedgerError.noLease }
            let observation = report.observation
            if try store.object(Bool.self, kind: "capture-policy", id: report.surfaceID) == true { privateSurfaces.insert(report.surfaceID) }
            let candidates = active.values.filter { $0.surfaceID == report.surfaceID && $0.provider == observation.contract.provider && $0.processGeneration == generation && $0.parentRunID == nil }
            let isPrivate = privateSurfaces.contains(report.surfaceID)
            let existing = isPrivate ? candidates.min { $0.startedAt < $1.startedAt }
                : (candidates.first { $0.profile == report.profile } ?? candidates.first { ($0.profileSource == nil || $0.profileSource == .launch) && ($0.profile == "default" || $0.profile == "private") })
            if !isPrivate, existing == nil, candidates.contains(where: { $0.profileSource == .hook || $0.profileSource == .launch }) {
                throw SessionHostError.refused("This provider process already has a different authoritative profile. Correct the hook profile or start a new provider execution; the existing run identity was preserved.")
            }
            var run = existing ?? AgentRun(hostID: hostID, surfaceID: report.surfaceID, paneID: paneID,
                processGeneration: generation, pid: pid, provider: observation.contract.provider, profile: report.profile, at: observation.reportedAt)
            run.profile = privateSurfaces.contains(report.surfaceID) ? "private" : report.profile
            run.profileSource = .hook
            if !privateSurfaces.contains(report.surfaceID) {
                if run.launch == nil { run.launch = launch }
                if let directory = launch?.directory ?? observation.directory, directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4096,
                   run.directory == nil || run.directorySource == .process {
                    if run.directory != directory { run.repository = nil; run.repositoryUnavailable = nil }
                    run.directory = directory; run.directorySource = .hook
                }
            }
            if !privateSurfaces.contains(report.surfaceID), let conversation = observation.conversationID { run.conversationID = conversation }
            try store.save(run)
            if let subagent = observation.subagentID, observation.kind == .subagentStarted || observation.kind == .subagentCompleted {
                let childGeneration = generation + ":subagent:" + subagent
                var child = try active.values.first { $0.parentRunID == run.id && $0.processGeneration == childGeneration }
                    ?? store.execution(surfaceID: report.surfaceID, generation: childGeneration, parentID: run.id)
                    ?? AgentRun(hostID: hostID, surfaceID: report.surfaceID, paneID: paneID, processGeneration: generation + ":subagent:" + subagent, pid: nil, provider: run.provider, profile: report.profile, at: observation.reportedAt)
                child.parentRunID = run.id
                if !privateSurfaces.contains(report.surfaceID) { child.conversationID = observation.conversationID }
                else { child.conversationID = nil; child.profile = "private" }
                child.process = .unknown
                if observation.kind == .subagentCompleted { child.endedAt = observation.reportedAt; child.turn = .completed }
                try store.save(child)
                if child.endedAt == nil { active[child.id] = child } else { active.removeValue(forKey: child.id) }
            }
            let event = RunEvent(runID: run.id, kind: observation.kind, source: .hook, at: observation.reportedAt,
                providerEventID: observation.eventID, conversationID: observation.conversationID, turnID: observation.turnID, toolID: observation.toolID,
                toolName: observation.toolName, message: observation.message, terminalSequence: sequence, streamIdentity: streamIdentity)
            try record(event, reducing: &run)
            active[run.id] = run; publish(run)
            if !privateSurfaces.contains(run.surfaceID), let path = observation.transcriptPath { onTranscript?(run, path) }
            return run
        }
    }
    func observeOSC(surfaceID: String, state: String, message: String?, sequence: UInt64?, streamIdentity: String? = nil) {
        guard slots.wait(timeout: .now()) == .success else { markOverflow(); return }
        queue.async { [self] in
            defer { slots.signal() }
            guard accepting, var run = active.values.filter({ $0.surfaceID == surfaceID && $0.parentRunID == nil }).max(by: { $0.startedAt < $1.startedAt }) else { return }
            let kind: RunEventKind
            switch state {
            case "working": kind = .turnStarted
            case "done": kind = .turnCompleted
            case "blocked": kind = .attention
            case "error": kind = .turnFailed
            default: return
            }
            do {
                try record(RunEvent(runID: run.id, kind: kind, source: .osc, message: message, terminalSequence: sequence, streamIdentity: streamIdentity), reducing: &run)
                active[run.id] = run; publish(run)
            } catch { failure = error.localizedDescription }
        }
    }
    func recordCommand(_ span: ShellCommandSpan) {
        guard slots.wait(timeout: .now()) == .success else { markOverflow(); return }
        queue.async { [self] in
            defer { slots.signal() }
            guard accepting, span.endSequence != nil else { return }
            do {
                guard try store.object(Bool.self, kind: "capture-policy", id: span.surfaceID) != true else { return }
                try store.saveObjects([LedgerObject(kind: "shell-command", id: span.surfaceID, value: span)])
            } catch { failure = error.localizedDescription }
        }
    }
    /// Serialized with hook capture: a completed opt-out has purged old text and
    /// blocks future capture even while the program continues running.
    func setPersistence(surfaceID: String, enabled: Bool) throws {
        try queue.sync {
            try store.saveObjects([LedgerObject(kind: "capture-policy", id: surfaceID, value: !enabled)])
            if enabled { privateSurfaces.remove(surfaceID); return }
            privateSurfaces.insert(surfaceID)
            try store.removeCapturedText(surfaceID: surfaceID)
            for id in active.keys where active[id]?.surfaceID == surfaceID {
                guard var run = active[id] else { continue }
                run.message = nil; run.launch = nil; run.conversationID = nil; run.profile = "private"
                run.directory = nil; run.directorySource = nil; run.repository = nil; run.repositoryUnavailable = nil
                active[id] = run; publish(run)
            }
        }
    }
    func permitsCapture(surfaceID: String) -> Bool { queue.sync { !privateSurfaces.contains(surfaceID) } }
    private func record(_ event: RunEvent, reducing run: inout AgentRun) throws {
        if event.kind == .processObserved {
            AgentRunReducer.apply(event, to: &run); try store.save(run); return
        }
        if privateSurfaces.contains(run.surfaceID) {
            var structural = event; structural.message = nil; structural.turnID = nil
            AgentRunReducer.apply(structural, to: &run)
            run.message = nil; run.launch = nil; run.conversationID = nil; run.profile = "private"
            run.directory = nil; run.directorySource = nil; run.repository = nil; run.repositoryUnavailable = nil
            try store.save(run)
        } else { _ = try store.record(event, reducing: &run) }
    }
    func drain() { queue.sync {} }
    func suspend() throws { try queue.sync { accepting = false; processMonitor?.cancel(); processMonitor = nil; try store.suspend() } }
    func activate(memoryCheckpoint: ActivityMemoryCheckpoint? = nil) throws {
        try queue.sync {
            if let hostIdentityFailure { throw SessionHostError.refused(hostIdentityFailure) }
            try store.activate()
            if let memoryCheckpoint { try store.restoreMemory(memoryCheckpoint) }
            if store.protectionKind != .keyUnavailable { try store.recoverConfiguredProtection() }
            try store.prune(); try reloadActive(); accepting = true
            for run in active.values { identifyRepository(run) }
            startProcessMonitor()
        }
    }
    func recoverHistory(protection: HistoryProtection) throws {
        try queue.sync {
            guard accepting else { throw LedgerError.noLease }
            try store.recover(protection: protection)
            try reloadActive(); failure = nil
        }
    }
    func checkpoint() throws -> ActivityMemoryCheckpoint? { try queue.sync { try store.memoryCheckpoint() } }
    func flush() throws { try queue.sync { try store.flush() } }
    func unavailable() -> String? { queue.sync { hostIdentityFailure ?? failure ?? store.availability } }
    func currentRun(surfaceID: String) -> AgentRun? {
        projectionLock.lock(); defer { projectionLock.unlock() }; return projection[surfaceID]
    }
    private func publish(_ run: AgentRun) {
        identifyRepository(run)
        projectionLock.lock()
        if run.process == .exited {
            if projection[run.surfaceID]?.id == run.id { projection.removeValue(forKey: run.surfaceID) }
        } else { projection[run.surfaceID] = run }
        projectionLock.unlock()
        onChange?(run)
    }
    private func identifyRepository(_ run: AgentRun) {
        guard accepting, !privateSurfaces.contains(run.surfaceID), let directory = run.directory,
              run.repository == nil, run.repositoryUnavailable == nil, !identifyingRepositories.contains(run.id) else { return }
        guard repositorySlots.wait(timeout: .now()) == .success else {
            failure = "Repository identification reached its bounded queue; some executions have unknown repository identity."
            return
        }
        identifyingRepositories.insert(run.id)
        repositoryQueue.async { [self] in
            let result: Result<GitRepository, Error>
            do { result = .success(try HarnessGit.repository(at: directory, cancelled: { self.queue.sync { !self.accepting } })) }
            catch { result = .failure(error) }
            queue.async { [self] in
                defer { identifyingRepositories.remove(run.id); repositorySlots.signal() }
                guard accepting, !privateSurfaces.contains(run.surfaceID), var current = try? store.run(run.id), current.directory == directory else { return }
                switch result {
                case let .success(repository): current.repository = repository; current.repositoryUnavailable = nil
                case .failure: current.repositoryUnavailable = "No verified Git repository identity was available for this recorded directory."
                }
                do {
                    try store.save(current)
                    if active[current.id] != nil { active[current.id] = current }
                    publish(current)
                } catch { failure = error.localizedDescription }
            }
        }
    }
    /// Pane closure or root deregistration cannot abandon a live execution's
    /// lifetime. Inspect a bounded rotating batch, independently of pane polling.
    private func startProcessMonitor() {
        guard accepting, processMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, accepting else { return }
            if Date().timeIntervalSince(lastPrune) >= 3600 {
                do { try store.prune(); lastPrune = .now } catch { failure = error.localizedDescription }
            }
            let executions = active.values.filter { $0.parentRunID == nil && $0.pid != nil }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let start = processCursor.flatMap { cursor in executions.firstIndex { $0.id.uuidString > cursor.uuidString } } ?? 0
            let batch = executions.dropFirst(start).prefix(256)
            do { for run in batch { try reconcileProcess(run, at: .now) } }
            catch { failure = error.localizedDescription }
            processCursor = batch.last?.id
            if start + batch.count >= executions.count { processCursor = nil }
        }
        processMonitor = timer; timer.resume()
    }
    private func reconcileProcess(_ prior: AgentRun, at: Date) throws {
        guard let pid = prior.pid, active[prior.id] != nil else { return }
        if let current = ProcessScan.generation(pid) {
            guard current != prior.processGeneration else { return }
        } else {
            // Inspection denial is unknown; only ESRCH proves disappearance.
            guard kill(pid, 0) != 0 && errno == ESRCH else { return }
        }
        var run = prior
        try record(RunEvent(runID: run.id, kind: .processExited, source: .exit, at: max(at, run.observedAt)), reducing: &run)
        active.removeValue(forKey: run.id); publish(run)
        // The parent's end does not invent a reported subagent outcome. Its
        // unreported children are closed with unknown process/turn state.
        for var child in Array(active.values) where child.parentRunID == run.id {
            child.process = .unknown; child.turn = .unknown; child.endedAt = run.endedAt
            try store.save(child); active.removeValue(forKey: child.id)
        }
    }
    deinit { processMonitor?.cancel() }
    private func markOverflow() {
        projectionLock.lock(); let report = !overflowReported; overflowReported = true; projectionLock.unlock()
        if report { queue.async { [weak self] in self?.failure = "Activity capture reached its bounded queue; some observations were not captured." } }
    }
}
