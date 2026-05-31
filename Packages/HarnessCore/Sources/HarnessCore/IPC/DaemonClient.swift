import Darwin
import Foundation

/// Synchronous IPC client. @unchecked Sendable: stateless between calls (each request
/// opens and closes its own socket) and all calls funnel through the serial `queue`.
public final class DaemonClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-client")

    public init() {}

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
        // Validate before opening the fd so an over-long path can't leak a socket — and so a deep
        // HARNESS_HOME fails clearly instead of `strncpy`-truncating to the wrong socket.
        let path = try HarnessPaths.validatedSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonClientError.connectionFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, 104)
            }
        }
        // connect() can be interrupted by a signal (EINTR). For a blocking AF_UNIX stream socket
        // the connect completes synchronously, so retry on EINTR rather than spuriously failing.
        var connected: Int32 = -1
        repeat {
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while connected != 0 && errno == EINTR
        guard connected == 0 else {
            close(fd)
            throw DaemonClientError.connectionFailed
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
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
        let bytes = [UInt8](payload)
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
        shutdown(fd, SHUT_RDWR)
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
                    let reply: IPCReply?
                    do { reply = try IPCCodec.decodeReply(from: &buffer) }
                    catch { break outer } // oversized/garbage frame — unrecoverable on a stream
                    guard let reply else { break }
                    onResponse(reply.response)
                }
            }
            if let self {
                self.lock.lock()
                self.finished = true
                self.lock.unlock()
            }
            close(fd)
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
