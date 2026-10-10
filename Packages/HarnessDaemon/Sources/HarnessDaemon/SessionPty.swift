import Foundation
import HarnessCore
import HarnessTerminalEngine

/// The registry retains a handle, never the hosted master descriptor or child reaper.
/// Embedded registries keep their local implementation for the existing isolated fixtures.
final class SessionPty: @unchecked Sendable {
    let id: String
    let createdShell: Bool
    let local: RealPty?
    private let remote: SessionHostClient?
    private let lock = NSLock()
    private var subscriptions: [UUID: SessionHostChannel] = [:]
    private var cachedState: HostedPtyState?
    private var activeTokens: Set<UUID> = []
    private var lastFailure: String?
    var onFailure: (@Sendable (String) -> Void)?
    var onStreamInterrupted: (@Sendable () -> Void)?
    private var exitHandler: ((Int32?) -> Void)?
    private var monitorToken: UUID?
    var monitorSubscription: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return monitorToken }
        set { lock.lock(); monitorToken = newValue; lock.unlock() }
    }
    var onExit: ((Int32?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return exitHandler }
        set { lock.lock(); exitHandler = newValue; lock.unlock(); local?.onExit = newValue }
    }
    init(id: String, cwd: String, shell: String, rows: UInt16, cols: UInt16, scrollbackBytes: Int,
         extraEnvironment: [String: String], termProgram: String, termProgramVersion: String,
         scrollbackURL: URL?, launchArgumentsOverride: [String]?, historyProtection: HistoryProtection? = nil) throws {
        self.id = id; remote = SessionHostClient.configured
        if let remote {
            local = nil
            let launch = HostedPtyLaunch(id: id, cwd: cwd, shell: shell, rows: rows, cols: cols,
                scrollbackBytes: scrollbackBytes, extraEnvironment: extraEnvironment, termProgram: termProgram,
                termProgramVersion: termProgramVersion, scrollbackURL: scrollbackURL, launchArgumentsOverride: launchArgumentsOverride)
            if case let .state(state) = try remote.request(.adopt(id)) { createdShell = false; cachedState = state; AgentDetector.registerRootPID(state.pid, forSurfaceKey: id); return }
            guard case let .state(state) = try remote.request(.create(launch)) else { throw SessionHostError.refused("The session host did not confirm shell creation.") }
            createdShell = true; cachedState = state; AgentDetector.registerRootPID(state.pid, forSurfaceKey: id)
        } else {
            createdShell = true
            local = try RealPty(id: id, cwd: cwd, shell: shell, rows: rows, cols: cols, scrollbackBytes: scrollbackBytes,
                extraEnvironment: extraEnvironment, termProgram: termProgram, termProgramVersion: termProgramVersion,
                scrollbackURL: scrollbackURL, launchArgumentsOverride: launchArgumentsOverride, historyProtection: historyProtection)
            AgentDetector.registerRootPID(local!.currentChildPID, forSurfaceKey: id)
        }
    }
    /// Attaches a specific host-confirmed execution without a create fallback.
    init(adopting state: HostedPtyState, id: String, host: SessionHostClient) {
        self.id = id; remote = host; local = nil; createdShell = false; cachedState = state
        if state.alive { AgentDetector.registerRootPID(state.pid, forSurfaceKey: id) }
    }
    var streamIdentity: String? {
        if let local { return local.streamIdentity }
        lock.lock(); defer { lock.unlock() }; return cachedState?.streamIdentity
    }
    func query(_ operation: HostedPtyOperation) throws -> SessionHostResult {
        guard let remote else { throw SessionHostError.refused("This pane is not hosted.") }
        let response = try remote.request(operation)
        if case let .state(state) = response {
            lock.lock(); cachedState = state; lock.unlock()
            AgentDetector.registerRootPID(state.pid, forSurfaceKey: id)
        }
        return response
    }
    func liveState() throws -> HostedPtyState {
        if let local { return HostedPtyState(local) }
        guard case let .state(value) = try query(.state(id)) else { throw SessionHostError.refused("The session host did not return process state.") }
        lock.lock(); cachedState = value; lock.unlock(); return value
    }
    func observationReplay(fromSequence: UInt64) throws -> AttachHistory {
        if let local { return local.attachHistory(history: true, fromSequence: fromSequence, screenOnResync: false, includeCheckpoint: false) }
        guard case let .history(value) = try query(.history(id, true, fromSequence, 1 << 20, false, false)) else { throw SessionHostError.refused("Retained observation replay is unavailable.") }
        return value
    }
    private func result(_ operation: HostedPtyOperation) -> SessionHostResult? {
        do {
            let value = try remote?.request(operation)
            if case let .state(state) = value { lock.lock(); cachedState = state; lock.unlock() }
            return value
        } catch { reportFailure(error.localizedDescription); return nil }
    }
    private func reportFailure(_ message: String) {
        lock.lock(); let changed = lastFailure != message; lastFailure = message; lock.unlock()
        if changed { onFailure?("Session host: " + message) }
    }
    private var state: HostedPtyState? {
        lock.lock(); defer { lock.unlock() }; return cachedState
    }
    private func text(_ operation: HostedPtyOperation) -> String { if case let .text(value) = result(operation) { return value }; return "" }
    func startSafely() throws {
        if let local { local.start(); return }
        guard case .ok = try query(.start(id)) else { throw SessionHostError.refused("Shell observation did not start.") }
    }
    func start() { do { try startSafely() } catch { reportFailure(error.localizedDescription) } }
    @discardableResult func write(_ data: Data) -> Bool { if let local { return local.write(data) }; if case .ok = result(.input(id, data)) { return true }; return false }
    @discardableResult func write(_ text: String) -> Bool { write(Data(text.utf8)) }
    @discardableResult func resize(rows: UInt16, cols: UInt16) -> Bool { if let local { return local.resize(rows: rows, cols: cols) }; if case .ok = result(.resize(id, rows, cols)) { return true }; return false }
    func clearScrollback() { if let local { local.clearScrollback() } else { _ = result(.clear(id)) } }
    func respawn(clearHistory: Bool, fallbackCwd: String?) { if let local { local.respawn(clearHistory: clearHistory, fallbackCwd: fallbackCwd) } else { _ = result(.respawn(id, clearHistory, fallbackCwd)) }; AgentDetector.registerRootPID(currentChildPID, forSurfaceKey: id) }
    func close() { if let local { local.close() } else { _ = result(.close(id)) }; AgentDetector.unregisterRootPID(forSurfaceKey: id) }
    var processGeneration: UInt64 { local?.processGeneration ?? state?.processGeneration ?? 0 }
    var currentChildPID: Int32 { local?.currentChildPID ?? state?.pid ?? -1 }
    func currentWorkingDirectory() -> String? { local?.currentWorkingDirectory() ?? state?.cwd }
    func currentSize() -> (rows: Int, cols: Int)? { if let local { return local.currentSize() }; guard let s = state, let rows = s.rows, let cols = s.cols else { return nil }; return (rows, cols) }
    func probeWorkingDirectory(parents: [Int32: Int32]? = nil) -> (pid: Int32, cwd: String)? { if let local { return local.probeWorkingDirectory(parents: parents) }; guard let s = state, let cwd = s.cwd else { return nil }; return (s.pid, cwd) }
    func probeForegroundProcess() -> (pid: Int32, executable: String)? { if let local { return local.probeForegroundProcess() }; guard let s = state, let pid = s.foregroundPID, let executable = s.foregroundExecutable else { return nil }; return (pid, executable) }
    func probeForegroundCommand() -> (pid: Int32, command: String)? { if let local { return local.probeForegroundCommand() }; guard let s = state, let executable = s.foregroundExecutable else { return nil }; return (s.pid, executable) }
    func probeForegroundArguments() -> (executable: String, arguments: [String], isShell: Bool)? { if let local { return local.probeForegroundArguments() }; guard let s = state, let executable = s.foregroundExecutable, let arguments = s.arguments, let isShell = s.isShell else { return nil }; return (executable, arguments, isShell) }
    var ringStart: UInt64 { local?.ringStart ?? state?.ringStart ?? 1 }
    var historyBytes: Int { local?.historyBytes ?? state?.historyBytes ?? 0 }
    var scrollbackByteCount: Int { local?.scrollbackByteCount ?? state?.historyBytes ?? 0 }
    var childIsAlive: Bool { local?.childIsAlive ?? state?.alive ?? true }
    var presentsProcessAsRunning: Bool { local?.presentsProcessAsRunning ?? state?.running ?? true }
    var parkedFootprint: (stored: Int, raw: Int)? { if let local { return local.parkedFootprint }; guard let s = state, let stored = s.parkedStored, let raw = s.parkedRaw else { return nil }; return (stored, raw) }
    var launchedShellForTesting: String { local?.launchedShellForTesting ?? "" }
    func changeScrollbackPersistence(enabled: Bool) throws {
        if let local { local.setScrollbackPersistence(enabled: enabled) }
        else {
            switch try query(.persist(id, enabled)) {
            case .ok: break
            case .error(let message): throw SessionHostError.refused(message)
            default: throw SessionHostError.refused("History persistence was not acknowledged by the session host.")
            }
        }
    }
    func setScrollbackPersistence(enabled: Bool) { if let local { local.setScrollbackPersistence(enabled: enabled) } else { _ = result(.persist(id, enabled)) } }
    func flushScrollback() { if let local { local.flushScrollback() } else { _ = result(.flush(id)) } }
    func deletePersistedScrollback() { if let local { local.deletePersistedScrollback() } else { _ = result(.deleteHistory(id)) } }
    func setScrollbackBytes(_ bytes: Int) { if let local { local.setScrollbackBytes(bytes) } else { _ = result(.budget(id, bytes)) } }
    func parkIfIdle(now: Date = Date(), threshold: TimeInterval = IdleGrid.defaultThreshold) { if let local { local.parkIfIdle(now: now, threshold: threshold) } else { _ = result(.park(id, now, threshold)) } }
    func warmScreen() { if let local { local.warmScreen() } else { _ = result(.warm(id)) } }
    func injectSyntheticOutput(_ data: Data) { if let local { local.injectSyntheticOutput(data) } else { _ = result(.inject(id, data)) } }
    func captureFormatted(format: String, trim: Bool, unwrap: Bool, screen: Bool = false) -> String { local?.captureFormatted(format: format, trim: trim, unwrap: unwrap, screen: screen) ?? text(.capture(id, format, trim, unwrap, screen)) }
    func captureScrollback(includeHistory: Bool) -> String { local?.captureScrollback(includeHistory: includeHistory) ?? text(.captureScrollback(id, includeHistory)) }
    func captureGrid(start: Int?, end: Int?, joinWrapped: Bool) -> String { local?.captureGrid(start: start, end: end, joinWrapped: joinWrapped) ?? text(.captureGrid(id, start, end, joinWrapped)) }
    func captureRange(start: Int?, end: Int?, escapeSequences: Bool = false) -> String { local?.captureRange(start: start, end: end, escapeSequences: escapeSequences) ?? text(.captureRange(id, start, end, escapeSequences)) }
    func processTreeJSON() -> String { local?.processTreeJSON() ?? text(.processTree(id)) }
    func replay(fromSequence: UInt64?) -> String { replayWithEndSequence(fromSequence: fromSequence).text }
    func replayWithEndSequence(fromSequence: UInt64?) -> (text: String, endSequence: UInt64) { if let local { return local.replayWithEndSequence(fromSequence: fromSequence) }; if case let .replay(text, end) = result(.replay(id, fromSequence)) { return (text, end) }; return ("", 0) }
    func attachHistory(history: Bool, fromSequence: UInt64?, chunkLimit: Int = 1 << 20, screenOnResync: Bool, includeCheckpoint: Bool) -> AttachHistory? {
        if let local { return local.attachHistory(history: history, fromSequence: fromSequence, chunkLimit: chunkLimit, screenOnResync: screenOnResync, includeCheckpoint: includeCheckpoint) }
        if case let .history(value) = result(.history(id, history, fromSequence, chunkLimit, screenOnResync, includeCheckpoint)) { return value }
        return nil
    }
    private func emulator() -> TerminalEmulator? {
        guard case let .checkpoint(data) = result(.checkpoint(id)),
              let checkpoint = try? PropertyListDecoder().decode(TerminalCheckpoint.self, from: data) else { return nil }
        let emulator = TerminalEmulator(cols: 80, rows: 24)
        guard (try? emulator.restore(checkpoint)) != nil else { return nil }; return emulator
    }
    func searchSnapshot() -> TerminalTextSnapshot? { local?.searchSnapshot() ?? emulator()?.textSnapshot() }
    var searchRevision: String { local?.searchRevision ?? state.map { "\($0.pid):\($0.ringEnd):\($0.rows ?? 0):\($0.cols ?? 0)" } ?? "unavailable" }
    func withMobileHistory<T>(_ body: (TerminalEmulator) -> T?) -> T? { if let local { return local.withMobileHistory(body) }; guard let term = emulator() else { return nil }; return body(term) }
    func subscribeSafely(watching: Bool = true, onResize: (@Sendable (ReplaySize) -> Void)? = nil, _ handler: @escaping @Sendable (Data, UInt64) -> Void) throws -> UUID {
        if let local { return local.subscribe(watching: watching, onResize: onResize, handler) }
        guard onResize == nil else { throw SessionHostError.refused("Recording geometry requires the public session-host stream.") }
        guard let remote else { throw SessionHostError.refused("The session host is unavailable.") }
        let token = UUID()
        lock.lock(); activeTokens.insert(token); lock.unlock()
        do {
            let channel = try remote.subscribe(id: id, watching: watching, onOutput: handler, onExit: { [weak self] status in
                guard let self else { return }
                self.lock.lock(); self.activeTokens.remove(token)
                self.cachedState?.alive = false; self.cachedState?.running = false
                let callback = self.exitHandler; self.lock.unlock()
                callback?(status)
            }, onEnd: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let unexpected = self.activeTokens.remove(token) != nil
                self.subscriptions.removeValue(forKey: token)
                self.lock.unlock()
                if unexpected { self.reportFailure("Activity observation disconnected; reconnecting from retained output."); self.onStreamInterrupted?() }
            })
            lock.lock(); let alive = activeTokens.contains(token)
            if alive { subscriptions[token] = channel }; lock.unlock()
            guard alive else { channel.closeChannel(); throw SessionHostError.refused("The activity subscription ended during attachment.") }
            return token
        } catch {
            lock.lock(); activeTokens.remove(token); lock.unlock()
            throw error
        }
    }
    func subscribe(watching: Bool = true, onResize: (@Sendable (ReplaySize) -> Void)? = nil, _ handler: @escaping @Sendable (Data, UInt64) -> Void) -> UUID {
        do { return try subscribeSafely(watching: watching, onResize: onResize, handler) }
        catch { reportFailure(error.localizedDescription); onStreamInterrupted?(); return UUID() }
    }
    func cancelSubscription(token: UUID? = nil) {
        if let local { local.cancelSubscription(token: token); return }
        lock.lock()
        let channels: [SessionHostChannel]
        if let token { activeTokens.remove(token); channels = subscriptions.removeValue(forKey: token).map { [$0] } ?? [] }
        else { activeTokens.removeAll(); channels = Array(subscriptions.values); subscriptions.removeAll() }
        lock.unlock(); for channel in channels { channel.closeChannel() }
    }
    deinit { for channel in subscriptions.values { channel.closeChannel() } }
}
