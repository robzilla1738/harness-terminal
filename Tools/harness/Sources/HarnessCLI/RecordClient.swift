#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

/// `harness-cli record` — records a daemon-owned surface's output to a JSON Lines
/// file (see ``RecordingEvent`` for the format).
///
/// This is a **passive observer**: it subscribes to the surface's output stream
/// and writes `output` events; it never sends input or resizes the surface, so
/// recording is safe to run alongside the GUI or other clients. With `--display`
/// the output is also mirrored to the local terminal so the user can watch live.
///
/// Recording runs until the user presses Ctrl-C or the surface closes. Because
/// the format is line-oriented and every line is flushed as it is written, an
/// interrupted recording is never corrupt — at worst the final line is truncated.
public enum RecordClient {
    public static func run(
        client: DaemonClient, surfaceID: String, outputPath: String, display: Bool
    ) -> Int32 {
        let writer: RecordingWriter
        do {
            writer = try RecordingWriter(path: outputPath)
        } catch {
            fputs("harness-cli record: cannot open \(outputPath): \(error)\n", harnessStderr)
            return 1
        }

        let session = RecordSession(
            client: client, surfaceID: surfaceID, writer: writer, display: display
        )
        return session.run()
    }
}

// MARK: - Session

private final class RecordSession: @unchecked Sendable {
    private let client: DaemonClient
    private let surfaceID: String
    private let writer: RecordingWriter
    private let display: Bool

    /// Signaled when recording should stop (Ctrl-C or the surface stream ending).
    private let done = DispatchSemaphore(value: 0)
    private var stopped = false
    private let stopLock = NSLock()

    private var subscription: DaemonSubscription?
    private var sigintSource: DispatchSourceSignal?
    private var sigwinchSource: DispatchSourceSignal?

    init(client: DaemonClient, surfaceID: String, writer: RecordingWriter, display: Bool) {
        self.client = client
        self.surfaceID = surfaceID
        self.writer = writer
        self.display = display
    }

    func run() -> Int32 {
        writer.append(.metadata(
            version: TerminalRecordingCodec.formatVersion, createdAt: Date(), surfaceID: surfaceID
        ))

        // Record the terminal size when we have a controlling TTY, plus any later
        // resizes, so a replayer can size its viewport. (We never resize the
        // surface itself — this is a passive recorder.)
        if let size = AttachClient.ttySize() {
            writer.append(.resize(timeMs: writer.nowMs(), rows: size.rows, cols: size.cols))
            installResizeHandler()
        }
        installInterruptHandler()

        fputs("harness-cli record: recording surface \(surfaceID) → \(writer.path) (Ctrl-C to stop)\n", harnessStderr)

        do {
            subscription = try client.subscribeSurfaceOutput(
                surfaceID: surfaceID,
                label: "harness-cli record",
                onData: { [weak self] data, _ in
                    guard let self else { return }
                    self.writer.append(.output(timeMs: self.writer.nowMs(), data: data))
                    if self.display { Self.writeOut(data) }
                },
                onEnd: { [weak self] in self?.stop() }
            )
        } catch {
            fputs("harness-cli record: subscribe failed: \(error)\n", harnessStderr)
            _ = writer.close()
            return 1
        }

        done.wait()

        subscription?.cancel()
        sigintSource?.cancel()
        sigwinchSource?.cancel()
        let summary = writer.close()
        let seconds = Double(summary.durationMs) / 1000
        fputs(String(format: "harness-cli record: wrote %d events (%.1fs) → %@\n",
                     summary.eventCount, seconds, writer.path), harnessStderr)
        return 0
    }

    private func stop() {
        stopLock.lock()
        let already = stopped
        stopped = true
        stopLock.unlock()
        guard !already else { return }
        done.signal()
    }

    private func installInterruptHandler() {
        // Trap SIGINT so Ctrl-C stops recording cleanly (flush + close) instead
        // of killing the process and truncating the file mid-line.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in self?.stop() }
        source.resume()
        sigintSource = source
    }

    private func installResizeHandler() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self, let size = AttachClient.ttySize() else { return }
            self.writer.append(.resize(timeMs: self.writer.nowMs(), rows: size.rows, cols: size.cols))
        }
        source.resume()
        sigwinchSource = source
    }

    private static func writeOut(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return
            }
        }
    }
}

// MARK: - Writer

/// Serializes recording-event appends to the output file and owns the monotonic
/// recording clock. `append` is called from the subscription queue (output) and
/// the SIGWINCH handler queue (resize), so every write is guarded by a lock to
/// keep the file handle and line ordering race-free.
private final class RecordingWriter: @unchecked Sendable {
    let path: String

    private let handle: FileHandle
    private let startNanos: UInt64
    private let lock = NSLock()
    private var eventCount = 0
    private var lastTimeMs = 0
    private var closed = false

    init(path: String) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        // Truncate/create the file, then open a handle for streaming appends.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: url)
        self.startNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Milliseconds since recording start, on a monotonic clock.
    func nowMs() -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
        return Int(elapsed / 1_000_000)
    }

    func append(_ event: RecordingEvent) {
        guard let line = try? TerminalRecordingCodec.encodeLine(event) else { return }
        let bytes = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            try handle.write(contentsOf: bytes)
            eventCount += 1
            if let t = event.timeMs { lastTimeMs = t }
        } catch {
            // A write failure (disk full, etc.) shouldn't crash the recorder;
            // stop appending and let the session wind down on its own.
            closed = true
        }
    }

    struct Summary {
        let eventCount: Int
        let durationMs: Int
    }

    @discardableResult
    func close() -> Summary {
        lock.lock()
        defer { lock.unlock() }
        let summary = Summary(eventCount: eventCount, durationMs: lastTimeMs)
        guard !closed else { return summary }
        closed = true
        try? handle.close()
        return summary
    }
}
