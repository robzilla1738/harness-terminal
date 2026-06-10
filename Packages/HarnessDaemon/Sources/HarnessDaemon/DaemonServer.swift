#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CHarnessSys
import Foundation
import HarnessCore

/// @unchecked Sendable: socket-accept and subscription state are confined to the serial `queue`.
public final class DaemonServer: @unchecked Sendable {
    public let registry: SurfaceRegistry
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon")
    private var clientBuffers: [Int32: IPCReadBuffer] = [:]
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    /// Unsent reply bytes per client, flushed by a writable `DispatchSource` when the socket
    /// was full. Client FDs are non-blocking, so a slow/stuck client buffers here instead of
    /// blocking the serial queue (which would freeze the whole daemon and hang shutdown).
    ///
    /// Each flush advances a `consumed` offset instead of shifting the buffer: `removeFirst` is
    /// O(remaining), so under a large flood (the GUI socket backs up while a 16 MiB burst drains)
    /// shifting on every partial write would be O(n²) and steal CPU from the PTY read loop. The
    /// consumed prefix is compacted in one batch once it dominates — the same head-index pattern as
    /// the PTY scrollback ring — so consume stays ≈O(1) amortized and memory stays bounded.
    private struct PendingWrite {
        var data: Data
        var consumed: Int = 0
        var remaining: Int { data.count - consumed }
    }
    private var writeBuffers: [Int32: PendingWrite] = [:]
    private var writeSources: [Int32: DispatchSourceWrite] = [:]
    /// Drop a client whose backlog grows past this — it isn't draining; buffering more would
    /// be an unbounded memory sink. Sized for a couple of large captures in flight.
    private let maxWriteBacklog = 32 * 1024 * 1024
    /// Per-connection cap on buffered bytes that have not yet decoded into a frame. A legit
    /// frame buffers at most `IPCCodec.maxPayloadLength` + framing overhead while it trickles
    /// in; the codec rejects larger declared lengths outright, so unconsumed bytes beyond this
    /// can never complete into a frame — defense in depth against codec drift or a misbehaving
    /// peer turning `clientBuffers` into a per-connection memory sink.
    private let maxPartialFrameBytes = IPCCodec.maxPayloadLength + 4096
    private var outputSubscriptions: [Int32: [(surfaceID: String, token: UUID)]] = [:]
    /// FDs subscribed to layout-change pushes (`subscribeSnapshot`).
    private var snapshotSubscribers: Set<Int32> = []
    /// Per-client requested PTY size per surface. Each surface is sized to the
    /// **smallest** request across attached clients (tmux `window-size smallest`),
    /// so a small ssh client never truncates a larger one's view and vice versa.
    private var clientSurfaceSizes: [Int32: [String: (rows: UInt16, cols: UInt16)]] = [:]

    private struct ClientRecord {
        let id: UUID
        var label: String
        let connectedAt: Date
    }
    private var clients: [Int32: ClientRecord] = [:]
    private var clientFDsByID: [UUID: Int32] = [:]
    /// Lock-guarded mirror of `clients.count` for `#{session_attached}`. The registry's
    /// format builder runs under its own lock on arbitrary threads, so it can't hop onto
    /// `queue` (the daemon queue itself calls into the registry — `queue.sync` would
    /// deadlock); it reads this counter instead.
    private let registeredClientCount = CountBox()
    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func update(_ count: Int) { lock.lock(); value = count; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// `wait-for` named channels (queue-confined, like the other connection state).
    private let waitForRegistry = WaitForRegistry()
    private let startedAt = Date()

    /// `enableVersionBanner` is passed by the real daemon entry point only (`main.swift`):
    /// the first-run / what's-new banner is daemon policy, not something every embedded or
    /// test registry should emit into freshly spawned PTYs.
    public init(enableVersionBanner: Bool = false) {
        registry = SurfaceRegistry(enableVersionBanner: enableVersionBanner)
        // Push layout changes to snapshot subscribers (the attach-window compositor),
        // replacing its old 0.5s poll. Hop onto the serial queue for FD-safe sends.
        registry.onSnapshotCommitted = { [weak self] revision in
            guard let self else { return }
            self.queue.async { [weak self] in self?.pushSnapshotRevision(revision) }
        }
        registry.attachedClientCountProvider = { [registeredClientCount] in
            registeredClientCount.read()
        }
    }

    private func pushSnapshotRevision(_ revision: Int) {
        for fd in snapshotSubscribers {
            send(.snapshotChanged(revision: revision), to: fd)
        }
    }

    public func start() throws {
        try HarnessPaths.ensureDirectories()
        if FileManager.default.fileExists(atPath: HarnessPaths.socketURL.path) {
            // Stale-socket recovery ordering: consult the PID file FIRST. If it names a dead
            // or non-HarnessDaemon process the socket is definitively stale — remove it without
            // spending the 200 ms ping timeout. Only fall back to the ping when the PID file is
            // absent, unparsable, or names a live HarnessDaemon (the ping is the authoritative
            // two-daemon guard for that last case, as documented in DaemonLifecycle).
            var socketIsClearlyStale = false
            if let raw = try? String(contentsOf: HarnessPaths.daemonPIDURL, encoding: .utf8),
               let priorPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let decision = DaemonLifecycle.priorInstanceDecision(
                    priorPID: priorPID,
                    ownPID: getpid(),
                    isAlive: DaemonLifecycle.processIsAlive,
                    executablePath: DaemonLifecycle.executablePath(of:)
                )
                if decision == .stale {
                    // Dead or recycled PID — the socket is leftover from a crashed/killed daemon;
                    // no need to ping it.
                    socketIsClearlyStale = true
                }
                // .refuse here means a live HarnessDaemon owns the PID: fall through to the
                // ping, which is the authoritative "is it really serving?" check.
                // .proceed means the PID file was written by us (re-exec path): also fall through.
            }
            // Ping only when the PID file didn't already tell us the socket is stale.
            if !socketIsClearlyStale {
                if case .pong = try? DaemonClient().request(.ping, timeout: 0.2) {
                    throw DaemonError.alreadyRunning
                }
            }
            try FileManager.default.removeItem(at: HarnessPaths.socketURL)
        }

        // Validate the socket path fits `sun_path` before binding, so a deep HARNESS_HOME fails
        // with a clear message instead of `strncpy`-truncating and binding the wrong socket.
        let socketPath = try HarnessPaths.validatedSocketPath()
        let fd = makeUnixStreamSocket()
        guard fd >= 0 else { throw DaemonError.socketFailed }
        setNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, sunPathCapacity - 1)
                dest[sunPathCapacity - 1] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Close the creation-time permission window: set umask(0o177) so bind() creates
        // the socket file with exactly 0o600 permissions (rw-------), not whatever the
        // process umask happens to be. This is listener setup on the daemon's single-
        // threaded startup path — signal handlers and DispatchSource event handlers are
        // not yet running, so umask is safe to change briefly here.
        //
        // Parent directory is 0o700 (ensureDirectories above), so this is defense-in-depth:
        // even a relaxed umask wouldn't grant access via the parent, but belt-and-suspenders
        // is correct for a control socket that can spawn PTYs. The chmod below stays as the
        // second layer in case some platform creates AF_UNIX sockets without obeying umask.
        let prevUmask = umask(0o177)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        // Restore umask immediately after bind so we don't affect any other file
        // creation in the process lifetime. bind() is the only call that needs
        // the restricted mask.
        umask(prevUmask)

        guard bindResult == 0 else {
            close(fd)
            throw DaemonError.bindFailed
        }
        // Belt-and-suspenders: explicitly restrict the socket to owner-only even
        // though the umask above should have produced 0o600 at bind time. A world-
        // or group-writable control socket would let any local process drive the
        // daemon (spawn PTYs, read pane output, run hook shell commands). 0o600 means
        // only our UID can even connect; the peer-credential check on accept is the
        // second layer.
        if chmod(HarnessPaths.socketURL.path, 0o600) != 0 {
            close(fd)
            throw DaemonError.bindFailed
        }
        // `SOMAXCONN`, not a small fixed backlog: the daemon serves the GUI plus any number of
        // `harness-cli` clients, and a burst of near-simultaneous connects (e.g. several attach
        // clients reconnecting at once) must not overflow the accept queue and get refused.
        guard listen(fd, Int32(SOMAXCONN)) == 0 else { // SOMAXCONN is `Int` on Glibc
            close(fd)
            throw DaemonError.listenFailed
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(listenerFD: fd)
        }
        // Own the listener fd's lifetime: cancelling the source (in `stop()`) closes it, so an
        // orderly shutdown doesn't leak the listening socket descriptor.
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        fputs("HarnessDaemon listening at \(HarnessPaths.socketURL.path)\n", harnessStderr)
    }

    private func acceptConnection(listenerFD: Int32) {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        // Defence in depth alongside the 0o600 socket mode: only accept peers running as our own
        // euid. The kernel records the peer's credentials at connect time (Darwin `getpeereid`,
        // Linux `SO_PEERCRED`), so a process can't spoof them. Reject anything else outright. This
        // applies to the local Unix socket; a future TCP transport authenticates with a token.
        let peer = harness_peer_uid(clientFD)
        guard peer >= 0, uid_t(peer) == geteuid() else {
            close(clientFD)
            return
        }
        setNoSigPipe(clientFD)
        // Non-blocking so a slow/stuck client never blocks `write` on the serial queue.
        _ = harness_set_nonblocking(clientFD)
        clientBuffers[clientFD] = IPCReadBuffer()
        // Don't auto-register the connection as a client — `DaemonClient.request`
        // opens a fresh socket per call, and bookkeeping every one of those would
        // make `list-clients` useless. Clients announce themselves with
        // `identifyClient`; everything else is treated as ephemeral RPC.
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readClient(fd: clientFD, source: source)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { close(clientFD); return }
            if let removed = self.clients.removeValue(forKey: clientFD) {
                self.clientFDsByID.removeValue(forKey: removed.id)
                self.registeredClientCount.update(self.clients.count)
                self.registry.fireClientDetached(label: removed.label)
            }
            self.clientBuffers.removeValue(forKey: clientFD)
            self.clientSources.removeValue(forKey: clientFD)
            self.writeBuffers.removeValue(forKey: clientFD)
            if let wsrc = self.writeSources.removeValue(forKey: clientFD) { wsrc.cancel() }
            self.cancelSubscriptions(for: clientFD)
            for granted in self.waitForRegistry.remove(fd: clientFD) { self.send(.ok, to: granted) }
            close(clientFD)
        }
        clientSources[clientFD] = source
        source.resume()
    }

    private func readClient(fd: Int32, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { source.cancel(); return } // EOF — peer closed
        if count < 0 {
            // Non-blocking fd: a transient EAGAIN/EINTR is not a disconnect.
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            source.cancel()
            return
        }
        var data = clientBuffers[fd] ?? IPCReadBuffer()
        data.append(buffer, count: count)
        clientBuffers[fd] = data

        while true {
            let frame: IPCCodec.DecodedRequestFrame?
            do {
                frame = try IPCCodec.decodeRequestOrInput(from: &data)
            } catch IPCCodec.FrameError.undecodable {
                // A well-framed request this build doesn't understand (version skew). The stream
                // is still in sync, so reply with an error and keep going rather than hanging the
                // client; the frame was already consumed, so persist the advanced buffer.
                clientBuffers[fd] = data
                send(.error("unrecognized request"), to: fd)
                continue
            } catch {
                // Oversized/garbage frame — the stream can't be re-synced. Drop the client.
                clientBuffers[fd] = IPCReadBuffer()
                source.cancel()
                return
            }
            guard let frame else { break }
            clientBuffers[fd] = data
            // Binary input frame on a persistent (subscription) connection: write straight to the
            // PTY, fire-and-forget — no reply (the echo comes back on the output stream).
            if case let .input(surfaceID, payload) = frame {
                _ = registry.handle(.sendData(surfaceID: surfaceID, data: payload))
                continue
            }
            guard case let .request(maybeRequest) = frame else { continue }
            guard let request = maybeRequest else {
                // The frame de-framed cleanly but carries no request — a `null`/empty/unknown-shape
                // envelope, e.g. from a newer client. Reply with an explicit error instead of
                // silently dropping it; otherwise the client blocks until its own timeout. Mirrors
                // the `.undecodable` reply above — never silently hang a client.
                send(.error("unrecognized request"), to: fd)
                continue
            }
            if case let .subscribeSurfaceOutput(surfaceID, label) = request {
                handleSubscribe(surfaceID: surfaceID, label: label, fd: fd)
                continue
            }
            if case let .subscribeSnapshot(label) = request {
                handleSubscribeSnapshot(label: label, fd: fd)
                continue
            }
            if case let .resizeSurface(surfaceID, rows, cols) = request {
                handleResize(surfaceID: surfaceID, rows: rows, cols: cols, fd: fd)
                send(.ok, to: fd)
                continue
            }
            if case let .detachSurface(surfaceID) = request {
                // Per-client detach: release only THIS connection's hold (handled at the
                // server FD layer, like resize/subscribe — never in the registry, which
                // can't see which client asked).
                handleDetachSurface(surfaceID: surfaceID, fd: fd)
                send(.ok, to: fd)
                continue
            }
            if case let .cancelSubscription(surfaceID) = request {
                // Per-client: release only THIS connection's subscription to the surface (mirrors
                // detachSurface). Intercepted here, never in the registry — which can't see which
                // client asked and would otherwise wipe EVERY subscriber on the surface.
                handleDetachSurface(surfaceID: surfaceID, fd: fd)
                send(.ok, to: fd)
                continue
            }
            if case let .waitFor(channel, mode) = request {
                handleWaitFor(channel: channel, mode: mode, fd: fd)
                continue
            }
            if let intercepted = handleClientLifecycle(request, fd: fd) {
                send(intercepted, to: fd)
                continue
            }
            let response = registry.handle(request)
            if case .snapshot = response {
                // keep buffer updated
            }
            send(response, to: fd)
        }
        clientBuffers[fd] = data
        // Partial-frame cap: bytes still buffered after the decode loop are an incomplete
        // frame. More than one max-size frame's worth can never decode (the codec rejects
        // larger declared lengths as soon as the header arrives), so the stream is broken
        // or abusive — drop it instead of buffering without bound.
        if data.count > maxPartialFrameBytes {
            clientBuffers[fd] = IPCReadBuffer()
            source.cancel()
        }
    }

    /// `wait-for`: register/wake fds on a named channel. `wait`/`lock` defer the reply (the
    /// client's socket read blocks) until a `signal`/`unlock` from another connection sends
    /// it. All on the serial queue — no blocking here, no registry lock.
    private func handleWaitFor(channel: String, mode: WaitForMode, fd: Int32) {
        switch mode {
        case .signal:
            for waiter in waitForRegistry.signal(channel: channel) { send(.ok, to: waiter) }
            send(.ok, to: fd)
        case .lock:
            if waitForRegistry.lock(channel: channel, fd: fd) { send(.ok, to: fd) }
            // else: held — reply deferred until `unlock` grants it.
        case .unlock:
            if let granted = waitForRegistry.unlock(channel: channel) { send(.ok, to: granted) }
            send(.ok, to: fd)
        case .wait:
            // wait() returns false when the per-channel waiter cap is reached. In that
            // case reply immediately with an error so the client's socket unblocks rather
            // than hanging forever waiting for a signal that might never arrive (too many
            // concurrent waiters on the same channel is a scripting error).
            if !waitForRegistry.wait(channel: channel, fd: fd) {
                send(.error("wait-for channel '\(channel)' has too many waiters"), to: fd)
            }
            // On true: reply deferred until a `signal`.
        }
    }

    /// Requests the server owns (because they query/mutate the FD layer rather
    /// than session state). Returning `nil` falls through to `registry.handle`.
    private func handleClientLifecycle(_ request: IPCRequest, fd: Int32) -> IPCResponse? {
        switch request {
        case let .identifyClient(label):
            // Idempotent: identifying twice on the same socket updates the label
            // but keeps the same client ID so callers can identify-then-act.
            if var record = clients[fd] {
                record.label = label
                clients[fd] = record
                return .clientID(record.id)
            }
            let record = ClientRecord(id: UUID(), label: label, connectedAt: Date())
            clients[fd] = record
            clientFDsByID[record.id] = fd
            registeredClientCount.update(clients.count)
            registry.fireClientAttached(label: label)
            return .clientID(record.id)
        case .listClients:
            let summaries = clients
                .sorted { $0.value.connectedAt < $1.value.connectedAt }
                .map { entry -> ClientSummary in
                    let surfaces = (outputSubscriptions[entry.key] ?? []).map(\.surfaceID)
                    return ClientSummary(
                        id: entry.value.id,
                        label: entry.value.label,
                        attachedSurfaceIDs: surfaces,
                        connectedAt: entry.value.connectedAt
                    )
                }
            return .clients(summaries)
        case let .detachClient(clientID):
            guard let targetFD = clientFDsByID[clientID] else {
                return .error("Client not found: \(clientID.uuidString)")
            }
            guard targetFD != fd else {
                return .error("Cannot detach the calling client; close the socket instead")
            }
            clientSources[targetFD]?.cancel()
            return .ok
        case .daemonStats:
            let telemetry = registry.surfaceTelemetry
            let totalSubs = outputSubscriptions.values.reduce(0) { $0 + $1.count }
            let stats = DaemonStats(
                pid: getpid(),
                uptimeSeconds: Date().timeIntervalSince(startedAt),
                surfaceCount: telemetry.surfaceCount,
                totalScrollbackBytes: telemetry.scrollbackBytes,
                clientCount: clients.count,
                subscriberCount: totalSubs,
                snapshotRevision: registry.revision,
                version: HarnessVersion.short,
                build: HarnessVersion.build
            )
            return .daemonStats(stats)
        default:
            return nil
        }
    }

    private enum WriteOutcome { case complete, wouldBlock, failed }

    private func send(_ response: IPCResponse, to fd: Int32) {
        guard let data = try? IPCCodec.encode(IPCReply(response: response)) else {
            // Encoding a reply should be infallible; if it isn't, the client would hang forever
            // waiting for bytes that never come. Send a minimal error instead, and if even that
            // won't encode, drop the connection so the client errors out rather than timing out.
            if case .error = response {
                clientSources[fd]?.cancel() // already an error and still unencodable — unrecoverable
            } else if let fallback = try? IPCCodec.encode(IPCReply(response: .error("internal encode failure"))) {
                enqueue(fallback, to: fd)
            } else {
                clientSources[fd]?.cancel()
            }
            return
        }
        enqueue(data, to: fd)
    }

    /// Hot-path PTY output as a raw binary frame (no JSON/base64). Shares the exact buffering,
    /// backlog cap, and writable-source flush as `send`, so ordering and backpressure are identical.
    private func sendDataFrame(_ payload: Data, sequence: UInt64, to fd: Int32) {
        guard let data = try? IPCCodec.encodeOutputFrame(payload, sequence: sequence) else {
            // A dropped output frame leaves a gap in the client's byte stream (visible terminal
            // corruption). This should be impossible — a frame is ≤64 KiB, far under the 16 MiB
            // cap — but if it ever happens, drop the client so it reattaches and replays cleanly
            // rather than rendering a corrupt buffer.
            clientSources[fd]?.cancel()
            return
        }
        enqueue(data, to: fd)
    }

    /// Append framed bytes to `fd`'s pending tail (so frames stay in order), enforce the backlog
    /// cap, and flush what the non-blocking socket takes now. The single owner of `writeBuffers`
    /// growth — both JSON replies and binary frames go through here.
    private func enqueue(_ data: Data, to fd: Int32) {
        if var pending = writeBuffers[fd] {
            pending.data.append(data) // amortized O(1) (Data grows by doubling)
            writeBuffers[fd] = pending
        } else {
            writeBuffers[fd] = PendingWrite(data: data)
        }
        let backlog = writeBuffers[fd]?.remaining ?? 0
        // Read-only instrumentation of the peak backlog (the cap/flush/drop logic below is
        // unchanged); captured here so a client that's about to be dropped still registers its high.
        registry.metrics.observeBacklog(bytes: backlog)
        // A client that won't drain must not pin unbounded memory — drop it past the backlog cap.
        if backlog > maxWriteBacklog {
            writeBuffers[fd] = nil
            suspendWriteSource(fd: fd)
            clientSources[fd]?.cancel()
            return
        }
        flushWrites(fd: fd)
    }

    /// Flush as much of `fd`'s pending reply bytes as the (non-blocking) socket accepts now.
    /// Unwritten bytes stay buffered (consume offset advanced, not shifted) and a writable
    /// `DispatchSource` finishes them later; a hard socket error drops the client. Runs on the
    /// serial queue, never blocks it.
    private func flushWrites(fd: Int32) {
        guard var pending = writeBuffers[fd], pending.remaining > 0 else {
            writeBuffers[fd] = nil
            suspendWriteSource(fd: fd)
            return
        }
        var newConsumed = pending.consumed
        var outcome: WriteOutcome = .complete
        pending.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while newConsumed < raw.count {
                let n = write(fd, base.advanced(by: newConsumed), raw.count - newConsumed)
                if n > 0 { newConsumed += n; continue }
                if n < 0, errno == EINTR { continue }
                outcome = (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? .wouldBlock : .failed
                return
            }
        }
        pending.consumed = newConsumed
        switch outcome {
        case .complete:
            writeBuffers[fd] = nil
            suspendWriteSource(fd: fd)
        case .wouldBlock:
            // Compact the consumed prefix in one batch once it dominates the buffer (≈O(1)
            // amortized), bounding retained memory without an O(remaining) shift every flush.
            if pending.consumed > 65_536, pending.consumed >= pending.remaining {
                pending.data.removeFirst(pending.consumed)
                pending.consumed = 0
            }
            writeBuffers[fd] = pending
            ensureWriteSource(fd: fd) // resume when the socket drains
        case .failed:
            writeBuffers[fd] = nil
            suspendWriteSource(fd: fd)
            clientSources[fd]?.cancel() // EPIPE / peer gone
        }
    }

    private func ensureWriteSource(fd: Int32) {
        guard writeSources[fd] == nil else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.flushWrites(fd: fd) }
        writeSources[fd] = src
        src.resume()
    }

    private func suspendWriteSource(fd: Int32) {
        if let src = writeSources.removeValue(forKey: fd) { src.cancel() }
    }

    private func handleSubscribe(surfaceID: String, label: String?, fd: Int32) {
        guard let token = registry.subscribe(surfaceID: surfaceID, handler: { [weak self] data, sequence in
            guard let server = self else { return }
            server.queue.async { [weak server] in
                guard let server else { return }
                server.registry.metrics.recordOutputNotification()
                server.sendDataFrame(data, sequence: sequence, to: fd)
            }
        }) else {
            send(.error("Surface not found"), to: fd)
            return
        }
        outputSubscriptions[fd, default: []].append((surfaceID, token))
        // A subscription connection is long-lived and identifies a real client
        // (Harness.app, harness-cli attach, etc.). Register it so `list-clients`
        // and `daemon-stats` reflect actual users, not ephemeral RPC sockets.
        if var record = clients[fd] {
            if let label, label != record.label {
                record.label = label
                clients[fd] = record
            }
        } else {
            let record = ClientRecord(id: UUID(), label: label ?? "subscriber", connectedAt: Date())
            clients[fd] = record
            clientFDsByID[record.id] = fd
            // A new long-lived client just attached. Fire the hook here (not only in
            // identifyClient) so attach/detach hooks stay paired: the cancel handler fires
            // client-detached for every registered record, including subscription-registered
            // ones — without this, every real client (GUI, attach, attach-window) produced a
            // detached event with no matching attached.
            registry.fireClientAttached(label: record.label)
            // Keep the off-queue mirror (`#{session_attached}`) in step with `clients` —
            // GUI/attach clients register here, never through identifyClient.
            registeredClientCount.update(clients.count)
        }
        send(.ok, to: fd)
    }

    /// Record this client's requested size for a surface and resize the PTY to the
    /// smallest request across all clients currently sizing it.
    private func handleResize(surfaceID: String, rows: UInt16, cols: UInt16, fd: Int32) {
        clientSurfaceSizes[fd, default: [:]][surfaceID] = (rows, cols)
        applyEffectiveSize(surfaceID: surfaceID)
    }

    private func applyEffectiveSize(surfaceID: String) {
        var minRows: UInt16 = .max
        var minCols: UInt16 = .max
        var found = false
        for sizes in clientSurfaceSizes.values {
            guard let size = sizes[surfaceID] else { continue }
            found = true
            minRows = min(minRows, size.rows)
            minCols = min(minCols, size.cols)
        }
        guard found, minRows > 0, minCols > 0 else { return }
        _ = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: minRows, cols: minCols))
    }

    private func handleSubscribeSnapshot(label: String?, fd: Int32) {
        snapshotSubscribers.insert(fd)
        // Register as a real client (like output subscriptions) so list-clients/stats
        // reflect it rather than treating it as ephemeral RPC.
        if var record = clients[fd] {
            if let label, label != record.label { record.label = label; clients[fd] = record }
        } else {
            let record = ClientRecord(id: UUID(), label: label ?? "snapshot-subscriber", connectedAt: Date())
            clients[fd] = record
            clientFDsByID[record.id] = fd
            // Pair with the cancel handler's client-detached (see handleSubscribe).
            registry.fireClientAttached(label: record.label)
            // Mirror update, as in handleSubscribe — `#{session_attached}` reads this.
            registeredClientCount.update(clients.count)
        }
        send(.ok, to: fd)
    }

    /// Release only *this* client's hold on one surface — its output subscription(s) and its
    /// size vote — leaving the PTY and every other client untouched. The surface can then grow
    /// back to the remaining clients' smallest size. The per-client counterpart to
    /// `cancelSubscriptions(for:)` (which tears down a whole connection). Runs on `queue`, like
    /// every other subscription/size mutation, so the maps are never touched off-queue.
    private func handleDetachSurface(surfaceID: String, fd: Int32) {
        if var subs = outputSubscriptions[fd] {
            for sub in subs where sub.surfaceID == surfaceID {
                registry.cancelSubscription(surfaceID: surfaceID, token: sub.token)
            }
            subs.removeAll { $0.surfaceID == surfaceID }
            if subs.isEmpty { outputSubscriptions.removeValue(forKey: fd) } else { outputSubscriptions[fd] = subs }
        }
        if clientSurfaceSizes[fd]?.removeValue(forKey: surfaceID) != nil {
            if clientSurfaceSizes[fd]?.isEmpty == true { clientSurfaceSizes.removeValue(forKey: fd) }
            applyEffectiveSize(surfaceID: surfaceID)
        }
    }

    private func cancelSubscriptions(for fd: Int32) {
        let subscriptions = outputSubscriptions.removeValue(forKey: fd) ?? []
        for subscription in subscriptions {
            registry.cancelSubscription(surfaceID: subscription.surfaceID, token: subscription.token)
        }
        snapshotSubscribers.remove(fd)
        // Drop this client's size requests and let the remaining clients' smallest
        // size take over (a surface can grow back when a small client detaches).
        let droppedSizes = clientSurfaceSizes.removeValue(forKey: fd) ?? [:]
        for surfaceID in droppedSizes.keys { applyEffectiveSize(surfaceID: surfaceID) }
    }

    public func runLoop() {
        dispatchMain()
    }

    /// Cancel the accept loop and tear down all client connections + subscriptions.
    /// Lets a server shut down cleanly (used by integration tests and for an orderly
    /// daemon teardown).
    public func stop() {
        // Stop the background timers first (they have their own queues), then tear down the
        // socket layer. Otherwise a scan/monitor tick could fire against a half-stopped server.
        AgentScanner.shared.stop()
        registry.stopMonitoring()
        // Persist any buffered scrollback AND the latest layout snapshot before tearing down, so a
        // graceful restart replays the most recent output and restores the last committed layout
        // instead of losing the last debounce window of either.
        registry.flushAllScrollback()
        registry.flushSnapshot()
        // Flush the debounced stores (options / environment / hooks / paste buffers) so the last
        // mutation in any burst's debounce window is never silently discarded on shutdown.
        registry.flushAllStores()
        queue.sync {
            listener?.cancel() // cancel handler closes the listener fd
            listener = nil
            // Give pending replies a bounded chance to drain before the fds close — a
            // client mid-`capture-pane` would otherwise receive a truncated response on
            // an orderly shutdown. Whatever hasn't drained by the deadline is dropped,
            // exactly as before.
            let drainDeadline = DispatchTime.now() + .milliseconds(250)
            while !writeBuffers.isEmpty, DispatchTime.now() < drainDeadline {
                for fd in Array(writeBuffers.keys) { flushWrites(fd: fd) }
                if !writeBuffers.isEmpty { usleep(5_000) }
            }
            for (fd, source) in clientSources {
                cancelSubscriptions(for: fd)
                source.cancel()
            }
            clientSources.removeAll()
            clientBuffers.removeAll()
            clients.removeAll()
            clientFDsByID.removeAll()
        }
    }
}

public enum DaemonError: Error, CustomStringConvertible {
    case alreadyRunning
    case socketFailed
    case bindFailed
    case listenFailed

    public var description: String {
        switch self {
        case .alreadyRunning: "HarnessDaemon is already running"
        case .socketFailed: "Failed to create socket"
        case .bindFailed: "Failed to bind socket"
        case .listenFailed: "Failed to listen on socket"
        }
    }
}
