#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CHarnessSys
import Foundation
import HarnessCore

/// Connects a real TTY to a daemon-owned surface for the lifetime of the
/// foreground process — the user's keystrokes flow to the shell, the shell's
/// output appears in their terminal, and detaching with the configured
/// key sequence leaves the session running for later reattach.
///
/// Implementation notes:
/// - Two sockets are used. A persistent `DaemonSubscription` carries push
///   output from the daemon plus this client's PTY size votes (the daemon keys
///   votes by fd, so they must ride the long-lived connection to hold while
///   attached; the `.ok` acks come back interleaved and are ignored); a
///   synchronous `DaemonClient` is used for stdin `sendData` and final
///   `detachSurface`.
/// - The local TTY is switched to raw mode for the duration of the session and
///   restored on every exit path (normal detach, signal, error).
/// - The detach key sequence is configurable (default `Ctrl-A d`). The matcher
///   tracks state across reads so the prefix can be split across two reads.
public enum AttachClient {
    public struct Configuration {
        /// Bytes that, when observed in stdin, trigger a clean detach. Defaults
        /// to `0x01 0x64` — Ctrl-A followed by `d`. The bytes are consumed
        /// (never forwarded to the shell) only when the full sequence matches.
        public var detachSequence: [UInt8] = [0x01, 0x64]
        /// Human-readable label sent via `identifyClient`. Shows up in
        /// `harness-cli list-clients`.
        public var label: String = "harness-cli attach"
        public init() {}
    }

    public static func run(
        surfaceID: String,
        configuration: Configuration = Configuration(),
        endpoint: Endpoint = .localControlSocket
    ) throws -> Int32 {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            fputs("harness-cli attach: stdin/stdout must be a TTY\n", harnessStderr)
            return 64
        }
        let client = DaemonClient(endpoint: endpoint)

        let session = LiveSession(client: client, surfaceID: surfaceID, configuration: configuration)
        // Gap-free attach: subscribe FIRST (buffering live output), then replay scrollback to the
        // local TTY (still cooked — raw mode is off here), then flush the buffered live frames
        // deduped against the replay boundary. This closes the window where output appended between
        // the old replay snapshot and the separate subscribe was persisted but never streamed.
        do {
            try session.connect()
        } catch {
            fputs("\nharness-cli attach: \(error)\n", harnessStderr)
            return 1
        }

        let original = enterRawMode()
        defer { restoreTerminalMode(original) }

        do {
            try session.run()
        } catch {
            fputs("\nharness-cli attach: \(error)\n", harnessStderr)
            return 1
        }
        return 0
    }
}

// MARK: - Live session

private final class LiveSession: @unchecked Sendable {
    /// Max time (ms) buffered stdin bytes wait before flushing — bounds typing
    /// latency while letting paste bursts coalesce. `poll` granularity is 1 ms.
    static let flushDelayMillis: Int32 = 2

    let client: DaemonClient
    let surfaceID: String
    let configuration: AttachClient.Configuration

    private var detachRequested = false
    private let detachLock = NSLock()
    private var subscription: DaemonSubscription?
    private var sigwinchSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    /// Self-pipe used to wake the stdin `poll(2)` loop when the subscription
    /// ends or SIGTERM lands. The read end is polled alongside stdin.
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    init(client: DaemonClient, surfaceID: String, configuration: AttachClient.Configuration) {
        self.client = client
        self.surfaceID = surfaceID
        self.configuration = configuration
    }

    /// Subscribe + replay, gap-free. Run BEFORE raw mode so the replayed history is written to the
    /// cooked TTY (matching the prior behavior). The output subscription is on its own socket; as
    /// data arrives it's copied straight to stdout — no interpretation; the daemon emits raw bytes.
    func connect() throws {
        try installWakePipe()
        installSignalHandlers()
        subscription = try client.attachReplayingSurfaceOutput(
            surfaceID: surfaceID,
            label: configuration.label,
            onReplay: { [weak self] text in
                if !text.isEmpty, let data = text.data(using: .utf8) { self?.writeOut(data) }
            },
            onData: { [weak self] data, _ in self?.writeOut(data) },
            onEnd: { [weak self] in
                // Daemon closed the stream — surface exited or daemon died. Wake
                // the stdin loop so attach exits without leaving the TTY in raw mode.
                self?.requestDetach()
            }
        )
    }

    func run() throws {
        guard let sub = subscription else { return }

        // Establish this client's size vote on the subscription fd, where it holds
        // until detach. (A one-shot `.resizeSurface` request loses its vote the
        // moment its socket closes, so a smaller attach client couldn't keep a
        // larger GUI client from enlarging the PTY out from under it.)
        if let size = AttachClient.ttySize() {
            sub.resize(surfaceID, rows: size.rows, cols: size.cols)
        }

        // stdin loop — `poll(2)` on (stdin, wakeRead) so a detach request from
        // any thread interrupts the read promptly. Forwarded bytes are coalesced
        // by `AttachInputBatcher` so a large paste burst becomes a few large
        // `sendData` requests instead of one per read, without delaying typing
        // or the detach sequence.
        func send(_ data: Data?) {
            guard let data, !data.isEmpty else { return }
            _ = try? client.request(.sendData(surfaceID: surfaceID, data: data), timeout: 1)
        }
        var batcher = AttachInputBatcher(detachSequence: configuration.detachSequence)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var fds: [pollfd] = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            if shouldExit() { send(batcher.drain()); break }
            // Block indefinitely while idle; once bytes are buffered, wait at
            // most `flushDelayMillis` so a paste keeps coalescing but a lone
            // keystroke is flushed almost immediately.
            let timeout: Int32 = batcher.hasPending ? Self.flushDelayMillis : -1
            let ready = fds.withUnsafeMutableBufferPointer { ptr -> Int32 in
                poll(ptr.baseAddress, nfds_t(ptr.count), timeout)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                send(batcher.drain())
                break
            }
            if ready == 0 {
                // Flush timeout elapsed with buffered bytes — send and resume
                // blocking. (Only reachable while `hasPending`.)
                send(batcher.drain())
                continue
            }
            if (fds[1].revents & Int16(POLLIN)) != 0 {
                var drain = [UInt8](repeating: 0, count: 32)
                _ = read(wakeRead, &drain, drain.count)
                // onEnd / SIGTERM set the flag — handled at the top of the loop.
                continue
            }
            guard (fds[0].revents & Int16(POLLIN)) != 0 else { continue }
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n == 0 { send(batcher.drain()); break } // stdin closed
            if n < 0 {
                if errno == EINTR { continue }
                send(batcher.drain())
                break
            }
            let outcome = batcher.ingest(buffer[0..<n])
            send(outcome.flush)
            if outcome.detach {
                requestDetach()
                break
            }
        }

        // Tear down.
        sub.cancel()
        _ = try? client.request(.detachSurface(surfaceID: surfaceID), timeout: 1)
        sigwinchSource?.cancel()
        sigtermSource?.cancel()
        if wakeRead >= 0 { close(wakeRead) }
        if wakeWrite >= 0 { close(wakeWrite) }
    }

    private func installWakePipe() throws {
        var fds: [Int32] = [-1, -1]
        guard fds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else {
            throw NSError(domain: "AttachClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "pipe() failed"])
        }
        wakeRead = fds[0]
        wakeWrite = fds[1]
        // Non-blocking so a flood of wakes doesn't stall the writer.
        _ = harness_set_nonblocking(wakeWrite)
    }

    private func shouldExit() -> Bool {
        detachLock.lock()
        defer { detachLock.unlock() }
        return detachRequested
    }

    private func requestDetach() {
        detachLock.lock()
        let already = detachRequested
        detachRequested = true
        detachLock.unlock()
        guard !already, wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private func writeOut(_ data: Data) {
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

    private func installSignalHandlers() {
        // Catch SIGWINCH so the daemon resizes the PTY in sync with our terminal.
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winch.setEventHandler { [weak self] in
            guard let self, let size = AttachClient.ttySize() else { return }
            // Over the subscription, not a one-shot request: the vote must stay on
            // the persistent fd so it keeps holding the smallest-size contract.
            self.subscription?.resize(self.surfaceID, rows: size.rows, cols: size.cols)
        }
        winch.resume()
        sigwinchSource = winch

        // SIGTERM → request detach so the terminal mode is restored cleanly.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [weak self] in self?.requestDetach() }
        term.resume()
        sigtermSource = term

        // We do NOT trap SIGINT — Ctrl-C must flow through to the shell. The
        // detach sequence is the documented way to exit attach.
    }
}

// MARK: - TTY helpers

extension AttachClient {
    struct TTYSize {
        let rows: UInt16
        let cols: UInt16
    }

    static func ttySize() -> TTYSize? {
        var rows: UInt16 = 0
        var cols: UInt16 = 0
        guard harness_pty_get_winsize(STDOUT_FILENO, &rows, &cols) == 0 else { return nil }
        return TTYSize(rows: rows, cols: cols)
    }

    static func enterRawMode() -> termios {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        // Keep ISIG off — we want Ctrl-C / Ctrl-Z to pass through to the daemon.
        // cfmakeraw already turns off ICANON, ECHO, ICRNL, OPOST, ISIG, etc.
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        return original
    }

    static func restoreTerminalMode(_ original: termios) {
        var mode = original
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &mode)
    }
}
