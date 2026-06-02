#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Synchronous IPC client. @unchecked Sendable: stateless between calls (each request
/// opens and closes its own socket) and all calls funnel through the serial `queue`.
public final class DaemonClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-client")
    /// Where this client connects. Defaults to the local daemon's control socket, so every existing
    /// `DaemonClient()` call is unchanged; a remote client passes the local end of an SSH tunnel.
    private let endpoint: Endpoint

    public init(endpoint: Endpoint = .localControlSocket) {
        self.endpoint = endpoint
    }

    public func request(_ ipcRequest: IPCRequest, timeout: TimeInterval = 2) throws -> IPCResponse {
        try queue.sync {
            try self.performRequest(ipcRequest, timeout: timeout)
        }
    }

    @discardableResult
    public func subscribeSurfaceOutput(
        surfaceID: String,
        label: String? = nil,
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        let fd = try connectSocket()
        let payload = try IPCCodec.encode(IPCEnvelope(request: .subscribeSurfaceOutput(surfaceID: surfaceID, label: label)))
        do { try writeAll(payload, to: fd) } catch { close(fd); throw error } // EINTR-safe, looped
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(onData: onData, onEnd: onEnd)
        return subscription
    }

    /// Long-lived snapshot subscription: invokes `onRevision` each time the daemon
    /// pushes a `snapshotChanged(revision:)` frame (i.e. the layout committed). Replaces
    /// the compositor's structure poll.
    @discardableResult
    public func subscribeSnapshot(
        label: String? = nil,
        onRevision: @escaping @Sendable (Int) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        let fd = try connectSocket()
        let payload = try IPCCodec.encode(IPCEnvelope(request: .subscribeSnapshot(label: label)))
        do { try writeAll(payload, to: fd) } catch { close(fd); throw error } // EINTR-safe, looped
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(
            onResponse: { response in
                if case let .snapshotChanged(revision) = response { onRevision(revision) }
            },
            onEnd: onEnd
        )
        return subscription
    }

    private func performRequest(_ ipcRequest: IPCRequest, timeout: TimeInterval) throws -> IPCResponse {
        let fd = try connectSocket()
        defer { close(fd) }

        let payload = try IPCCodec.encode(IPCEnvelope(request: ipcRequest))
        try writeAll(payload, to: fd)

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var temp = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard try waitForReadable(fd: fd, timeout: remaining) else { break }
            let count = read(fd, &temp, temp.count)
            if count > 0 {
                buffer.append(contentsOf: temp.prefix(count))
                if let reply = try IPCCodec.decodeReply(from: &buffer) {
                    return reply.response
                }
            } else if count == 0 {
                // Peer closed. A complete (possibly large, multi-read) reply may already be
                // buffered — try one last decode before giving up, so we don't drop it.
                if let reply = try? IPCCodec.decodeReply(from: &buffer) {
                    return reply.response
                }
                break
            }
        }
        throw DaemonClientError.timeout
    }

    private func connectSocket() throws -> Int32 {
        // Establishing the byte stream is the only transport-specific step; the framing and read
        // loop are endpoint-agnostic. `EndpointConnector` handles validation + connect for the
        // local socket and (via an SSH tunnel) a remote one. Let its specific error propagate
        // (e.g. `.pathTooLong` with the offending path) instead of flattening it to a generic
        // `connectionFailed` — that detail is what tells a user how to fix it.
        try EndpointConnector.connect(endpoint)
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = write(fd, base.advanced(by: written), raw.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                throw DaemonClientError.writeFailed
            }
        }
    }

    private func waitForReadable(fd: Int32, timeout: TimeInterval) throws -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMS = max(0, Int32((timeout * 1000).rounded(.up)))
        while true {
            let result = poll(&pfd, 1, timeoutMS)
            if result > 0 {
                return (pfd.revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0
            }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw DaemonClientError.connectionFailed
        }
    }
}

/// Live output stream over a dedicated socket.
///
/// The read loop runs a *blocking* `read(fd)` on `queue`, so it parks that queue for the
/// subscription's whole lifetime (an idle daemon keeps the socket open, so `read()` does
/// not return on its own). Cancellation therefore must NOT funnel through `queue` — a
/// `queue.sync` would wait behind the read loop forever, and the `close(fd)` that would
/// wake the loop is exactly what's trapped behind it. That self-deadlock froze the main
/// thread whenever a tab/pane closed and its `TerminalHostView` deinit called `cancel()`.
///
/// Instead `cancel()` flips a lock-guarded flag and `shutdown(2)`s the socket to wake the
/// blocked `read()`. The read loop then observes EOF, exits, and owns the final `close(fd)`
/// so the descriptor is closed exactly once and never while another thread might read it.
///
/// @unchecked Sendable: `fd` is immutable; `cancelled`/`finished` are guarded by `lock`.
public final class DaemonSubscription: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-subscription")
    private let lock = NSLock()
    /// Serializes writes to the single full-duplex `fd` so concurrent writers (keystroke `sendInput`
    /// + `detachSurface`) can never interleave bytes mid-frame. Distinct from `lock` (which guards
    /// the cancel flags) so a blocking write can't wedge `cancel()`. Uncontended in practice —
    /// input is already serialized upstream on the host's IO queue.
    private let writeLock = NSLock()
    private var cancelled = false
    private var finished = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Detach this subscription's surface on the daemon **without closing the connection** —
    /// releases only this client's hold (its subscription + size vote) on `surfaceID`, leaving
    /// the PTY and every other client running, so the surface can be re-grabbed later. Use
    /// `cancel()` instead to also tear down the connection. Safe to call from any thread (the
    /// socket is full-duplex; the read loop runs on its own queue).
    public func detachSurface(_ surfaceID: String) {
        lock.lock(); let dead = cancelled || finished; lock.unlock()
        guard !dead,
              let payload = try? IPCCodec.encode(IPCEnvelope(request: .detachSurface(surfaceID: surfaceID)))
        else { return }
        writeFrame(payload)
    }

    /// Write keystroke/paste bytes to `surfaceID` over this persistent full-duplex connection,
    /// fire-and-forget (no reply). Replaces the per-keystroke `DaemonClient.request(.sendData:)`,
    /// which opened a fresh socket and blocked for the `.ok`. Safe from any thread — the read loop
    /// runs on its own queue and only reads; the `cancelled`/`finished` guard (same as
    /// `detachSurface`) prevents writing to a torn-down fd.
    public func sendInput(_ data: Data, surfaceID: String) {
        lock.lock(); let dead = cancelled || finished; lock.unlock()
        guard !dead,
              let payload = try? IPCCodec.encodeInputFrame(surfaceID: surfaceID, payload: data)
        else { return }
        writeFrame(payload)
    }

    /// Write one complete framed message to `fd`, retrying partial/interrupted writes. Holds
    /// `writeLock` for the whole frame so two writers can't interleave bytes. A hard error (peer
    /// gone) just stops — the read loop independently observes EOF and tears down.
    private func writeFrame(_ payload: Data) {
        let bytes = [UInt8](payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        // The read loop sets `finished` and closes `fd` under `writeLock` on teardown. Holding it
        // here means either that close already happened (bail — the fd is closed and its number may
        // be recycled) or it can't begin until we're done. Re-checking under `lock` (not just in the
        // sendInput/detachSurface entry points) closes the window where `cancel()` + the read-loop
        // close raced an in-flight write into a stale descriptor.
        lock.lock(); let dead = cancelled || finished; lock.unlock()
        guard !dead else { return }
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: off), bytes.count - off) }
            if n > 0 { off += n }
            else if n < 0, errno == EINTR || errno == EAGAIN { continue }
            else { break }
        }
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !finished else { return }
        cancelled = true
        // Wake the blocked read() without touching `queue`. Holding `lock` while we call
        // shutdown — paired with the read loop setting `finished` under the same lock
        // before it closes — guarantees `fd` is still open here, so we never shutdown a
        // descriptor the loop already closed and the OS may have recycled.
        shutdown(fd, Int32(SHUT_RDWR)) // SHUT_RDWR is `Int` on Glibc, `Int32` on Darwin
    }

    /// Output-stream convenience: forwards `.data` frames to `onData`.
    func start(
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)?
    ) {
        start(
            onResponse: { if case let .data(data, sequence) = $0 { onData(data, sequence) } },
            onEnd: onEnd
        )
    }

    /// Generic read loop: decodes every pushed reply and forwards its response. Used by
    /// both output (`.data`) and snapshot (`.snapshotChanged`) subscriptions.
    func start(
        onResponse: @escaping @Sendable (IPCResponse) -> Void,
        onEnd: (@Sendable () -> Void)?
    ) {
        queue.async { [weak self, fd] in
            var buffer = Data()
            var temp = [UInt8](repeating: 0, count: 65_536)
            outer: while true {
                let count = read(fd, &temp, temp.count)
                if count <= 0 { break }
                buffer.append(contentsOf: temp.prefix(count))
                while true {
                    let decoded: IPCCodec.DecodedReplyFrame?
                    do { decoded = try IPCCodec.decodeReplyOrData(from: &buffer) }
                    catch { break outer } // oversized/garbage frame — unrecoverable on a stream
                    guard let decoded else { break }
                    switch decoded {
                    case let .reply(response):
                        onResponse(response)
                        // A subscription connection only carries `.ok`/`.error` acks before `.data`
                        // flows. An `.error` means the subscribe was rejected (e.g. surface gone) and
                        // the daemon leaves the fd open — so the read loop would block forever and
                        // `onEnd` would never fire. Treat it as fatal (like EOF) so callers (GUI
                        // reconnect, CLI attach) finish and can retry instead of hanging.
                        if case .error = response { break outer }
                    // Binary output frame → present it as `.data` so `onData` consumers (app +
                    // every CLI attach client) are unchanged and get the no-base64 fast path free.
                    case let .output(data, sequence): onResponse(.data(data, sequence: sequence))
                    }
                }
            }
            if let self {
                // Close `fd` under `writeLock` so an in-flight `writeFrame` completes first and any
                // later writer sees `finished` and bails — never a write into a closed/recycled fd.
                // Liveness: a blocked write here is released by `cancel()`'s shutdown or the peer's
                // close (EPIPE), so this never hangs teardown.
                self.writeLock.lock()
                self.lock.lock()
                self.finished = true
                self.lock.unlock()
                close(fd)
                self.writeLock.unlock()
            } else {
                close(fd)
            }
            onEnd?()
        }
    }

    deinit {
        cancel()
    }
}

public enum DaemonClientError: Error, CustomStringConvertible {
    case connectionFailed
    case writeFailed
    case timeout
    case unexpectedResponse

    public var description: String {
        switch self {
        case .connectionFailed: "Could not connect to HarnessDaemon"
        case .writeFailed: "Failed to write IPC request"
        case .timeout: "HarnessDaemon request timed out"
        case .unexpectedResponse: "Unexpected response from HarnessDaemon"
        }
    }
}
