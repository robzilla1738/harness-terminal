import Foundation
import HarnessCore
import HarnessTerminalEngine

struct HostedPtyLaunch: Codable, Sendable {
    var id: String, cwd: String, shell: String
    var rows: UInt16, cols: UInt16
    var scrollbackBytes: Int
    var extraEnvironment: [String: String]
    var termProgram: String, termProgramVersion: String
    var scrollbackURL: URL?
    var launchArgumentsOverride: [String]?
    var initialStandardInput: Data? = nil
    var workloadID: UUID? = nil
}
struct HostedPtyState: Codable, Sendable {
    var streamIdentity: String
    var processGeneration: UInt64
    var freshShellIdentity: String?
    var pid: Int32
    var cwd: String?
    var foregroundPID: Int32?
    var foregroundExecutable: String?
    var arguments: [String]?
    var isShell: Bool?
    var rows: Int?, cols: Int?
    var historyBytes: Int
    var historyUnavailable: String?
    var historyProtection: HistoryProtection.Kind?
    var ringEnd: UInt64, ringStart: UInt64
    var alive: Bool, running: Bool
    var preparedStandardInput: Bool? = nil
    var parkedStored: Int?, parkedRaw: Int?
    init(_ pty: RealPty) {
        streamIdentity = pty.streamIdentity
        processGeneration = pty.processGeneration
        freshShellIdentity = pty.freshShellIdentity
        pid = pty.currentChildPID; cwd = pty.currentWorkingDirectory()
        let foreground = pty.probeForegroundProcess()
        foregroundPID = foreground?.pid; foregroundExecutable = foreground?.executable
        let command = pty.probeForegroundArguments(); arguments = command?.arguments; isShell = command?.isShell
        let size = pty.currentSize(); rows = size?.rows; cols = size?.cols
        historyBytes = pty.historyBytes; ringEnd = pty.ringEnd; ringStart = pty.ringStart
        historyUnavailable = pty.historyUnavailable; historyProtection = pty.historyProtection
        alive = pty.childIsAlive; running = pty.presentsProcessAsRunning; preparedStandardInput = pty.usesPreparedStandardInput
        let parked = pty.parkedFootprint; parkedStored = parked?.stored; parkedRaw = parked?.raw
    }
}
enum HostedPtyOperation: Codable, Sendable {
    case applicationCheckpoint(Data)
    case inventory
    case capabilities
    case workloadOutcome(UUID), cancelWorkload(UUID)
    case adopt(String), create(HostedPtyLaunch), state(String), start(String)
    case input(String, Data), inject(String, Data), resize(String, UInt16, UInt16)
    case insertResume(String, String, String)
    case automaticResume(String, String, String)
    case commandOutput(String, ShellCommandSpan, Int)
    case insertExplanation(String, String, Int32, String)
    case pipe(String, String?)
    case close(String), respawn(String, Bool, String?), clear(String)
    case persist(String, Bool), flush(String), deleteHistory(String), budget(String, Int)
    case park(String, Date, TimeInterval), warm(String)
    case capture(String, String, Bool, Bool, Bool)
    case captureScrollback(String, Bool), captureGrid(String, Int?, Int?, Bool), captureRange(String, Int?, Int?, Bool)
    case processTree(String), replay(String, UInt64?)
    case history(String, Bool, UInt64?, Int, Bool, Bool), checkpoint(String)
    case subscribe(String, Bool)
    var querySurface: String? {
        switch self {
        case let .state(id), let .processTree(id), let .checkpoint(id): id
        case let .capture(id, _, _, _, _), let .captureScrollback(id, _), let .captureGrid(id, _, _, _),
             let .captureRange(id, _, _, _), let .replay(id, _), let .history(id, _, _, _, _, _), let .commandOutput(id, _, _): id
        default: nil
        }
    }
    var mutation: Bool {
        switch self {
        case .inventory, .adopt, .state, .capture, .captureScrollback, .captureGrid, .captureRange, .processTree, .replay, .history, .checkpoint, .subscribe, .commandOutput, .workloadOutcome, .capabilities: false
        default: true
        }
    }
}
struct SessionHostRequest: Codable, Sendable {
    static let protocolVersion = DaemonStats.currentSessionHostProtocolLevel
    var version = Self.protocolVersion
    var generation: UUID
    var operationID = UUID()
    var operationSequence: UInt64
    var operation: HostedPtyOperation
}
enum SessionHostResult: Codable, Sendable {
    case inventory([String]), capabilities([String])
    case ok, error(String), state(HostedPtyState), text(String), replay(String, UInt64)
    case history(AttachHistory), checkpoint(Data), output(Data, UInt64), exited(Int32?)
    case commandOutput(CommandOutput)
    case workloadOutcome(WorkloadOutcome?)
}

/// One request connection per operation: an uncertain write is never retried automatically.
/// A retry with the same operation identity is safe while the generation lease is retained.
final class SessionHostClient: @unchecked Sendable {
    private static let sequences = SequenceAllocator()
    let path: String, generation: UUID
    init(path: String, generation: UUID) { self.path = path; self.generation = generation }
    static var configured: SessionHostClient? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HARNESS_SESSION_HOST_SOCKET"],
              let raw = environment["HARNESS_DAEMON_GENERATION"], let generation = UUID(uuidString: raw) else { return nil }
        return SessionHostClient(path: path, generation: generation)
    }
    struct OperationIdentity: Sendable { let id: UUID; let sequence: UInt64 }
    func operationIdentity() -> OperationIdentity { .init(id: UUID(), sequence: Self.sequences.next(generation)) }
    func request(_ operation: HostedPtyOperation, identity: OperationIdentity? = nil, timeout: TimeInterval = 5) throws -> SessionHostResult {
        let token = identity ?? operationIdentity()
        let frame = try IPCCodec.encode(SessionHostRequest(generation: generation, operationID: token.id, operationSequence: token.sequence, operation: operation))
        let channel = SessionHostChannel(fd: try EndpointConnector.connect(.unix(path: path)))
        let response = ResponseBox()
        channel.start(onFrame: { data in
            response.set(try? JSONDecoder().decode(SessionHostResult.self, from: data.dropFirst(4)))
        }, onEnd: { response.set(nil) })
        channel.send(frame)
        defer { channel.closeChannel() }
        guard response.ready.wait(timeout: .now() + timeout) == .success, let result = response.read() else { throw DaemonClientError.timeout }
        if case let .error(message) = result { throw SessionHostError.refused(message) }
        return result
    }
    func subscribe(id: String, watching: Bool, onOutput: @escaping @Sendable (Data, UInt64) -> Void,
                   onExit: @escaping @Sendable (Int32?) -> Void,
                   onEnd: @escaping @Sendable () -> Void) throws -> SessionHostChannel {
        let channel = SessionHostChannel(fd: try EndpointConnector.connect(.unix(path: path)))
        let acknowledgement = ResponseBox()
        channel.start(onFrame: { data in
            if data.first == 0xf5 {
                var buffer = data
                if case let .output(bytes, sequence) = try? IPCCodec.decodeReplyOrData(from: &buffer) { onOutput(bytes, sequence) }
                return
            }
            guard let event = try? JSONDecoder().decode(SessionHostResult.self, from: data.dropFirst(4)) else { return }
            switch event {
            case .ok, .error: acknowledgement.set(event)
            case let .output(data, sequence): onOutput(data, sequence)
            case let .exited(status): acknowledgement.set(.ok); onExit(status)
            default: break
            }
        }, onEnd: { acknowledgement.set(nil); onEnd() })
        channel.send(try IPCCodec.encode(SessionHostRequest(generation: generation, operationSequence: Self.sequences.next(generation), operation: .subscribe(id, watching))))
        guard acknowledgement.ready.wait(timeout: .now() + 1) == .success, let result = acknowledgement.read() else {
            channel.closeChannel(); throw SessionHostError.refused("The session host did not acknowledge the activity subscription.")
        }
        guard case .ok = result else {
            channel.closeChannel()
            if case let .error(message) = result { throw SessionHostError.refused(message) }
            throw SessionHostError.refused("The activity subscription is unavailable.")
        }
        return channel
    }
    private final class SequenceAllocator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: UInt64] = [:]
        func next(_ generation: UUID) -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            values[generation, default: 0] += 1
            return values[generation]!
        }
    }
    private final class ResponseBox: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false, value: SessionHostResult?
        func set(_ value: SessionHostResult?) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }; finished = true; self.value = value; ready.signal()
        }
        func read() -> SessionHostResult? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
enum SessionHostError: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { switch self { case let .refused(message): message } }
}
