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
    private let capabilityLock = NSLock()
    private var attachStreamSupported: Bool?

    public init(endpoint: Endpoint = .localControlSocket) {
        self.endpoint = endpoint
    }

    public func request(_ ipcRequest: IPCRequest, timeout: TimeInterval = 2) throws -> IPCResponse {
        let deadline = SocketDeadline(timeout: timeout)
        return try queue.sync {
            try self.performRequest(ipcRequest, deadline: deadline)
        }
    }

    @discardableResult
    public func subscribeSurfaceOutput(
        surfaceID: String,
        label: String? = nil,
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        let deadline = SocketDeadline(timeout: 2)
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        let payload = try IPCCodec.encode(IPCEnvelope(request: .subscribeSurfaceOutput(surfaceID: surfaceID, label: label)))
        do { try deadline.write(payload, to: fd) } catch { close(fd); throw error } // EINTR-safe, looped
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(onData: onData, onEnd: onEnd)
        if RemoteAttach.isTunnel(endpoint) { subscription.presentAsTunnel() }
        return subscription
    }

    /// Gap-free attach: subscribe FIRST (buffering live output), then replay scrollback, deliver the
    /// replayed history via `onReplay`, flush the buffered live frames DEDUPED against the replay's
    /// end sequence, and stream the rest via `onData`. This closes the replay→subscribe window where
    /// bytes appended between the replay snapshot and handler registration were persisted but never
    /// delivered (the daemon does no backfill).
    ///
    /// Ordering is preserved end to end: live frames buffer inside the subscription until
    /// `flushBuffered` runs, so `onReplay` (history) is always delivered before any live byte, and
    /// the flush + live frames share one ordered sink. The caller's `onReplay`/`onData` decide the
    /// delivery thread (e.g. the GUI hops to main); this method only guarantees the *call* order.
    ///
    /// Compatibility: uses `replayScrollbackSequenced` to learn the dedup boundary. An old daemon
    /// rejects that request (`.error`), so we fall back to plain `replayScrollback`. Without a
    /// boundary the buffered frames can't be deduped against the replay — and that replay (taken
    /// after the subscribe) already covers them — so on the old-daemon path we DISCARD the buffer
    /// and restore the original replay-then-subscribe ordering: no double-delivery, at the cost of
    /// the small historical gap an old daemon's missing boundary makes unavoidable. The probe, not
    /// just the dedup, decides ordering. `fromSequence` is passed through (nil = full history).
    @discardableResult
    public func attachReplayingSurfaceOutput(
        surfaceID: String,
        label: String? = nil,
        fromSequence: UInt64? = nil,
        readOnly: Bool = false,
        replayTimeout: TimeInterval = 5,
        onReplay: @escaping @Sendable (String) -> Void,
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        // 1. Subscribe first, buffering live frames (do NOT deliver yet).
        let deadline = SocketDeadline(timeout: 2)
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        let subscribe: IPCRequest = readOnly
            ? .subscribeSurfaceOutputReadOnly(surfaceID: surfaceID, label: label)
            : .subscribeSurfaceOutput(surfaceID: surfaceID, label: label)
        let payload = try IPCCodec.encode(IPCEnvelope(request: subscribe))
        do { try deadline.write(payload, to: fd) } catch { close(fd); throw error }
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(onData: onData, onEnd: onEnd, buffered: true)

        // 2. Replay AFTER the subscription is live, so every byte the replay omits is already in the
        //    buffer. Prefer the sequenced replay (gives the dedup boundary); on an old daemon that
        //    rejects it, fall back to the plain replay — and remember we got NO usable boundary.
        var replayText = ""
        var endSequence: UInt64 = 0
        var haveBoundary = false
        if case let .replayResult(text, end)? = try? request(.replayScrollbackSequenced(surfaceID: surfaceID, fromSequence: fromSequence), timeout: replayTimeout) {
            replayText = text
            endSequence = end
            haveBoundary = true
        } else if case let .text(text)? = try? request(.replayScrollback(surfaceID: surfaceID, fromSequence: fromSequence), timeout: replayTimeout) {
            replayText = text // legacy daemon: no usable boundary
        }

        // 3. Deliver the replayed history, THEN release the buffered live frames. With a real
        //    boundary, flush deduped (gap-free). Without one (old daemon), discard the buffer and
        //    fall back to replay-then-subscribe ordering — the replay already covers the buffered
        //    tail, so flushing it would double-deliver. The caller's sink keeps both in one order.
        if RemoteAttach.isTunnel(endpoint) { subscription.presentAsTunnel() }
        onReplay(replayText)
        if haveBoundary {
            subscription.flushBuffered(droppingSequencesBelow: endSequence, onData: onData)
        } else {
            subscription.discardBufferedAndDeliverDirect()
        }
        return subscription
    }

    /// Where a client's terminal stands in a daemon's output: the daemon's epoch and the next
    /// sequence it expects. Handing it back on reconnect resumes instead of repainting.
    public struct AttachPoint: Equatable, Sendable {
        public var epoch: String
        public var sequence: UInt64
        public init(epoch: String, sequence: UInt64) {
            self.epoch = epoch
            self.sequence = sequence
        }
    }

    /// How an attach starts. With `resync` the caller resets its terminal before the bytes
    /// that follow; otherwise they continue where `resume` left off. Bytes below `historyEnd`
    /// are history (feed them as a replay: no bells or notifications); `point` is nil on a
    /// daemon that can't resume. A resync from a current daemon carries `screen`, the visible
    /// screen at `historyEnd` as VT bytes, to paint before the history.
    public struct AttachStart: Equatable, Sendable {
        public var resync: Bool
        public var historyEnd: UInt64
        public var point: AttachPoint?
        public var screen: Data?
        public var replaySizes: [ReplaySize]?
    }

    /// Attach to a surface's output with its history. On a daemon with `attach-stream` this
    /// is one request: the history streams as binary frames (no JSON size cap) and a known
    /// `resume` point sends only what was missed. An older daemon gets subscribe + replay.
    /// `onStart` runs before any `onData`, on the subscription's read thread.
    @discardableResult
    public func attach(
        surfaceID: String,
        label: String? = nil,
        readOnly: Bool = false,
        resume: AttachPoint? = nil,
        onStart: @escaping @Sendable (AttachStart) -> Void,
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onOwnership: (@Sendable (SizeOwnership) -> Void)? = nil,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        guard supportsAttachStream() else {
            // The replay is history at sequence 0; live frames count from 1 so none is taken for it.
            return try attachReplayingSurfaceOutput(
                surfaceID: surfaceID, label: label, readOnly: readOnly,
                onReplay: { text in
                    onStart(AttachStart(resync: true, historyEnd: 1, point: nil))
                    if !text.isEmpty { onData(Data(text.utf8), 0) }
                },
                onData: { data, sequence in onData(data, max(sequence, 1)) },
                onEnd: onEnd
            )
        }
        let request = AttachRequest(
            surfaceID: surfaceID, label: label, readOnly: readOnly, history: true,
            fromSequence: resume?.sequence, epoch: resume?.epoch, inputErrors: true
        )
        return try attachStream(request, onAttached: { reply in
            onStart(AttachStart(
                resync: reply.resync, historyEnd: reply.endSequence,
                point: AttachPoint(epoch: reply.epoch, sequence: reply.endSequence), screen: reply.screen,
                replaySizes: reply.replaySizes
            ))
        }, onData: onData, onOwnership: onOwnership, onEnd: onEnd)
    }

    /// The `attachStream` request itself: `.attached`, then output frames. `harness-cli attach`
    /// uses it screen-only (`history: false`), painting `reply.screen`.
    @discardableResult
    public func attachStream(
        _ request: AttachRequest,
        onAttached: @escaping @Sendable (AttachReply) -> Void,
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onOwnership: (@Sendable (SizeOwnership) -> Void)? = nil,
        onEnd: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (String) -> Void)? = nil
    ) throws -> DaemonSubscription {
        let deadline = SocketDeadline(timeout: 2)
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        let payload = try IPCCodec.encode(IPCEnvelope(request: .attachStream(request)))
        do { try deadline.write(payload, to: fd) } catch { close(fd); throw error }
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(onResponse: { [weak subscription] response in
            switch response {
            case let .attached(reply):
                subscription?.setInputErrorSupport(reply.inputErrors == true)
                onAttached(reply)
            case let .data(data, sequence): onData(data, sequence)
            case let .sizeOwnership(ownership): onOwnership?(ownership)
            case let .error(message): onError?(message)
            default: break
            }
        }, onEnd: onEnd)
        if RemoteAttach.isTunnel(endpoint) { subscription.presentAsTunnel() }
        return subscription
    }

    /// Whether the daemon has `attach-stream`. Remembered once the daemon answers; a probe
    /// that fails (daemon starting, tunnel not up) is asked again next time.
    public func supportsAttachStream() -> Bool {
        capabilityLock.lock()
        if let known = attachStreamSupported { capabilityLock.unlock(); return known }
        capabilityLock.unlock()
        guard case let .daemonStats(stats)? = try? request(.daemonStats, timeout: 2) else { return false }
        let supported = stats.capabilities?.contains(DaemonStats.attachStream) == true
        capabilityLock.lock()
        attachStreamSupported = supported
        capabilityLock.unlock()
        return supported
    }

    /// Long-lived snapshot subscription: invokes `onRevision` each time the daemon
    /// pushes a `snapshotChanged(revision:)` frame (i.e. the layout committed). Replaces
    /// the compositor's structure poll.
    @discardableResult
    public func subscribeSnapshot(
        label: String? = nil,
        onRevision: @escaping @Sendable (Int) -> Void,
        onDirective: (@Sendable (ClientDirective) -> Void)? = nil,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        let deadline = SocketDeadline(timeout: 2)
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        let payload = try IPCCodec.encode(IPCEnvelope(request: .subscribeSnapshot(label: label, directives: onDirective != nil)))
        do { try deadline.write(payload, to: fd) } catch { close(fd); throw error } // EINTR-safe, looped
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(
            onResponse: { response in
                switch response {
                case let .snapshotChanged(revision): onRevision(revision)
                case let .clientDirective(directive): onDirective?(directive)
                default: break
                }
            },
            onEnd: onEnd
        )
        return subscription
    }

    /// Block until the follow socket closes, delivering each NDJSON event. `.ok` is the
    /// subscription ack and is not an event. A daemon error ends the call.
    public func followEvents(
        sessionID: String?,
        includeServer: Bool,
        onEvent: (FollowEvent) -> Void
    ) throws {
        let deadline = SocketDeadline(timeout: 2)
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        defer { close(fd) }
        let payload = try IPCCodec.encode(
            IPCEnvelope(request: .subscribeEvents(sessionID: sessionID, includeServer: includeServer))
        )
        try deadline.write(payload, to: fd)
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 65_536)
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, -1)
            if polled < 0, errno == EINTR { continue }
            if polled < 0 || ready.revents & Int16(POLLNVAL) != 0 { throw DaemonClientError.connectionFailed }
            let count = read(fd, &temp, temp.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw DaemonClientError.connectionFailed
            }
            buffer.append(contentsOf: temp.prefix(count))
            while true {
                let reply: IPCReply?
                do {
                    reply = try IPCCodec.decodeReply(from: &buffer)
                } catch {
                    throw DaemonClientError.unexpectedResponse
                }
                guard let reply else { break }
                switch reply.response {
                case let .follow(line):
                    if let event = try? JSONDecoder().decode(FollowEvent.self, from: Data(line.utf8)) {
                        onEvent(event)
                    }
                case let .error(message):
                    throw FollowStreamError(message: message)
                case .ok:
                    break
                default:
                    break
                }
            }
        }
    }

    private func performRequest(_ ipcRequest: IPCRequest, deadline: SocketDeadline) throws -> IPCResponse {
        let fd = try EndpointConnector.connect(endpoint, deadline: deadline)
        defer { close(fd) }
        let payload = try IPCCodec.encode(IPCEnvelope(request: ipcRequest))
        try deadline.write(payload, to: fd)
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 65_536)
        while true {
            try deadline.wait(fd, events: Int16(POLLIN))
            let count = read(fd, &temp, temp.count)
            if count > 0 {
                buffer.append(contentsOf: temp.prefix(count))
                if let reply = try IPCCodec.decodeReply(from: &buffer) { return reply.response }
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw DaemonClientError.connectionFailed
            }
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

    /// Gap-free attach buffering. While `buffering` is true the output read loop stashes live
    /// `(data, sequence)` frames here instead of delivering them, so a subscription can be
    /// established BEFORE the scrollback replay is taken without the live frames racing ahead of
    /// the replayed history. `flushBuffered(droppingSequencesBelow:)` drains them in order — minus
    /// any whose sequence is already inside the replay — and switches to direct delivery. Guarded
    /// by `bufferLock` (distinct from `lock`/`writeLock`, which guard teardown/writes).
    private let bufferLock = NSLock()
    private var buffering = false
    private var pendingFrames: [(Data, UInt64)] = []
    /// Running byte total of `pendingFrames`, so the cap check stays O(1) on the read hot path.
    private var pendingBytes = 0
    /// Cap on buffered live output while a replay is outstanding. A flooding surface against a slow
    /// daemon could otherwise buffer the entire replay window (default 5 s) of output in memory.
    /// On overflow we drop the OLDEST buffered frames (a byte ring) to stay under the cap, set
    /// `bufferOverflowed`, and at flush time skip dedup — dropping-oldest broke buffer contiguity,
    /// so the replay-boundary dedup can no longer prove which frames are duplicates; delivering all
    /// remaining frames after the replay risks a momentary visible duplication but never drops live
    /// output, and bounds memory. A few MiB is far above any real terminal's per-replay-window
    /// output yet small enough that the worst-case flush is a single bounded `onData`.
    private static let maxPendingBufferBytes = 4 * 1024 * 1024
    /// Set once `pendingFrames` had to drop a frame to respect the cap (see above): tells
    /// `flushBuffered` to skip dedup and deliver everything that survived.
    private var bufferOverflowed = false

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

    private var inputErrorsSupported = false
    private var inputErrorHandler: (@Sendable (String) -> Void)?

    func setInputErrorSupport(_ supported: Bool) {
        lock.lock(); inputErrorsSupported = supported; lock.unlock()
    }

    public func setInputErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock(); inputErrorHandler = handler; lock.unlock()
    }

    /// A false result has an UNKNOWN delivery outcome. Never retry this mutation.
    /// Old daemons use their existing JSON request/reply path; binary input requires the
    /// attach handshake's explicit agreement to report admission failures.
    @discardableResult
    public func sendInput(_ data: Data, surfaceID: String) -> Bool {
        lock.lock()
        let dead = cancelled || finished
        let binary = inputErrorsSupported
        lock.unlock()
        guard !dead else { return false }
        let payload = binary
            ? try? IPCCodec.encodeInputFrame(surfaceID: surfaceID, payload: data)
            : try? IPCCodec.encode(IPCEnvelope(request: .sendData(surfaceID: surfaceID, data: data)))
        guard let payload else { return false }
        return writeFrame(payload)
    }

    /// Mark this subscription as an SSH-tunneled client so a dropped forward emits
    /// `client.connection`. The `.ok` is ignored by the output read loop, same as a resize ack.
    func presentAsTunnel() {
        let request = IPCRequest.presentClient(
            kind: "client",
            version: HarnessVersion.short,
            uid: UInt32(getuid()),
            tunnel: true
        )
        guard let payload = try? IPCCodec.encode(IPCEnvelope(request: request)) else { return }
        writeFrame(payload)
    }

    /// Record this client's PTY size vote for `surfaceID` over the persistent connection. The
    /// daemon keys size votes by fd and drops them when the fd closes — so a vote sent through
    /// one-shot `DaemonClient.request(.resizeSurface:)` dies with its socket and multi-client
    /// smallest-size sizing degrades to last-resize-wins. Sending the vote on this connection
    /// ties its lifetime to the subscription: it holds while attached and is released exactly
    /// on `detachSurface`/disconnect, letting the surface grow back.
    ///
    /// Deliberately the plain JSON `.resizeSurface` request, NOT a new binary frame: every
    /// daemon (including older builds) already handles it per-fd on any connection, so this is
    /// compatible in both directions — a new binary magic would read as an oversized JSON
    /// length on an old daemon, which drops the connection. The daemon's `.ok` ack arrives
    /// interleaved with the output stream and is ignored by the read loop, exactly like
    /// `detachSurface`'s; resizes are far too infrequent for the ack to matter.
    public func resize(_ surfaceID: String, rows: UInt16, cols: UInt16, takeOwnership: Bool = false) {
        lock.lock(); let dead = cancelled || finished; lock.unlock()
        guard !dead,
              var payload = try? IPCCodec.encode(IPCEnvelope(request: .resizeSurface(surfaceID: surfaceID, rows: rows, cols: cols)))
        else { return }
        // Keep the vote and claim on the same socket, in order. A separate RPC can
        // reach the daemon before this subscription's size vote exists.
        if takeOwnership {
            guard let claim = try? IPCCodec.encode(IPCEnvelope(request: .takeSurface(surfaceID: surfaceID, clientID: nil))) else { return }
            payload.append(claim)
        }
        writeFrame(payload)
    }

    /// Write one complete framed message to `fd`, retrying partial/interrupted writes. Holds
    /// `writeLock` for the whole frame so two writers can't interleave bytes. A hard error (peer
    /// gone) just stops — the read loop independently observes EOF and tears down. Returns `true`
    /// iff every byte of the frame flushed; `false` on a torn-down subscription or a hard write
    /// error (the caller must report the uncertain delivery, without retrying). `detachSurface`/`resize` ignore the result.
    @discardableResult
    private func writeFrame(_ payload: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        // The read loop sets `finished` and closes `fd` under `writeLock` on teardown. Holding it
        // here means either that close already happened (bail — the fd is closed and its number may
        // be recycled) or it can't begin until we're done. Re-checking under `lock` (not just in the
        // sendInput/detachSurface entry points) closes the window where `cancel()` + the read-loop
        // close raced an in-flight write into a stale descriptor.
        lock.lock(); let dead = cancelled || finished; lock.unlock()
        guard !dead else { return false }
        do {
            try SocketDeadline(timeout: 2).write(payload, to: fd)
            return true
        } catch {
            // The outcome may be unknown. Close this stream and never retry its input.
            cancel()
            return false
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
    ///
    /// When `buffered` is true the loop starts in buffering mode (see `beginBuffering`): live frames
    /// are stashed until `flushBuffered(droppingSequencesBelow:)` releases them. The caller uses this
    /// to subscribe BEFORE the replay snapshot and then dedupe — closing the replay→subscribe gap.
    func start(
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)?,
        buffered: Bool = false
    ) {
        if buffered { beginBuffering() }
        start(
            onResponse: { [weak self] in
                guard case let .data(data, sequence) = $0 else { return }
                // While buffering, stash in order under `bufferLock`; the flush drains these and
                // flips to direct delivery atomically, so no frame is lost or reordered at the seam.
                if let self {
                    self.bufferLock.lock()
                    if self.buffering {
                        self.pendingFrames.append((data, sequence))
                        self.pendingBytes += data.count
                        // Bound the buffer: under a flood + slow replay, drop the OLDEST frames so
                        // memory stays capped. Dropping-oldest (not refusing the newest) keeps the
                        // freshest output; the `bufferOverflowed` flag makes the flush skip dedup so
                        // a dropped frame can never be mistaken for a kept one.
                        while self.pendingBytes > Self.maxPendingBufferBytes,
                              self.pendingFrames.count > 1 {
                            let evicted = self.pendingFrames.removeFirst()
                            self.pendingBytes -= evicted.0.count
                            self.bufferOverflowed = true
                        }
                        self.bufferLock.unlock()
                        return
                    }
                    self.bufferLock.unlock()
                }
                onData(data, sequence)
            },
            onEnd: onEnd
        )
    }

    /// Arm buffering before the read loop starts (called from `start(…, buffered: true)`).
    private func beginBuffering() {
        bufferLock.lock(); buffering = true; bufferLock.unlock()
    }

    /// Test-only: how many live frames are currently held in the buffer (before a flush). Lets a
    /// deterministic test wait for the read loop to stash all frames without timing guesswork.
    func bufferedFrameCountForTesting() -> Int {
        bufferLock.lock(); defer { bufferLock.unlock() }; return pendingFrames.count
    }

    /// Release buffered live frames in arrival order, dropping any whose sequence is already inside
    /// the replay (`sequence < endSequence`), then switch to direct delivery — all under `bufferLock`
    /// so a frame arriving mid-flush either lands in `pendingFrames` (drained here, in order) or is
    /// delivered directly after the flag flips, never both and never out of order. `onData` is the
    /// SAME closure the read loop forwards to, so flushed and live frames share one ordered sink.
    ///
    /// The surviving frames are CONCATENATED into a single `onData` call (their bytes are already in
    /// order, and the coalesced frame keeps its FIRST byte's sequence), so a large buffer
    /// flushes as ONE main-thread hop instead of one per frame — the per-frame `main.async` storm
    /// the old loop caused under a big buffer.
    ///
    /// If the buffer overflowed its byte cap (oldest frames were dropped to bound memory), dedup is
    /// SKIPPED: dropping-oldest broke buffer contiguity so `endSequence` can no longer prove which
    /// remaining frames are replay duplicates. Everything that survived is delivered after the
    /// replay — a momentary visible duplication is possible under that pathological flood, but no
    /// live output is lost and memory stayed bounded.
    ///
    /// Returns the number of frames dropped as duplicates (0 when overflowed / boundary 0).
    @discardableResult
    func flushBuffered(
        droppingSequencesBelow endSequence: UInt64,
        onData: @Sendable (Data, UInt64) -> Void
    ) -> Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let skipDedup = bufferOverflowed || endSequence == 0
        var dropped = 0
        var coalesced = Data()
        var firstSequence: UInt64 = 0
        for (data, sequence) in pendingFrames {
            if !skipDedup, sequence < endSequence { dropped += 1; continue }
            if coalesced.isEmpty { firstSequence = sequence }
            coalesced.append(data)
        }
        if !coalesced.isEmpty { onData(coalesced, firstSequence) }
        pendingFrames.removeAll(keepingCapacity: false)
        pendingBytes = 0
        bufferOverflowed = false
        buffering = false
        return dropped
    }

    /// Old-daemon attach path: a daemon too old to answer `replayScrollbackSequenced` gives no
    /// dedup boundary, so the buffered live frames can't be deduped against the plain replay text —
    /// and that replay (taken AFTER the subscribe) already covers the buffered tail, so flushing
    /// them re-shows the overlap. Restore the ORIGINAL replay-then-subscribe ordering instead:
    /// DROP everything buffered (it's a subset of the replay text, modulo the same tiny historical
    /// gap the pre-buffering code always had) and switch to direct delivery for subsequent live
    /// frames. No double-delivery; the only cost is the historical gap an old daemon can't avoid.
    /// Like `flushBuffered`, runs under `bufferLock` so the flag flip and the buffer drop are atomic
    /// against a frame arriving mid-call.
    func discardBufferedAndDeliverDirect() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        pendingFrames.removeAll(keepingCapacity: false)
        pendingBytes = 0
        bufferOverflowed = false
        buffering = false
    }

    /// Generic read loop: decodes every pushed reply and forwards its response. Used by
    /// both output (`.data`) and snapshot (`.snapshotChanged`) subscriptions.
    func start(
        onResponse: @escaping @Sendable (IPCResponse) -> Void,
        onEnd: (@Sendable () -> Void)?
    ) {
        queue.async { [weak self, fd] in
            // `IPCReadBuffer`, not `Data`: this loop runs for the life of the subscription and a
            // busy PTY delivers thousands of ~1 KiB frames/s — `Data.removeFirst` per frame is an
            // O(remaining) shift (quadratic under flood); the offset buffer consumes in O(1).
            var buffer = IPCReadBuffer()
            var temp = [UInt8](repeating: 0, count: 65_536)
            outer: while true {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let polled = poll(&ready, 1, -1)
                if polled < 0, errno == EINTR { continue }
                if polled < 0 || ready.revents & Int16(POLLNVAL) != 0 { break }
                let count = read(fd, &temp, temp.count)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if count <= 0 { break }
                buffer.append(temp, count: count)
                while true {
                    let decoded: IPCCodec.DecodedReplyFrame?
                    do { decoded = try IPCCodec.decodeReplyOrData(from: &buffer) }
                    catch { break outer } // oversized/garbage frame — unrecoverable on a stream
                    guard let decoded else { break }
                    switch decoded {
                    case let .reply(response):
                        if case let .inputRejected(message) = response, let self {
                            self.lock.lock()
                            let handler = self.inputErrorHandler
                            self.lock.unlock()
                            handler?(message)
                        }
                        if case let .error(message) = response, let self {
                            self.lock.lock()
                            let handler = self.inputErrorHandler
                            self.lock.unlock()
                            handler?(message)
                        }
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

public struct FollowStreamError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
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
