import Foundation
import HarnessCore
@testable import HarnessDaemonCore

final class OwnedWorkloadFixture: @unchecked Sendable {
    let store: SessionHostStore
    let listener: SessionHostListener
    let client: SessionHostClient
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: SessionHostChannel] = [:]
    private var launches: [UUID: Int] = [:]
    func launchCount(_ id: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return launches[id] ?? 0 }
    init(root: URL) throws {
        store = SessionHostStore(snapshotURL: root.appendingPathComponent("layout.json"), sessionsDirectory: root.appendingPathComponent("owner"), historyDirectory: root.appendingPathComponent("scrollback"))
        let generation = UUID(), path = root.appendingPathComponent("owner.sock").path
        listener = SessionHostListener(path: path); client = SessionHostClient(path: path, generation: generation)
        store.queue.sync { store.generations.insert(generation); store.grant(generation) }
        try listener.start { [weak self] channel in
            guard let self else { channel.closeChannel(); return }
            self.lock.lock(); self.channels[ObjectIdentifier(channel)] = channel; self.lock.unlock()
            channel.start(onFrame: { [weak self, weak channel] data in
                guard let self, let channel, let request = try? JSONDecoder().decode(SessionHostRequest.self, from: data.dropFirst(4)) else { channel?.closeChannel(); return }
                self.store.handle(request, channel: channel)
            }, onEnd: { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.store.forget(channel); self.lock.lock(); self.channels.removeValue(forKey: ObjectIdentifier(channel)); self.lock.unlock()
            })
        }
    }
    func launch(_ group: FanoutGroup, _ participant: FanoutParticipant, _ specification: AgentLaunchSpecification, _ input: Data) throws -> WorkloadOutcome? {
        try launch(id: participant.id, surfaceID: participant.surfaceID, specification: specification, input: input)
    }
    func launch(_ record: ScheduleRecord, _ occurrence: ScheduleOccurrence) throws -> WorkloadOutcome? {
        try launch(id: occurrence.id, surfaceID: occurrence.surfaceID, specification: record.definition.launch, input: Data((record.definition.input ?? "").utf8))
    }
    func launch(id: UUID, surfaceID: String, specification: AgentLaunchSpecification, input: Data) throws -> WorkloadOutcome? {
        lock.lock(); launches[id, default: 0] += 1; lock.unlock()
        let launch = HostedPtyLaunch(id: surfaceID, cwd: specification.directory, shell: specification.executable, rows: 24, cols: 80, scrollbackBytes: 65536,
            extraEnvironment: specification.environment ?? [:], termProgram: "Harness", termProgramVersion: "fixture", scrollbackURL: nil,
            launchArgumentsOverride: specification.arguments, initialStandardInput: input, workloadID: id)
        guard case .state = try client.request(.create(launch)) else { throw FanoutError.host }
        guard case let .workloadOutcome(value) = try client.request(.workloadOutcome(id)) else { throw FanoutError.host }; return value
    }
    func stop() {
        store.queue.sync { for pty in store.ptys.values { pty.close() }; store.stopOwnedPipes() }
        _ = store.waitForOwnedChildren(timeout: 4)
        listener.stop(); lock.lock(); let pending = Array(channels.values); channels.removeAll(); lock.unlock()
        for channel in pending { channel.closeChannel() }
    }
}
