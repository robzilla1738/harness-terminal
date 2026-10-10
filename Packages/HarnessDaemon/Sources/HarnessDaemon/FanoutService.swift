import Foundation
import HarnessCore

/// The ledger owns intent; the session host owns every launched process. Calls are
/// accepted/drained by SurfaceRegistry. State writes are serialized separately from
/// Git and host requests, so cancellation can interrupt an in-progress launch batch.
final class FanoutService: @unchecked Sendable {
    typealias Launch = @Sendable (FanoutGroup, FanoutParticipant, AgentLaunchSpecification, Data) throws -> WorkloadOutcome?
    private let queue = DispatchQueue(label: "com.harness.fanout-state")
    private let store: ActivityStore
    private let hostID: UUID
    private let worktrees: WorktreeService
    private let host: SessionHostClient?
    private let launch: Launch
    private let workspace: @Sendable (UUID?) throws -> UUID
    private var starting: Set<UUID> = []
    private let monitorQueue = DispatchQueue(label: "com.harness.fanout-outcomes", qos: .utility)
    private var monitor: DispatchSourceTimer?
    private var monitorOffset = 0
    private let observeOwned: @Sendable (@Sendable () -> Void) -> Void
    init(store: ActivityStore, hostID: UUID, worktrees: WorktreeService, host: SessionHostClient? = .configured,
         workspace: @escaping @Sendable (UUID?) throws -> UUID, observeOwned: @escaping @Sendable (@Sendable () -> Void) -> Void = { $0() }, launch: @escaping Launch) {
        self.store = store; self.hostID = hostID; self.worktrees = worktrees; self.host = host; self.workspace = workspace; self.launch = launch; self.observeOwned = observeOwned
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.observeOwned { [weak self] in self?.refreshOutcomes() } }
        monitor = timer; timer.resume()
    }
    deinit { monitor?.cancel() }
    private func refreshOutcomes() {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        do {
            let ids = try store.objectPage(UUID.self, kind: "fanout-active", offset: 0, limit: 129).sorted { $0.uuidString < $1.uuidString }
            let page = ids.dropFirst(monitorOffset).prefix(4)
            monitorOffset = monitorOffset + page.count >= ids.count ? 0 : monitorOffset + page.count
            for id in page {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                _ = try inspect(id, cancelled: { ProcessInfo.processInfo.systemUptime >= deadline })
            }
        } catch { /* Preserve last observations; explicit Inspect reports recovery errors. */ }
    }
    func handle(_ operation: FanoutOperation, cancelled: @escaping () -> Bool) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        switch operation {
        case let .start(id, directory, base, workspaceID, prompt, providers, managed):
            return try encoder.encode(start(id: id, directory: directory, base: base, workspaceID: workspaceID, prompt: prompt, providers: providers, managed: managed, cancelled: cancelled))
        case let .list(offset, limit):
            guard offset >= 0, (1...100).contains(limit) else { throw FanoutError.budget }
            let records = try store.objectPage(FanoutGroup.self, kind: "fanout", offset: offset, limit: limit + 1)
            return try encoder.encode(FanoutPage(groups: Array(records.prefix(limit)), nextOffset: records.count > limit ? offset + limit : nil, historyUnavailable: store.availability))
        case let .inspect(id): return try encoder.encode(inspect(id))
        case let .cancel(id):
            let group = try update(id) { $0.cancellationRequested = true }
            for participant in group.participants {
                if [.launching, .running, .unknown].contains(participant.state) {
                    do { _ = try host?.request(.cancelWorkload(participant.id), timeout: 1) }
                    catch { _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].failure = "Cancellation could not be confirmed for this identity; other participants are handled independently. " + error.localizedDescription } } }
                }
                for test in participant.tests where test.mayBeRunning {
                    do { _ = try host?.request(.cancelWorkload(test.id), timeout: 1) }
                    catch { _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }), let ti = group.participants[index].tests.firstIndex(where: { $0.id == test.id }) { group.participants[index].tests[ti].failure = "Test cancellation could not be confirmed. " + error.localizedDescription } } }
                }
            }
            return try encoder.encode(inspect(id))
        case let .compare(id):
            let group = try inspect(id)
            var comparisons: [String: WorktreeComparison] = [:], failures: [String: String] = [:]
            for participant in group.participants {
                if cancelled() { throw ProcessCaptureError.cancelled }
                do {
                    if let worktreeID = participant.worktreeID, !participant.cleanedUp {
                        let data = try worktrees.handle(.compare(id: worktreeID), cancelled: cancelled)
                        comparisons[participant.id.uuidString] = try JSONDecoder().decode(WorktreeComparison.self, from: data)
                    } else if participant.worktreeID == nil {
                        let head = try HarnessGit.commit("HEAD", in: group.repository.worktree, cancelled: cancelled)
                        let committed = try HarnessGit.stats(HarnessGit.run(directory: group.repository.worktree, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", group.baseCommit, head, "--"], cancelled: cancelled))
                        let working = try HarnessGit.stats(HarnessGit.run(directory: group.repository.worktree, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", head, "--"], cancelled: cancelled))
                        let untracked = try HarnessGit.run(directory: group.repository.worktree, arguments: ["ls-files", "--others", "--exclude-standard", "-z"], cancelled: cancelled).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                        var projection = ManagedWorktree(id: group.id, hostID: hostID, repository: group.repository, directory: group.repository.worktree, baseCommit: group.baseCommit, branch: "shared checkout")
                        projection.state = .ready
                        projection.note = "Shared repository state; changes cannot be attributed to one participant. This projection is not a managed cleanup target."
                        comparisons[participant.id.uuidString] = WorktreeComparison(worktree: projection, head: head, committed: committed, workingTree: working, untrackedFiles: untracked, patchUnavailable: "Use Git difftool on the recorded host for the full shared-checkout patch.")
                    }
                } catch { failures[participant.id.uuidString] = error.localizedDescription }
            }
            return try encoder.encode(FanoutComparison(group: group, repositories: comparisons, failures: failures))
        case let .cleanup(id):
            let group = try inspect(id)
            for participant in group.participants where !participant.cleanedUp {
                guard participant.canCleanup, !participant.tests.contains(where: { $0.mayBeRunning }) else { throw FanoutError.active }
                guard let worktreeID = participant.worktreeID else { continue }
                if cancelled() { throw ProcessCaptureError.cancelled }
                var cleanupClaimed = false
                do {
                    _ = try update(id) { group in
                        guard let index = group.participants.firstIndex(where: { $0.id == participant.id }), group.participants[index].canCleanup,
                              group.participants[index].cleanupInProgress != true, group.participants[index].tests.allSatisfy({ !$0.mayBeRunning }) else { throw FanoutError.active }
                        group.participants[index].cleanupInProgress = true; cleanupClaimed = true
                    }
                    _ = try worktrees.handle(.remove(id: worktreeID), cancelled: cancelled)
                    _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].cleanedUp = true; group.participants[index].cleanupInProgress = false; group.participants[index].failure = nil } }
                } catch {
                    guard cleanupClaimed else { throw error }
                    _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].cleanupInProgress = false; group.participants[index].failure = "Cleanup retained this worktree: " + error.localizedDescription } }
                }
            }
            return try encoder.encode(try recorded(id))
        case let .test(id, participantID, operationID, executable, arguments):
            try requireHost()
            let group = try inspect(id)
            guard let participant = group.participants.first(where: { $0.id == participantID }), participant.canCleanup,
                  !participant.cleanedUp, participant.cleanupInProgress != true, let directory = participant.directory else { throw FanoutError.active }
            if let prior = participant.tests.first(where: { $0.id == operationID }) {
                guard prior.launch?.executable == executable, prior.launch?.arguments == arguments else { throw FanoutError.identity }
                return try encoder.encode(group)
            }
            guard !group.captureDisabled else { throw FanoutError.captureDisabled }
            guard participant.tests.count < 16, !participant.tests.contains(where: { $0.mayBeRunning }),
                  executable.hasPrefix("/"), !executable.contains("\0"), FileManager.default.isExecutableFile(atPath: executable), arguments.count <= 128,
                  arguments.allSatisfy({ !$0.contains("\0") }), arguments.reduce(0, { $0 + $1.utf8.count }) <= 32 << 10 else { throw FanoutError.budget }
            let specification = AgentLaunchSpecification(executable: executable, arguments: arguments, directory: directory, profile: "explicit test")
            let test = TrackedTest(id: operationID, launch: specification)
            if case let .workloadOutcome(receipt) = try host?.request(.workloadOutcome(operationID)), receipt != nil {
                let latest = try recorded(id)
                if latest.participants.first(where: { $0.id == participantID })?.tests.contains(where: { $0.id == operationID && $0.launch == specification }) == true { return try encoder.encode(inspect(id)) }
                throw FanoutError.identity
            }
            var accepted = false
            let staged = try update(id) { group in
                guard let index = group.participants.firstIndex(where: { $0.id == participantID }), !group.captureDisabled,
                      !group.participants[index].cleanedUp, group.participants[index].cleanupInProgress != true else { throw FanoutError.active }
                if let prior = group.participants[index].tests.first(where: { $0.id == operationID }) {
                    guard prior.launch == specification else { throw FanoutError.identity }; return
                }
                guard !group.participants.contains(where: { $0.id == operationID }), group.id != operationID,
                      try store.object(TestExecution.self, kind: "test-execution", id: operationID.uuidString) == nil,
                      group.participants[index].tests.count < 16, group.participants[index].tests.allSatisfy({ !$0.mayBeRunning }) else { throw FanoutError.active }
                group.participants[index].tests.append(test); accepted = true
            }
            if !accepted { return try encoder.encode(staged) }
            var projection = participant; projection.id = test.id; projection.surfaceID = test.surfaceID
            projection.provider = FanoutProvider(provider: .generic, profile: "explicit test")
            do {
                let outcome = try launch(group, projection, specification, Data())
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participantID }), let ti = group.participants[index].tests.firstIndex(where: { $0.id == test.id }) { group.participants[index].tests[ti].outcome = outcome } }
            } catch let OwnedWorkloadLaunchError.notAccepted(reason) {
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participantID }), let ti = group.participants[index].tests.firstIndex(where: { $0.id == test.id }) { group.participants[index].tests[ti].launchRejected = true; group.participants[index].tests[ti].failure = "Test did not start: " + reason } }
            } catch {
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participantID }), let ti = group.participants[index].tests.firstIndex(where: { $0.id == test.id }) { group.participants[index].tests[ti].failure = "Test launch outcome is uncertain; inspect its receipt. " + error.localizedDescription } }
            }
            return try encoder.encode(inspect(id))
        }
    }
    private func requireHost() throws {
        guard store.availability == nil else { throw FanoutError.history }
        guard let host, case let .capabilities(capabilities) = try host.request(.capabilities),
              Set(["workload-stdin-v1", "workload-outcomes-v1"]).isSubset(of: Set(capabilities)) else { throw FanoutError.host }
    }
    private func recorded(_ id: UUID) throws -> FanoutGroup {
        guard let group = try store.object(FanoutGroup.self, kind: "fanout", id: id.uuidString) else { throw FanoutError.missing }
        guard group.hostID == hostID, group.id == id else { throw FanoutError.identity }
        return group
    }
    private func update(_ id: UUID, _ body: (inout FanoutGroup) throws -> Void) throws -> FanoutGroup {
        try queue.sync {
            var group = try recorded(id); try body(&group)
            // Opt-out wins against an in-flight launch batch's captured snapshot.
            for participant in group.participants {
                if try store.object(Bool.self, kind: "capture-policy", id: participant.surfaceID) == true || participant.tests.contains(where: { (try? store.object(Bool.self, kind: "capture-policy", id: $0.surfaceID)) == true }) { group.removeCapturedText(); break }
            }
            group.updatedAt = .now
            if group.participants.allSatisfy({ $0.canCleanup && $0.tests.allSatisfy { !$0.mayBeRunning } }) {
                let actualEnds = group.participants.flatMap { participant in [participant.outcome?.observedAt].compactMap { $0 } + participant.tests.compactMap { $0.outcome?.observedAt } }
                group.finishedAt = actualEnds.max() ?? group.finishedAt ?? .now
            } else { group.finishedAt = nil }
            var objects = [try LedgerObject(kind: "fanout", id: id.uuidString, value: group)]
            for participant in group.participants {
                for test in participant.tests where test.detailExpired != true {
                    var execution = TestExecution(hostID: hostID, participant: participant, repository: group.repository, test: test)
                    if group.captureDisabled { execution.removeCapturedText() }
                    objects.append(try LedgerObject(kind: "test-execution", id: test.id.uuidString, value: execution, at: test.outcome?.observedAt ?? test.acceptedAt))
                }
            }
            try store.saveObjects(objects)
            return group
        }
    }
    private func stopped(_ id: UUID, cancelled: () -> Bool) -> Bool {
        cancelled() || ((try? recorded(id).cancellationRequested) ?? true) || ((try? recorded(id).captureDisabled) ?? true)
    }
    private func start(id: UUID, directory: String, base: String?, workspaceID: UUID?, prompt: String, providers: [FanoutProvider], managed: Bool, cancelled: @escaping () -> Bool) throws -> FanoutGroup {
        try requireHost()
        guard !prompt.isEmpty, prompt.utf8.count <= 32 << 10, !prompt.contains("\0"), (1...8).contains(providers.count), providers.allSatisfy({ [.claudeCode, .codex, .cursor].contains($0.provider) }) else { throw FanoutError.invalid }
        if let prior = try store.object(FanoutGroup.self, kind: "fanout", id: id.uuidString) {
            let requestedBase = try base.map { try HarnessGit.commit($0, in: directory, cancelled: cancelled) }
            guard prior.hostID == hostID, prior.repository == (try HarnessGit.repository(at: directory, cancelled: cancelled)), (prior.captureDisabled || prior.participants.map(\.provider) == providers),
                  prior.prompt == prompt || prior.captureDisabled, prior.participants.allSatisfy({ ($0.worktreeID != nil) == managed }), workspaceID == nil || workspaceID == prior.workspaceID,
                  requestedBase == nil || requestedBase == prior.baseCommit else { throw FanoutError.identity }
            return try inspect(id) // Never repeats an accepted batch after uncertainty.
        }
        let repository = try HarnessGit.repository(at: directory, cancelled: cancelled)
        let pinned = try HarnessGit.commit(base ?? "HEAD", in: repository.worktree, cancelled: cancelled)
        if base == nil {
            guard try HarnessGit.clean(repository.worktree, cancelled: cancelled) else { throw GitOperationError.dirty }
            guard try HarnessGit.commit("HEAD", in: repository.worktree, cancelled: cancelled) == pinned else { throw GitOperationError.changed }
        }
        let selectedWorkspace = try workspace(workspaceID)
        let group = FanoutGroup(id: id, hostID: hostID, repository: repository, baseCommit: pinned, workspaceID: selectedWorkspace, prompt: prompt, providers: providers, managed: managed)
        try queue.sync {
            guard try store.object(FanoutGroup.self, kind: "fanout", id: id.uuidString) == nil, starting.count < 2 else { throw FanoutError.budget }
            try prune()
            try store.saveObjects([LedgerObject(kind: "fanout", id: id.uuidString, value: group)])
            starting.insert(id)
        }
        defer { queue.sync { _ = starting.remove(id) } }
        for participant in group.participants {
            if stopped(id, cancelled: cancelled) {
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].state = .skipped; group.participants[index].failure = "Not launched: cancellation, handover or capture opt-out interrupted the batch." } }
                continue
            }
            var accepted = false
            do {
                let directory: String
                if let worktreeID = participant.worktreeID {
                    _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].state = .creatingWorktree } }
                    let bytes = try worktrees.handle(.create(id: worktreeID, directory: repository.worktree, base: pinned), cancelled: { self.stopped(id, cancelled: cancelled) })
                    let worktree = try JSONDecoder().decode(ManagedWorktree.self, from: bytes)
                    guard worktree.state == .ready, worktree.baseCommit == pinned else { throw ManagedWorktreeError.identity }
                    directory = worktree.directory
                } else {
                    guard try HarnessGit.commit("HEAD", in: repository.worktree, cancelled: cancelled) == pinned else { throw GitOperationError.changed }
                    directory = repository.worktree
                }
                let specification = try participant.provider.specification(directory: directory, path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
                let fresh = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].directory = directory; group.participants[index].launch = specification; group.participants[index].state = .launching } }
                guard !stopped(id, cancelled: cancelled), let prompt = fresh.prompt, let current = fresh.participants.first(where: { $0.id == participant.id }) else { throw ProcessCaptureError.cancelled }
                accepted = true
                let outcome = try launch(fresh, current, specification, Data(prompt.utf8))
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) {
                    group.participants[index].outcome = outcome
                    group.participants[index].state = outcome?.state == .exited ? .exited : (outcome?.state == .running ? .running : .unknown)
                } }
            } catch let OwnedWorkloadLaunchError.notAccepted(reason) {
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].state = .failed; group.participants[index].failure = "No host launch was attempted: " + reason } }
            } catch {
                _ = try update(id) { group in if let index = group.participants.firstIndex(where: { $0.id == participant.id }) { group.participants[index].state = accepted ? .unknown : .failed; group.participants[index].failure = error.localizedDescription + (accepted ? " The launch outcome is uncertain. Inspect this participant; it will never be repeated automatically." : " Other participants retain their independent outcomes.") } }
            }
        }
        return try inspect(id)
    }
    private func inspect(_ id: UUID, cancelled: () -> Bool = { false }) throws -> FanoutGroup {
        let group = try recorded(id), inProgress = queue.sync { starting.contains(id) }
        var receipts: [UUID: WorkloadOutcome] = [:], unavailable: Set<UUID> = []
        for participant in group.participants {
            if cancelled() { throw ProcessCaptureError.cancelled }
            if [.launching, .running, .unknown].contains(participant.state) {
                do { if case let .workloadOutcome(value) = try host?.request(.workloadOutcome(participant.id), timeout: 1), let value { receipts[participant.id] = value } else { unavailable.insert(participant.id) } }
                catch { unavailable.insert(participant.id) }
            }
            for test in participant.tests where test.mayBeRunning {
                if cancelled() { throw ProcessCaptureError.cancelled }
                do { if case let .workloadOutcome(value) = try host?.request(.workloadOutcome(test.id), timeout: 1), let value { receipts[test.id] = value } }
                catch { unavailable.insert(test.id) }
            }
        }
        var cleaned: Set<UUID> = [], cleanupReady: Set<UUID> = []
        for participant in group.participants where participant.cleanupInProgress == true {
            if let worktreeID = participant.worktreeID, let data = try? worktrees.handle(.inspect(id: worktreeID), cancelled: cancelled), let record = try? JSONDecoder().decode(ManagedWorktree.self, from: data) {
                if record.state == .removed { cleaned.insert(participant.id) }
                else if record.state == .ready { cleanupReady.insert(participant.id) }
            }
        }
        return try update(id) { group in
            for index in group.participants.indices {
                let participant = group.participants[index]
                if cleaned.contains(participant.id) { group.participants[index].cleanedUp = true; group.participants[index].cleanupInProgress = false }
                else if cleanupReady.contains(participant.id) { group.participants[index].cleanupInProgress = false }
                if let receipt = receipts[participant.id] {
                    group.participants[index].outcome = receipt
                    group.participants[index].state = receipt.state == .exited ? .exited : (receipt.state == .running ? .running : .unknown)
                    group.participants[index].failure = receipt.state == .unknown ? (receipt.processAbsentObservedAt != nil ? "The recorded root is proven absent, but its exit result is unknown. Cleanup still checks active descendants, dirty files and unpushed work." : "The session host was interrupted before an actual exit outcome was retained. No launch was repeated.") : (receipt.storageUnavailable == true ? "Outcome persistence is unavailable; the displayed process observation is in memory." : nil)
                } else if unavailable.contains(participant.id) {
                    group.participants[index].failure = "The workload receipt is unavailable or expired. Last observed state is retained; no success or cancellation is inferred."
                } else if !inProgress, [.prepared, .creatingWorktree, .launching].contains(participant.state) {
                    group.participants[index].state = participant.state == .launching ? .unknown : .failed
                    group.participants[index].failure = "The accepted launch batch was interrupted. Inspect its managed worktree and start new work explicitly; this workload is not automatically repeated."
                }
                for ti in participant.tests.indices {
                    let test = participant.tests[ti]
                    if let receipt = receipts[test.id] { group.participants[index].tests[ti].outcome = receipt; group.participants[index].tests[ti].failure = receipt.state == .unknown ? "Actual test exit outcome is unknown after host interruption." : nil }
                    else if unavailable.contains(test.id) { group.participants[index].tests[ti].failure = "Test receipt is unavailable. No passing result is inferred." }
                }
            }
        }
    }
    private func prune() throws {
        var offset = 0, groups: [FanoutGroup] = []
        repeat {
            let page = try store.objectPage(FanoutGroup.self, kind: "fanout", offset: offset, limit: 500); groups += page
            if page.count < 500 { break }; offset += page.count
            guard offset <= 4096 else { throw FanoutError.budget }
        } while true
        guard groups.filter(\.isActive).count < 128 else { throw FanoutError.budget }
        try store.prune()
    }
}
