import Foundation
import HarnessCore

enum OwnedWorkloadLaunchError: Error { case notAccepted(String) }

extension SurfaceRegistry {
    func launchFanoutWorkload(group: FanoutGroup, participant: FanoutParticipant, specification: AgentLaunchSpecification, input: Data) throws -> WorkloadOutcome? {
        try launchOwnedWorkload(workspaceID: group.workspaceID, surfaceID: participant.surfaceID, workloadID: participant.id,
            provider: participant.provider.provider, title: participant.provider.provider == .generic ? "Explicit test" : "Fan-out · " + participant.provider.provider.commandToken,
            specification: specification, input: input)
    }
    func launchOwnedWorkload(workspaceID: UUID, surfaceID: String, workloadID: UUID, provider: AgentKind,
                             title: String, specification: AgentLaunchSpecification, input: Data) throws -> WorkloadOutcome? {
        guard let host = SessionHostClient.configured, let surfaceUUID = UUID(uuidString: surfaceID) else { throw OwnedWorkloadLaunchError.notAccepted("A stable host and valid surface are required.") }
        var ownsCreation = false
        defer { if ownsCreation { lock.lock(); surfaceCreations.remove(surfaceID); lock.unlock() } }
        let request: HostedPtyLaunch, leaf: PaneLeaf
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.isExecutableFile(atPath: specification.executable),
                  FileManager.default.fileExists(atPath: specification.directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw FanoutError.executable }
            let prepared: (HostedPtyLaunch, PaneLeaf) = try {
        lock.lock()
        guard !quiesced, !shuttingDown, editor.snapshot.workspaces.contains(where: { $0.id == workspaceID }),
              sessions[surfaceID] == nil, surfaceCreations.insert(surfaceID).inserted else { lock.unlock(); throw FanoutError.active }
        ownsCreation = true
        var leaf = PaneLeaf(surfaceID: surfaceUUID, cwd: specification.directory)
        leaf.workloadID = workloadID; leaf.workloadProvider = provider
        guard let tabID = editor.addTab(to: workspaceID, cwd: specification.directory, rootPane: .leaf(leaf)) else {
            surfaceCreations.remove(surfaceID); lock.unlock(); throw FanoutError.invalid
        }
        _ = editor.renameTab(tabID, name: title)
        let persistence = resolvedPersistScrollback(forSurfaceKey: surfaceID)
        var environment = extraEnvironment(forSurfaceKey: surfaceID)
        for (key, value) in specification.environment ?? [:] { environment[key] = value }
        environment["HARNESS_AGENT_PROFILE"] = specification.profile
        let identity = TerminalIdentity.spec(forOption: optionStore.get(TerminalIdentity.optionKey)?.stringValue)
        commit(); let snapshot = editor.snapshot; lock.unlock()
        // No prompt or launch arguments are written into layout. Persist its
        // structural ownership before accepting the one-shot host launch.
        try persistWorkloadLayout(snapshot)
        guard persistence else { throw FanoutError.captureDisabled }
        lock.lock(); let ready = !quiesced && !shuttingDown && editor.paneLocation(forSurfaceKey: surfaceID) != nil; lock.unlock()
        guard ready else { throw FanoutError.active }
        let request = HostedPtyLaunch(id: surfaceID, cwd: specification.directory, shell: specification.executable, rows: 24, cols: 80,
            scrollbackBytes: persistedScrollbackBytes, extraEnvironment: environment, termProgram: identity.name, termProgramVersion: identity.version,
            scrollbackURL: HarnessPaths.scrollbackFileURL(forSurfaceID: surfaceID), launchArgumentsOverride: specification.arguments,
            initialStandardInput: input, workloadID: workloadID)
                return (request, leaf)
            }()
            request = prepared.0; leaf = prepared.1
        } catch { throw OwnedWorkloadLaunchError.notAccepted(error.localizedDescription) }
        guard case let .state(state) = try host.request(.create(request)) else { throw SessionHostError.refused("The session host did not confirm this workload. Inspect its accepted ID; no launch will be repeated.") }
        let receipt: WorkloadOutcome?
        if case let .workloadOutcome(value) = try host.request(.workloadOutcome(workloadID)) { receipt = value } else { receipt = nil }
        let session = SessionPty(adopting: state, id: surfaceID, host: host)
        session.onFailure = { [weak self] message in self?.observationQueue.async { [weak self] in self?.publishObserverFailure(message) } }
        session.onStreamInterrupted = { [weak self, weak session] in
            guard let self, let session else { return }; self.scheduleObserverRecovery(surfaceKey: surfaceID, session: session)
        }
        session.onExit = { [weak self, weak session] status in self?.removeSurfaceIfCurrent(surfaceID: surfaceID, session: session, exitStatus: status) }
        lock.lock()
        let present = editor.paneLocation(forSurfaceKey: surfaceID) != nil && !shuttingDown
        if present { sessions[surfaceID] = session; rememberMonitorIdentity(surfaceID: surfaceID) }
        lock.unlock()
        if present {
            if provider != .generic, let pid = receipt?.pid, let generation = receipt?.kernelIdentity {
                try activity.registerLaunch(id: workloadID, surfaceID: surfaceID, paneID: leaf.id.uuidString, pid: pid, generation: generation,
                    provider: provider, specification: specification, startedAt: receipt?.acceptedAt ?? .now, outcome: receipt)
            }
            do {
                session.monitorSubscription = try session.subscribeSafely(watching: false) { [weak self, weak session] data, sequence in
                    self?.observeSurfaceOutput(surfaceKey: surfaceID, data: data, sequence: sequence, session: session)
                }
            } catch {
                // A fast process can finish before observation attaches. Its
                // actual outcome remains queryable from the stable host receipt.
                if case let .workloadOutcome(value) = try? host.request(.workloadOutcome(workloadID)), value?.state == .exited {
                    removeSurfaceIfCurrent(surfaceID: surfaceID, session: session, exitStatus: value?.exitCode)
                } else { session.onStreamInterrupted?() }
            }
        } else { _ = try host.request(.cancelWorkload(workloadID)) }
        if case let .workloadOutcome(outcome) = try host.request(.workloadOutcome(workloadID)) { return outcome }
        throw SessionHostError.refused("The workload was accepted, but its outcome could not be queried. Inspect the participant; no launch is repeated.")
    }
    /// Hook root eligibility is derived from a host receipt and declared launch,
    /// never from an unverified hint or the root executable's filename alone.
    func permitsHookRoot(surfaceID: String, pid: Int32, provider: AgentKind) -> Bool {
        lock.lock()
        let leaf = editor.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allLeaves() }.first { $0.surfaceID.uuidString == surfaceID }
        lock.unlock()
        guard let leaf, leaf.workloadProvider == provider, let id = leaf.workloadID, let host = SessionHostClient.configured,
              case let .workloadOutcome(value) = try? host.request(.workloadOutcome(id), timeout: 1), let value,
              value.state == .running, value.pid == pid, let generation = value.kernelIdentity,
              ProcessScan.generation(pid) == generation else { return false }
        return true
    }
}
