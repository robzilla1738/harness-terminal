import Foundation

public struct TerminalRecordingStatus: Sendable {
    public enum Phase: String, Sendable { case idle, starting, recording, finished, failed }
    public var phase: Phase, events: Int, durationMs: Int, failure: String?
    public var complete: Bool { phase == .finished || phase == .failed }
}

/// One owned recorder shared by the CLI and native review flow. Its subscription
/// is read-only, never votes on size, and cannot inject or replay terminal input.
public final class LiveTerminalRecorder: @unchecked Sendable {
    private let lock = NSLock(), client: DaemonClient, surfaceID: String, url: URL, protection: HistoryProtection
    private let onUpdate: @Sendable (TerminalRecordingStatus) -> Void
    private let onOutput: (@Sendable (Data) -> Void)?
    private var state = TerminalRecordingStatus(phase: .idle, events: 0, durationMs: 0, failure: nil)
    private var archive: RecordingArchiveWriter?, subscription: DaemonSubscription?
    private var startNanos: UInt64 = 0, stopping = false
    public init(client: DaemonClient, surfaceID: String, url: URL, protection: HistoryProtection = .system(), onUpdate: @escaping @Sendable (TerminalRecordingStatus) -> Void, onOutput: (@Sendable (Data) -> Void)? = nil) {
        self.client = client; self.surfaceID = surfaceID; self.url = url; self.protection = protection; self.onUpdate = onUpdate; self.onOutput = onOutput
    }
    public var protectionKind: HistoryProtection.Kind { protection.kind }
    public var status: TerminalRecordingStatus { lock.lock(); defer { lock.unlock() }; return state }
    public func start() {
        lock.lock(); guard state.phase == .idle, !stopping else { lock.unlock(); return }
        state.phase = .starting; let initial = state; lock.unlock(); onUpdate(initial)
        do {
            guard UUID(uuidString: surfaceID) != nil else { throw RecordingArchiveError.invalid }
            guard case let .daemonStats(stats) = try client.request(.daemonStats), stats.supports(DaemonStats.terminalGeometry) else { throw RecordingError.geometry }
            lock.lock()
            guard !stopping else { lock.unlock(); return }
            do { archive = try RecordingArchiveWriter(url: url, protection: protection); startNanos = DispatchTime.now().uptimeNanoseconds }
            catch { lock.unlock(); throw error }
            lock.unlock()
            guard append(.metadata(version: 1, createdAt: .now, surfaceID: surfaceID)) else { return }
            let attached = try client.attachStream(
                AttachRequest(surfaceID: surfaceID, label: "harness-recording", readOnly: true, history: false, geometryEvents: true),
                onAttached: { [weak self] reply in
                    guard let self else { return }
                    guard let size = reply.replaySizes?.last, let screen = reply.screen else { self.fail("The initial terminal screen or dimensions are unavailable."); return }
                    guard self.append(.resize(timeMs: self.nowMs(), rows: size.rows, cols: size.cols)), self.append(.output(timeMs: self.nowMs(), data: screen)) else { return }
                    self.lock.lock(); if !self.stopping { self.state.phase = .recording }; let status = self.state; self.lock.unlock(); self.onUpdate(status)
                }, onData: { [weak self] data, _ in
                    guard let self else { return }
                    if self.append(.output(timeMs: self.nowMs(), data: data)) { self.onOutput?(data) }
                }, onResize: { [weak self] size in
                    guard let self else { return }; _ = self.append(.resize(timeMs: self.nowMs(), rows: size.rows, cols: size.cols))
                }, onEnd: { [weak self] in self?.stop() }, onError: { [weak self] message in self?.fail(message) }
            )
            lock.lock(); let ended = stopping; if !ended { subscription = attached }; lock.unlock()
            if ended { attached.cancel() }
        } catch { fail(error.localizedDescription) }
    }
    public func stop() {
        lock.lock(); guard !stopping else { lock.unlock(); return }; stopping = true
        let subscription = self.subscription; self.subscription = nil; let archive = self.archive; self.archive = nil
        lock.unlock()
        subscription?.cancel()
        var failure: String?
        do { try archive?.finish() } catch { failure = error.localizedDescription }
        lock.lock(); if state.failure == nil { state.failure = failure }; state.phase = state.failure == nil ? .finished : .failed; let final = state; lock.unlock()
        onUpdate(final)
    }
    private func fail(_ message: String) { lock.lock(); guard !stopping else { lock.unlock(); return }; if state.failure == nil { state.failure = message }; lock.unlock(); stop() }
    private func nowMs() -> Int { lock.lock(); let start = startNanos; lock.unlock(); return start == 0 ? 0 : Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) }
    private func append(_ event: RecordingEvent) -> Bool {
        lock.lock(); guard !stopping, let archive else { lock.unlock(); return false }
        let ordered: RecordingEvent
        if let time = event.timeMs {
            let time = max(time, state.durationMs)
            switch event {
            case let .output(_, data): ordered = .output(timeMs: time, data: data)
            case let .resize(_, rows, cols): ordered = .resize(timeMs: time, rows: rows, cols: cols)
            case .input: lock.unlock(); fail("Input capture is disabled."); return false
            case .metadata: ordered = event
            }
        } else { ordered = event }
        do { try archive.append(ordered); state.events += 1; state.durationMs = ordered.timeMs ?? state.durationMs; lock.unlock(); return true }
        catch { lock.unlock(); fail(error.localizedDescription); return false }
    }
    deinit { subscription?.cancel(); try? archive?.finish() }
    private enum RecordingError: Error, LocalizedError {
        case geometry
        var errorDescription: String? { "Recording requires ordered PTY geometry support. Adopt a compatible session-host update after its shells close; existing programs remain running." }
    }
}
