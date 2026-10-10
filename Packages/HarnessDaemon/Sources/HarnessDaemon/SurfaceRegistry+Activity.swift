import Foundation
import HarnessCore

extension SurfaceRegistry {
    public func activatePowerManagement() {
        power.activate()
        notifications.start()
        schedules.activate()
        aiSummaries.activate()
        scheduleAutomaticRestores()
    }
    func setNotificationSnooze(surfaceID: String, minutes: Int) -> IPCResponse {
        guard let id = UUID(uuidString: surfaceID), [0, 15, 60].contains(minutes) else { return .error("Snooze must be 0, 15, or 60 minutes") }
        lock.lock(); let present = editor.paneLocation(forSurfaceKey: surfaceID) != nil, paused = quiesced || shuttingDown; lock.unlock()
        guard present, !paused else { return .error("The pane is unavailable or handover is in progress.") }
        do {
            let prior = notifications.status().controls.first { $0.surfaceID == surfaceID && $0.runID == nil }
            let until = minutes == 0 ? nil : Date().addingTimeInterval(Double(minutes * 60))
            try notifications.control(AgentNotificationControl(surfaceID: surfaceID, muted: prior?.muted ?? false, snoozedUntil: until))
            lock.lock()
            if editor.updatePaneActivity(surfaceID: id, { $0.snoozedUntil = until }) { commit() }
            lock.unlock(); return .ok
        } catch { return .error(error.localizedDescription) }
    }
    func handleActivity(_ operation: ActivityOperation, cancelled: @escaping () -> Bool = { false }) -> IPCResponse {
        lock.lock()
        guard !quiesced, !shuttingDown else { lock.unlock(); return .error("Activity handover is in progress; retry this request. Programs remain running.") }
        hostedMutations.enter(); lock.unlock()
        defer { hostedMutations.leave() }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data: Data
            switch operation {
            case let .list(hostID, surfaceID, activeOnly, offset, limit, responseCapabilities):
                guard hostID == nil || hostID == activity.hostID else { return .error("This run query names a different host; connect to its recorded host.") }
                guard offset >= 0, (1...500).contains(limit) else { return .error("History offset must be nonnegative and page size must be 1–500.") }
                data = try encoder.encode(ActivityResponseCompatibility.page(try activity.store.list(surfaceID: surfaceID, activeOnly: activeOnly, offset: offset, limit: limit), capabilities: responseCapabilities))
            case let .session(hostID, runID, offset, limit, responseCapabilities):
                guard hostID == nil || hostID == activity.hostID else { return .error("This run belongs to another host.") }
                guard offset >= 0, (1...499).contains(limit) else { return .error("Event offset must be nonnegative and page size must be 1–499.") }
                guard let run = try activity.store.run(runID) else { return .error("This execution is unavailable or has expired under the history retention policy.") }
                var events = try activity.store.events(runID: runID, offset: offset, limit: limit + 1)
                lock.lock(); let target = sessions[run.surfaceID]; lock.unlock()
                let state = try? target?.liveState()
                for index in events.indices {
                    events[index].anchorAvailability = events[index].availability(stream: state?.streamIdentity, firstSequence: state?.ringStart, endSequence: state?.ringEnd, terminalPresent: target != nil)
                }
                data = try encoder.encode(AgentRunSession(run: ActivityResponseCompatibility.run(run, capabilities: responseCapabilities), events: events.prefix(limit).map { ActivityResponseCompatibility.event($0, capabilities: responseCapabilities) }, nextOffset: events.count > limit ? offset + limit : nil, historyUnavailable: activity.unavailable()))
            case let .notifications(operation):
                switch operation {
                case .status: break
                case let .configure(value): try notifications.configure(value)
                case let .control(value):
                    if let runID = value.runID {
                        guard let run = try activity.store.run(runID), run.surfaceID == value.surfaceID else { return .error("Notification control names a different execution or pane.") }
                    }
                    try notifications.control(value)
                case let .credentials(reference, values):
                    guard let values else { return .error("Credential reads are not exposed. Provide values through secure local input.") }
                    try CredentialStore.save(values, reference: reference); return .ok
                case let .removeCredentials(reference): try CredentialStore.remove(reference); return .ok
                }
                data = try encoder.encode(notifications.status())
            case let .power(operation):
                switch operation {
                case .status: break
                case let .mode(value): try power.setMode(value)
                case let .configure(value): try power.configure(value)
                }
                data = try encoder.encode(power.status())
            case let .worktrees(_, operation):
                data = try worktrees.handle(operation, cancelled: cancelled)
            case let .configure(settings):
                if let settings { try usage.configure(settings); return .ok }
                data = try encoder.encode(usage.configuration())
            case let .resumePolicy(surfaceID, runID, automatic):
                if automatic {
                    guard let runID, let run = try activity.store.run(runID), run.hostID == activity.hostID else { throw ResumeError.unavailable }
                    _ = try AgentResume.command(for: run); try AgentResume.validateFiles(for: run)
                }
                lock.lock(); defer { lock.unlock() }
                guard !quiesced, let id = UUID(uuidString: surfaceID), editor.paneLocation(forSurfaceKey: surfaceID) != nil else { throw ResumeError.shellChanged }
                for wi in editor.snapshot.workspaces.indices {
                    for si in editor.snapshot.workspaces[wi].sessions.indices {
                        for ti in editor.snapshot.workspaces[wi].sessions[si].tabs.indices {
                            editor.snapshot.workspaces[wi].sessions[si].tabs[ti].rootPane.updateLeaf(surfaceKey: id.uuidString) { leaf in
                                leaf.resumeAutomatically = automatic
                                if automatic { leaf.lastAgentRunID = runID }
                            }
                        }
                    }
                }
                editor.snapshot.revision += 1; commit(); return .ok
            case let .resume(runID, surfaceID, expected):
                guard let run = try activity.store.run(runID), run.hostID == activity.hostID else { throw ResumeError.unavailable }
                let command = try AgentResume.command(for: run)
                try AgentResume.validateFiles(for: run)
                lock.lock(); let target = sessions[surfaceID]; lock.unlock()
                guard let target else { throw ResumeError.shellChanged }
                let state = try target.liveState()
                if let expected {
                    if let local = target.local { try local.insertResume(command, expectedIdentity: expected) }
                    else { _ = try target.query(.insertResume(surfaceID, command, expected)) }
                }
                data = try encoder.encode(PreparedAgentResume(runID: runID, surfaceID: surfaceID,
                    command: command, freshShellIdentity: state.freshShellIdentity, inserted: expected != nil))
            case let .commandOutput(surfaceID, maximum):
                data = try encoder.encode(readCommandOutput(surfaceID: surfaceID, maximum: maximum))
            case let .explain(source, targetID, runID):
                let output = try readCommandOutput(surfaceID: source, maximum: 8192)
                guard !output.evicted else { return .error("This command's output has been evicted; an explanation cannot reconstruct it.") }
                guard let run = try activity.store.run(runID), run.surfaceID == targetID,
                      run.process == .running, run.parentRunID == nil, let pid = run.pid else {
                    return .error("Select a current agent execution in the target pane.")
                }
                lock.lock(); let target = sessions[targetID]; lock.unlock()
                guard let target else { return .error("The target agent's pane has closed.") }
                if let local = target.local { try local.insertExplanation(output.explanationPrompt, agentPID: pid, agentGeneration: run.processGeneration) }
                else { _ = try target.query(.insertExplanation(targetID, output.explanationPrompt, pid, run.processGeneration)) }
                return .ok
            case let .resources(surfaceID):
                let root = try resourceRoot(surfaceID)
                data = try encoder.encode(resources.sample(surfaceID: surfaceID, rootPID: root))
            case let .terminateTree(surfaceID, generation):
                let root = try resourceRoot(surfaceID)
                try resources.terminate(rootPID: root, expectedGeneration: generation)
                return .ok
            case let .usage(from, to):
                guard validActivityRange(from, to) else { return .error("Usage range must be ordered and no longer than 90 days.") }
                data = try encoder.encode(usage.summary(from: from, to: to))
            case let .repositoryDigest(_, from, to, offset, limit):
                guard validActivityRange(from, to) else { return .error("Repository report range must be ordered and no longer than 90 days.") }
                data = try encoder.encode(activity.store.repositoryDigests(hostID: activity.hostID, from: from, to: to, offset: offset, limit: limit, cancelled: cancelled))
            case let .digest(from, to, surfaceID, responseCapabilities):
                guard validActivityRange(from, to) else { return .error("Digest range must be ordered and no longer than 90 days.") }
                let (totals, events, truncated) = try activity.store.digestEvents(from: from, to: to, surfaceID: surfaceID)
                var digest = try ActivityDigest(hostID: activity.hostID, from: from, to: to, totals: totals, timeline: events, timelineTruncated: truncated,
                    usage: usage.summary(from: from, to: to), historyUnavailable: activity.unavailable())
                digest.tests = try activity.store.testSummary(from: from, to: to, surfaceID: surfaceID)
                digest.timeline = digest.timeline.map { ActivityResponseCompatibility.event($0, capabilities: responseCapabilities) }
                data = try encoder.encode(digest)
            case let .hookPolicy(operation):
                switch operation {
                case var .record(audit):
                    guard audit.ruleIDs.count <= 32, audit.event.utf8.count <= 64,
                          ["PreToolUse", "preToolUse", "beforeShellExecution", "beforeMCPExecution"].contains(audit.event),
                          audit.surfaceID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw HookPolicyError.invalid }
                    audit.at = .now; try activity.store.recordPolicyAudit(audit); return .ok
                case let .audit(offset, limit):
                    guard (0...1_000_000).contains(offset), (1...100).contains(limit) else { throw HookPolicyError.invalid }
                    let records = try activity.store.objectPage(HookPolicyAudit.self, kind: "hook-policy-audit", offset: offset, limit: limit + 1)
                    data = try encoder.encode(HookPolicyAuditPage(records: Array(records.prefix(limit)), nextOffset: records.count > limit ? offset + limit : nil, unavailable: activity.unavailable()))
                }
            case let .schedules(_, operation):
                data = try schedules.handle(operation)
            case let .aiSummaries(operation):
                data = try aiSummaries.handle(operation)
            case let .fanout(_, operation):
                data = try fanout.handle(operation, cancelled: {
                    self.lock.lock(); let stopped = self.quiesced || self.shuttingDown; self.lock.unlock()
                    return stopped || cancelled()
                })
            case let .hook(report):
                guard report.profile.utf8.count <= 256, UUID(uuidString: report.surfaceID) != nil else { return .error("Hook profile or surface identity is invalid.") }
                lock.lock()
                let persistence = resolvedPersistScrollback(forSurfaceKey: report.surfaceID)
                let pty = sessions[report.surfaceID], paneID = editor.paneLocation(forSurfaceKey: report.surfaceID)?.paneID.uuidString
                lock.unlock()
                guard let pty else { return .error("The hook's shell is no longer available.") }
                let root = pty.currentChildPID
                let parents = ProcessScan.parentMap()
                var cursor = report.senderPID, belongs = false
                for _ in 0..<64 {
                    if cursor == root { belongs = true; break }
                    guard let parent = parents[cursor], parent > 0, parent != cursor else { break }; cursor = parent
                }
                guard belongs else { return .error("Hook process identity does not belong to the recorded shell.") }
                guard let pid = AgentDetector.ancestorAgent(pid: report.senderPID, root: root,
                    provider: report.observation.contract.provider, table: AgentTable.loadFromDisk(), parents: parents,
                    allowRoot: permitsHookRoot(surfaceID: report.surfaceID, pid: root, provider: report.observation.contract.provider)) else {
                    return .error("The reporting provider process could not be verified in the hook's ancestor chain.")
                }
                guard let generation = ProcessScan.generation(pid) else { return .error("Hook process has exited; its execution identity could not be verified.") }
                let sequence: UInt64
                if let local = pty.local { sequence = local.ringEnd }
                else if case let .state(state) = try pty.query(.state(report.surfaceID)) { sequence = state.ringEnd }
                else { return .error("Terminal sequence anchor is unavailable.") }
                if !persistence { usage.setPersistence(surfaceID: report.surfaceID, enabled: false); try activity.setPersistence(surfaceID: report.surfaceID, enabled: false) }
                let launch = report.observation.directory.flatMap {
                    AgentDetector.launchSpecification(pid: pid, provider: report.observation.contract.provider,
                        generation: generation, directory: $0, profile: report.profile, environment: report.launchEnvironment ?? [:])
                }
                let run = try activity.report(report, paneID: paneID, generation: generation, pid: pid, sequence: sequence, streamIdentity: pty.streamIdentity, launch: launch)
                data = try encoder.encode(ActivityResponseCompatibility.run(run, capabilities: nil))
            }
            return .text(String(decoding: data, as: UTF8.self))
        } catch { return .error(error.localizedDescription) }
    }
    func readCommandOutput(surfaceID: String, maximum: Int) throws -> CommandOutput {
        guard (1...65536).contains(maximum) else { throw SessionHostError.refused("Command output limit must be 1–65536 bytes.") }
        monitorLock.lock(); let cached = monitors[surfaceID]?.lastCommand; monitorLock.unlock()
        guard let span = try cached ?? activity.store.object(ShellCommandSpan.self, kind: "shell-command", id: surfaceID) else {
            throw SessionHostError.refused("No completed OSC 133 command span is available. Enable shell integration before running the command.")
        }
        lock.lock(); let target = sessions[surfaceID]; lock.unlock()
        guard let target else { throw SessionHostError.refused("The command's terminal has closed; its live replay window is unavailable.") }
        if let local = target.local { return try local.commandOutput(span: span, maximumBytes: maximum) }
        if case let .commandOutput(value) = try target.query(.commandOutput(surfaceID, span, maximum)) { return value }
        throw SessionHostError.refused("Command output is unavailable from the session host.")
    }
    private func resourceRoot(_ surfaceID: String) throws -> Int32 {
        lock.lock(); let pty = sessions[surfaceID]; lock.unlock()
        guard let pty else { throw SessionHostError.refused("The pane has closed.") }
        if let local = pty.local { return local.currentChildPID }
        guard case let .state(state) = try pty.query(.state(surfaceID)) else { throw SessionHostError.refused("The shell process identity is unavailable.") }
        return state.pid
    }
    private func validActivityRange(_ from: Date, _ to: Date) -> Bool {
        from.timeIntervalSince1970.isFinite && to.timeIntervalSince1970.isFinite && to > from && to.timeIntervalSince(from) <= 90 * 86400
    }
    func applyCanonicalRun(_ run: AgentRun) {
        lock.lock(); defer { lock.unlock() }
        guard !quiesced, run.parentRunID == nil else { return }
        let state: AgentActivity
        if run.attention == .error || run.turn == .failed { state = .errored }
        else if run.attention != .none { state = .awaiting }
        else if run.turn == .working { state = .working }
        else { state = .idle }
        let snapshot: AgentSnapshot? = run.process == .exited ? nil : AgentSnapshot(kind: run.provider, executable: run.provider.commandToken, pid: run.pid ?? 0, activity: state, lastActivityAt: run.observedAt)
        editor.setAgent(snapshot, forSurfaceKey: run.surfaceID)
        for wi in editor.snapshot.workspaces.indices {
            for si in editor.snapshot.workspaces[wi].sessions.indices {
                for ti in editor.snapshot.workspaces[wi].sessions[si].tabs.indices {
                    editor.snapshot.workspaces[wi].sessions[si].tabs[ti].rootPane.updateLeaf(surfaceKey: run.surfaceID) { $0.lastAgentRunID = run.id }
                }
            }
        }
        commit()
    }
}
