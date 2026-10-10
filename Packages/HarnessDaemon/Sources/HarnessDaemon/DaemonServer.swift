#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CHarnessSys
import Foundation
import HarnessCore
import HarnessTerminalEngine

/// @unchecked Sendable: socket-accept and subscription state are confined to the serial `queue`.
public final class DaemonServer: @unchecked Sendable {
    public let registry: SurfaceRegistry
    /// Set before starting the listener. Executed off the socket queue after replying.
    public var onShutdown: (@Sendable () -> Void)?
    private var listener: DispatchSourceRead?
    private var checkpointTimer: DispatchSourceTimer?
    private let checkpointTimerLock = NSLock()
    private var listenerSocketIdentity: (device: dev_t, inode: ino_t)?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon")
    private var clientBuffers: [Int32: IPCReadBuffer] = [:]
    /// `read(2)` destination reused by every `readClient` — reads all run on the serial `queue`,
    /// so one buffer is never shared, and a fresh zero-filled 64 KiB per read was pure waste.
    private var readScratch = [UInt8](repeating: 0, count: 65_536)
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
    private var outputSubscriptions: [Int32: [(surfaceID: String, token: UUID, deliveryID: UUID)]] = [:]
    /// FDs subscribed to layout-change pushes (`subscribeSnapshot`).
    private var snapshotSubscribers: Set<Int32> = []
    /// FDs subscribed to `events --follow`.
    private var eventSubscribers: [Int32: FollowSubscription] = [:]
    /// `pane.wait` callers blocked on this connection. Queue-confined.
    private struct PaneWait {
        var fd: Int32
        var surfaceID: String
        var until: String
    }
    private var paneWaits: [UUID: PaneWait] = [:]
    /// Per-client PTY sizes. `smallest` (the default) is tmux compatibility.
    /// `owner` lets one client set the size; other clients' votes do not resize.
    private var sizeArbiter = SurfaceSizeArbiter()
    /// The ownership each subscriber was last told, per surface, so a push goes out only when
    /// a client's view changes.
    private var sentOwnership: [Int32: [String: SizeOwnership]] = [:]
    /// Connections that attached with `attachStream`: they understand `.sizeOwnership`. An
    /// older client's decoder would choke on it and drop its stream.
    private var streamClients: Set<Int32> = []
    private var inputErrorClients: Set<Int32> = []
    /// Snapshot subscribers that asked for client directives (older apps can't decode them).
    private var notificationSubscribers: Set<Int32> = []
    private var directiveSubscribers: Set<Int32> = []

    private struct ClientRecord {
        let id: UUID
        var label: String
        let connectedAt: Date
        var kind: String = "client"
        var version: String = ""
        var principalUID: UInt32?
        var tunnel = false
    }
    private var clients: [Int32: ClientRecord] = [:]
    /// File descriptors that may receive output but must not write to a child.
    private var readOnlyClients: Set<Int32> = []
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
    /// This daemon's boot id. A client may resume an attach only within the same epoch:
    /// a restarted daemon numbers its ring afresh.
    private let epoch = ProcessInfo.processInfo.environment["HARNESS_STREAM_EPOCH"] ?? UUID().uuidString
    private let socketURL: URL
    private let searchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.robert.harness.search"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var cancelledSearches: [UUID: Date] = [:]
    private let mobileHistory = MobileHistoryStore()
    private var searches: [UUID: (fd: Int32, cancellation: SurfaceRegistry.FlagBox)] = [:]
    private var clientDescriptors: [Int32: ChannelDescriptor] = [:]
    /// Startup phases the server itself times (`listen`); the registry times the rest.
    private var startupMillis: [String: Double] = [:]

    /// `enableVersionBanner` is passed by the real daemon entry point only (`main.swift`):
    /// the first-run / what's-new banner is daemon policy, not something every embedded or
    /// test registry should emit into freshly spawned PTYs.
    public init(enableVersionBanner: Bool = false, enablePowerManagement: Bool = false, socketURL: URL = HarnessPaths.socketURL, mutationLease: DaemonMutationLease? = nil) {
        self.socketURL = socketURL
        registry = SurfaceRegistry(enableVersionBanner: enableVersionBanner, enablePowerManagement: enablePowerManagement, mutationLease: mutationLease)
        // `size-mode` set with `harness-cli size-mode` survives a daemon restart.
        if let raw = registry.optionStore.get("size-mode")?.stringValue, let mode = SurfaceSizeMode(rawValue: raw) {
            sizeArbiter = SurfaceSizeArbiter(mode: mode)
        }
        // Push layout changes to snapshot subscribers (the attach-window compositor),
        // replacing its old 0.5s poll. Hop onto the serial queue for FD-safe sends.
        registry.onSnapshotCommitted = { [weak self] revision in
            guard let self else { return }
            self.queue.async { [weak self] in self?.pushSnapshotRevision(revision) }
        }
        registry.onFollowEvent = { [weak self] event in
            guard let self else { return }
            self.queue.async { [weak self] in self?.pushFollow(event) }
        }
        registry.onCommandFinished = { [weak self] surfaceID, status in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.finishPaneWaits(surfaceID: surfaceID, until: "command", status: status)
            }
        }
        // Called with the registry lock held. Only hop; never take that lock again here.
        registry.onChildExited = { [weak self] surfaceID, status in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.finishPaneWaits(surfaceID: surfaceID, until: "child", status: status)
            }
        }
        registry.notifications.onDesktop = { [weak self] delivery in
            self?.queue.async { [weak self] in
                guard let self, let fd = self.notificationSubscribers.sorted().first(where: { self.snapshotSubscribers.contains($0) }) else { return }
                self.send(.clientDirective(.notification(delivery)), to: fd)
            }
        }
        registry.onClientDirective = { [weak self] directive in
            self?.queue.async { [weak self] in
                guard let self else { return }
                for fd in self.snapshotSubscribers where self.directiveSubscribers.contains(fd) {
                    self.send(.clientDirective(directive), to: fd)
                }
            }
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
        var phase = DispatchTime.now()
        defer { startupMillis["listen"] = SurfaceRegistry.millis(since: &phase) }
        try HarnessPaths.ensureDirectories()
        if FileManager.default.fileExists(atPath: socketURL.path) {
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
            // A live owner that is temporarily unresponsive is never a stale socket.
            if SessionHostClient.configured == nil, case let .alive(owner) = DaemonOwnership.probe(), owner != getpid() { throw DaemonError.alreadyRunning }
            // Ping only when the PID file didn't already tell us the socket is stale.
            if !socketIsClearlyStale {
                if case .pong = try? DaemonClient(endpoint: .unix(path: socketURL.path)).request(.ping, timeout: 0.2) {
                    throw DaemonError.alreadyRunning
                }
            }
            try FileManager.default.removeItem(at: socketURL)
        }

        // Validate the socket path fits `sun_path` before binding, so a deep HARNESS_HOME fails
        // with a clear message instead of `strncpy`-truncating and binding the wrong socket.
        let socketPath = socketURL.path
        guard socketPath.utf8.count < HarnessPaths.maxSocketPathLength else { throw DaemonError.socketFailed }
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
        if chmod(socketURL.path, 0o600) != 0 {
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
        var boundSocket = stat()
        _ = lstat(socketPath, &boundSocket)
        let boundDevice = boundSocket.st_dev
        let boundInode = boundSocket.st_ino
        listenerSocketIdentity = (boundDevice, boundInode)
        source.setCancelHandler {
            var current = stat()
            if lstat(socketPath, &current) == 0,
               current.st_dev == boundDevice, current.st_ino == boundInode {
                unlink(socketPath)
            }
            close(fd)
        }
        source.resume()
        listener = source
        if SessionHostClient.configured != nil, !registry.isQuiesced { startHostCheckpointTimer() }
        fputs("HarnessDaemon listening at \(socketURL.path)\n", harnessStderr)
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
        let descriptor = ChannelDescriptor(clientFD)
        clientDescriptors[clientFD] = descriptor
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
        descriptor.register(source) { [weak self, descriptor] in
            guard let self else { descriptor.retire(); return }
            for (id, search) in self.searches where search.fd == clientFD {
                search.cancellation.update(true)
                self.searches.removeValue(forKey: id)
            }
            self.readOnlyClients.remove(clientFD)
            if let removed = self.clients.removeValue(forKey: clientFD) {
                self.clientFDsByID.removeValue(forKey: removed.id)
                self.registeredClientCount.update(self.clients.count)
                self.registry.fireClientDetached(label: removed.label)
                if removed.tunnel {
                    self.registry.noteTunnelClientDropped(client: removed.label)
                }
            }
            self.clientBuffers.removeValue(forKey: clientFD)
            self.clientSources.removeValue(forKey: clientFD)
            self.writeBuffers.removeValue(forKey: clientFD)
            if let wsrc = self.writeSources.removeValue(forKey: clientFD) { wsrc.cancel() }
            self.cancelSubscriptions(for: clientFD)
            for granted in self.waitForRegistry.remove(fd: clientFD) { self.send(.ok, to: granted) }
            self.clientDescriptors.removeValue(forKey: clientFD)
            descriptor.retire()
        }
        clientSources[clientFD] = source
        source.resume()
    }

    private func readClient(fd: Int32, source: DispatchSourceRead) {
        let capacity = readScratch.count
        let count = read(fd, &readScratch, capacity)
        if count == 0 { source.cancel(); return } // EOF — peer closed
        if count < 0 {
            // Non-blocking fd: a transient EAGAIN/EINTR is not a disconnect.
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            source.cancel()
            return
        }
        // Take the buffer out of the map so the append mutates uniquely-owned storage instead of
        // copy-on-writing the whole unconsumed backlog on every read.
        var data = clientBuffers.removeValue(forKey: fd) ?? IPCReadBuffer()
        data.append(readScratch, count: count)

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
                if !readOnlyClients.contains(fd) {
                    let response = registry.handle(.sendData(surfaceID: surfaceID, data: payload))
                    if inputErrorClients.contains(fd), case let .error(message) = response {
                        send(.inputRejected(message), to: fd)
                    }
                }
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
                readOnlyClients.remove(fd)
                handleSubscribe(surfaceID: surfaceID, label: label, fd: fd)
                continue
            }
            if case let .subscribeSurfaceOutputReadOnly(surfaceID, label) = request {
                readOnlyClients.insert(fd)
                handleSubscribe(surfaceID: surfaceID, label: label, fd: fd)
                continue
            }
            if case let .attachStream(attach) = request {
                handleAttach(attach, fd: fd)
                continue
            }
            if case let .sendData(surfaceID, payload) = request, readOnlyClients.contains(fd) {
                send(.ok, to: fd)
                _ = surfaceID
                _ = payload
                continue
            }
            if case let .send(surfaceID, _) = request, readOnlyClients.contains(fd) {
                send(.ok, to: fd)
                _ = surfaceID
                continue
            }
            if case let .subscribeSnapshot(label, directives, capabilities) = request {
                if directives == true { directiveSubscribers.insert(fd) }
                handleSubscribeSnapshot(label: label, fd: fd)
                if directives == true, let capabilities, capabilities.contains(DaemonStats.clientCapabilities) {
                    let negotiated = Set(capabilities.prefix(64)).intersection(DaemonStats.currentCapabilities)
                    if negotiated.contains(DaemonStats.notificationPolicy) { notificationSubscribers.insert(fd) }
                    send(.clientDirective(.capabilities(negotiated.sorted())), to: fd)
                }
                continue
            }
            if case let .resizeSurface(surfaceID, rows, cols) = request {
                send(handleResize(surfaceID: surfaceID, rows: rows, cols: cols, fd: fd), to: fd)
                pushOwnership(surfaceID)
                continue
            }
            if case let .setSurfaceSizeMode(mode) = request {
                if let failure = applySizeMode(mode) { send(.error(failure), to: fd); continue }
                registry.optionStore.set(.string(mode.rawValue), key: "size-mode")
                send(.ok, to: fd)
                continue
            }
            if case let .takeSurface(surfaceID, clientID) = request {
                let targetFD: Int32
                if let clientID {
                    guard let resolved = clientFDsByID[clientID] else {
                        send(.error("take-surface: client \(clientID.uuidString) is not connected"), to: fd)
                        continue
                    }
                    targetFD = resolved
                } else {
                    targetFD = fd
                }
                let previousArbiter = sizeArbiter
                let taken = sizeArbiter.take(client: targetFD, surface: surfaceID)
                guard taken.accepted else {
                    send(.error("This client must attach and send its terminal size before taking control."), to: fd)
                    continue
                }
                if let size = taken.size {
                    if case let .error(message) = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: size.rows, cols: size.cols)) { sizeArbiter = previousArbiter; send(.error(message), to: fd); continue }
                }
                send(.ok, to: fd)
                pushOwnership(surfaceID)
                if taken.ownershipChanged {
                    pushFollow(FollowEvent(type: "pane.owner_changed", payload: [
                        "surface": .string(surfaceID), "client": .string(clients[targetFD]?.id.uuidString ?? ""),
                    ]))
                }
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
            if case let .subscribeEvents(sessionID, includeServer) = request {
                eventSubscribers[fd] = FollowSubscription(sessionID: sessionID, includeServer: includeServer)
                send(.ok, to: fd)
                continue
            }
            if case let .paneWait(surfaceID, until, timeout) = request {
                handlePaneWait(surfaceID: surfaceID, until: until, timeout: timeout, fd: fd)
                continue
            }
            if case let .cancelSearch(id) = request {
                searches[id]?.cancellation.update(true)
                cancelledSearches = cancelledSearches.filter { Date().timeIntervalSince($0.value) < 30 }
                if cancelledSearches.count >= 64, let oldest = cancelledSearches.min(by: { $0.value < $1.value })?.key { cancelledSearches.removeValue(forKey: oldest) }
                cancelledSearches[id] = Date()
                send(.ok, to: fd)
                continue
            }
            if case let .mobileHistory(surfaceID, token, before, count) = request {
                scheduleSearch(id: UUID(), fd: fd) { [registry, mobileHistory, epoch] cancellation in
                    guard !cancellation.read() else { return .error("Cancelled") }
                    return mobileHistory.page(surfaceID: surfaceID, token: token, before: before, count: count,
                                              epoch: epoch, load: { registry.mobileHistorySnapshot(surfaceID: surfaceID) })
                }
                continue
            }
            if case let .mobileHistoryMatch(match, expectedEpoch, revision) = request {
                guard expectedEpoch == epoch else { send(.error("This daemon restarted. Search again."), to: fd); continue }
                scheduleSearch(id: UUID(), fd: fd) { [registry, mobileHistory, epoch] cancellation in
                    mobileHistory.matchedPage(match, epoch: epoch, load: {
                        registry.matchedMobileHistorySnapshot(match, revision: revision, cancelled: cancellation)
                    })
                }
                continue
            }
            if request.requiresLocalOwner, peerUID(fd) != UInt32(getuid()) || clients[fd]?.tunnel == true { send(.error("This administrative operation requires a local owner connection."), to: fd); continue }
            if case let .activity(.repositoryDigest(id, from, to, offset, limit)) = request {
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    registry.handleActivity(.repositoryDigest(requestID: id, from: from, to: to, offset: offset, limit: limit), cancelled: { cancellation.read() })
                }
                continue
            }
            if case let .activity(.hookPolicy(operation)) = request {
                scheduleSearch(id: UUID(), fd: fd) { [registry] cancellation in
                    guard !cancellation.read() else { return .error("Cancelled") }
                    return registry.handleActivity(.hookPolicy(operation))
                }
                continue
            }
            if case let .activity(.schedules(id, operation)) = request {
                guard peerUID(fd) == UInt32(getuid()), clients[fd]?.tunnel != true else { send(.error("Scheduling administration requires the local host."), to: fd); continue }
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    guard !cancellation.read() else { return .error("Cancelled") }
                    return registry.handleActivity(.schedules(requestID: id, operation: operation), cancelled: { cancellation.read() })
                }
                continue
            }
            if case let .activity(.fanout(id, operation)) = request {
                guard peerUID(fd) == UInt32(getuid()), clients[fd]?.tunnel != true else { send(.error("Fan-out administration requires the local host."), to: fd); continue }
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    registry.handleActivity(.fanout(requestID: id, operation: operation), cancelled: { cancellation.read() })
                }
                continue
            }
            if case let .activity(.worktrees(id, operation)) = request {
                guard peerUID(fd) == UInt32(getuid()), clients[fd]?.tunnel != true else { send(.error("Managed worktree administration requires the local host."), to: fd); continue }
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    registry.handleActivity(.worktrees(requestID: id, operation: operation), cancelled: { cancellation.read() })
                }
                continue
            }
            if case let .searchOutput(id, query, caseSensitive, sessionID, offset, generation) = request {
                scheduleSearch(id: id, fd: fd) { [registry, epoch] cancellation in
                    registry.searchOutput(query: query, caseSensitive: caseSensitive, sessionID: sessionID,
                                          offset: offset, epoch: epoch, cancelled: cancellation, generation: generation)
                }
                continue
            }
            if case let .searchOutputFiltered(id, query, caseSensitive, sessionID, offset, generation, filter) = request {
                scheduleSearch(id: id, fd: fd) { [registry, epoch] cancellation in
                    registry.searchOutput(query: query, caseSensitive: caseSensitive, sessionID: sessionID,
                        offset: offset, epoch: epoch, cancelled: cancellation, generation: generation, filter: filter)
                }
                continue
            }
            if case let .validateOutputMatch(id, match, expectedEpoch, revision) = request {
                guard expectedEpoch == epoch else { send(.error("This daemon restarted. Search again."), to: fd); continue }
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    registry.validateOutputMatch(match, revision: revision, cancelled: cancellation)
                }
                continue
            }
            if case let .searchPaths(id, surfaceID, path, query, project) = request {
                scheduleSearch(id: id, fd: fd) { [registry] cancellation in
                    registry.searchPaths(surfaceID: surfaceID, path: path, query: query, project: project, cancelled: cancellation)
                }
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
    private func scheduleSearch(id: UUID, fd: Int32, work: @escaping @Sendable (SurfaceRegistry.FlagBox) -> IPCResponse) {
        if let cancelled = cancelledSearches.removeValue(forKey: id), Date().timeIntervalSince(cancelled) < 30 {
            send(.error("Search cancelled"), to: fd)
            return
        }
        guard searches.count < 32, searches[id] == nil else {
            send(.error("Too many searches are running. Try again shortly."), to: fd)
            return
        }
        let cancellation = SurfaceRegistry.FlagBox()
        searches[id] = (fd, cancellation)
        searchQueue.addOperation { [weak self] in
            let response = work(cancellation)
            self?.queue.async { [weak self] in
                guard let self, let search = self.searches[id], search.cancellation === cancellation else { return }
                self.searches.removeValue(forKey: id)
                self.send(response, to: search.fd)
            }
        }
    }

    private func handleClientLifecycle(_ request: IPCRequest, fd: Int32) -> IPCResponse? {
        switch request {
        case .activity(.hook), .activity(.resumePolicy), .activity(.resume), .activity(.explain), .activity(.power), .activity(.notifications), .activity(.terminateTree), .activity(.configure), .retryHistory:
            guard peerUID(fd) == UInt32(getuid()), clients[fd]?.tunnel != true else { return .error("This operation is available only to local owner processes.") }
            return nil
        case let .handoverDaemon(phase, checkpoint):
            guard SessionHostClient.configured != nil, peerUID(fd) == UInt32(getuid()) else {
                return .error("Handover controls are available only on the private daemon socket.")
            }
            let response = registry.handover(phase, checkpoint: checkpoint)
            if phase != .prepare, case .ok = response { startHostCheckpointTimer() }
            return response
        case .replaceDaemon:
            return .error("Daemon replacement requires the stable session host. Close legacy shells before adopting that architecture.")
        case let .shutdownDaemon(requireEmpty):
            guard peerUID(fd) == UInt32(getuid()), clients[fd]?.tunnel != true else {
                return .error("Session-service administration requires a local owner connection.")
            }
            guard let onShutdown else { return .error("Shutdown is unavailable in this host.") }
            let result = registry.beginShutdown(requireEmpty: requireEmpty)
            if case .ok = result {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: onShutdown)
            }
            return result
        case let .identifyClient(label):
            // Idempotent: identifying twice on the same socket updates the label
            // but keeps the same client ID so callers can identify-then-act.
            if var record = clients[fd] {
                record.label = label
                clients[fd] = record
                return .clientID(record.id)
            }
            var record = ClientRecord(id: UUID(), label: label, connectedAt: Date())
            record.principalUID = peerUID(fd)
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
                        connectedAt: entry.value.connectedAt,
                        kind: entry.value.kind,
                        version: entry.value.version,
                        principalUID: entry.value.principalUID ?? peerUID(entry.key),
                        tunnel: entry.value.tunnel,
                        age: Date().timeIntervalSince(entry.value.connectedAt)
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
        case let .presentClient(kind, version, uid, tunnel):
            guard var record = clients[fd] else { return .error("client is not identified") }
            record.kind = kind
            record.version = version
            record.tunnel = tunnel
            if record.principalUID == nil { record.principalUID = uid }
            clients[fd] = record
            return .ok
        case let .publishKeymap(generation, hash):
            registry.noteKeymap(generation: generation, hash: hash)
            return .ok
        case .noteHostsChanged:
            registry.noteHostsChanged()
            return .ok
        case let .noteClientConnection(host):
            registry.noteClientConnection(host: host)
            return .ok
        case let .noteTailscaleStatus(peerCount):
            registry.noteTailscaleStatus(peerCount: peerCount)
            return .ok
        case .daemonStats:
            let telemetry = registry.surfaceTelemetry
            let totalSubs = outputSubscriptions.values.reduce(0) { $0 + $1.count }
            let parked = registry.parkTelemetry
            var stats = DaemonStats(
                pid: getpid(),
                uptimeSeconds: Date().timeIntervalSince(startedAt),
                surfaceCount: telemetry.surfaceCount,
                totalScrollbackBytes: telemetry.scrollbackBytes,
                clientCount: clients.count,
                subscriberCount: totalSubs,
                snapshotRevision: registry.revision,
                version: HarnessVersion.short,
                build: HarnessVersion.build,
                capabilities: DaemonStats.currentCapabilities + (SessionHostClient.configured == nil ? [] : [DaemonStats.sessionHostWorker]),
                parkedSurfaceCount: parked.count,
                parkedStoredBytes: parked.stored,
                parkedRawBytes: parked.raw,
                startupMillis: registry.startupMillis.merging(startupMillis) { $1 },
                epoch: epoch,
                protocolLevel: HarnessVersion.protocolLevel
            )
            stats.daemonAvailable = true
            stats.historyProtection = registry.activity.store.protectionKind
            stats.historyUnavailable = registry.activity.unavailable()
            return .daemonStats(stats)
        default:
            return nil
        }
    }

    private func peerUID(_ fd: Int32) -> UInt32? {
        let uid = harness_peer_uid(fd)
        return uid >= 0 ? UInt32(uid) : nil
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
        // Mutate in place through the subscript: copying the entry out would copy-on-write the
        // whole backlog per frame (quadratic once a client falls behind).
        writeBuffers[fd, default: PendingWrite(data: Data())].data.append(data) // amortized O(1)
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
        // Moved out of the map (not copied) so the compaction below mutates unique storage; every
        // path re-inserts it or leaves it removed.
        guard var pending = writeBuffers.removeValue(forKey: fd), pending.remaining > 0 else {
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
            suspendWriteSource(fd: fd)
            clientSources[fd]?.cancel() // EPIPE / peer gone
        }
    }

    private func ensureWriteSource(fd: Int32) {
        guard writeSources[fd] == nil, let descriptor = clientDescriptors[fd] else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.flushWrites(fd: fd) }
        descriptor.register(src)
        writeSources[fd] = src
        src.resume()
    }

    private func suspendWriteSource(fd: Int32) {
        if let src = writeSources.removeValue(forKey: fd) { src.cancel() }
    }

    private func handleSubscribe(surfaceID: String, label: String?, fd: Int32) {
        guard addOutputSubscription(surfaceID: surfaceID, label: label, fd: fd, gate: nil) != nil else {
            send(.error("Surface not found"), to: fd)
            return
        }
        send(.ok, to: fd)
    }

    /// `attachStream`: the reply (with the screen on a resync), then the history as ordinary
    /// output frames, then live output. The history and screen are read off the server queue,
    /// since a cold pane's screen is a parse of its ring and no other client should wait on it,
    /// while this client's live frames are held. Back on the queue the reply and history go
    /// out, then the held frames the history doesn't cover: nothing is missed or sent twice.
    /// History is binary frames, so its size is bounded by the ring, not the JSON frame cap.
    private func handleAttach(_ attach: AttachRequest, fd: Int32) {
        if attach.readOnly { readOnlyClients.insert(fd) } else { readOnlyClients.remove(fd) }
        streamClients.insert(fd)
        if attach.inputErrors == true { inputErrorClients.insert(fd) }
        let gate = AttachGate()
        guard let token = addOutputSubscription(surfaceID: attach.surfaceID, label: attach.label, fd: fd, gate: gate, geometryEvents: attach.geometryEvents == true) else {
            send(.error("Surface not found"), to: fd)
            return
        }
        let resumeFrom = attach.epoch == epoch ? attach.fromSequence : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self, registry] in
            let start = registry.attachHistory(surfaceID: attach.surfaceID, history: attach.history, fromSequence: resumeFrom, screenOnResync: attach.screenOnResync == true, includeCheckpoint: attach.checkpoint == true)
            self?.queue.async { [weak self] in
                // The client may have gone, and its fd been reused, while the history was read.
                guard let self, self.outputSubscriptions[fd]?.contains(where: { $0.token == token }) == true else { return }
                guard let start else {
                    self.send(.error("Surface not found"), to: fd)
                    return
                }
                if attach.checkpoint == true, start.resync, start.screen?.checkpoint == nil {
                    self.send(.error("Terminal checkpoint unavailable or exceeds the 8 MiB limit. Reduce pane graphics or geometry and reconnect."), to: fd)
                    return
                }
                self.send(.attached(AttachReply(
                    epoch: self.epoch, resync: start.resync, endSequence: start.endSequence, screen: attach.checkpoint == true ? nil : start.screen?.vt, inputErrors: attach.inputErrors == true ? true : nil,
                    replaySizes: start.replaySizes, checkpoint: attach.checkpoint == true ? start.screen?.checkpoint : nil
                )), to: fd)
                for chunk in start.chunks {
                    self.sendDataFrame(chunk.data, sequence: chunk.sequence, to: fd)
                }
                for frame in gate.open(floor: start.endSequence) {
                    if let wire = frame.wire { self.enqueue(wire, to: fd) }
                }
            }
        }
    }

    /// Streams `surfaceID`'s output to `fd` and registers `fd` as a client. `gate` holds live
    /// frames until an attach's history is out. The subscription's token, or nil when the
    /// surface doesn't exist.
    private func addOutputSubscription(surfaceID: String, label: String?, fd: Int32, gate: AttachGate?, geometryEvents: Bool = false) -> UUID? {
        let deliveryID = UUID()
        let resizeHandler: (@Sendable (ReplaySize) -> Void)?
        if geometryEvents {
            resizeHandler = { [weak self] size in
            self?.queue.async { [weak self] in
                guard let self, self.outputSubscriptions[fd]?.contains(where: { $0.deliveryID == deliveryID }) == true else { return }
                if let gate, !gate.admits(.resize(size)) { if gate.overflowed { self.clientSources[fd]?.cancel() }; return }
                self.send(.terminalResize(size), to: fd)
            }
            }
        } else { resizeHandler = nil }
        guard let token = registry.subscribe(surfaceID: surfaceID, onResize: resizeHandler, handler: { [weak self] data, sequence in
            guard let server = self else { return }
            server.queue.async { [weak server] in
                // Cancellation cannot retract a callback already captured by the PTY's
                // delivery queue. The descriptor may now belong to an unrelated RPC or
                // a new attachment, so validate this exact subscription before writing.
                guard let server,
                      server.outputSubscriptions[fd]?.contains(where: { $0.deliveryID == deliveryID }) == true
                else { return }
                if let gate, !gate.admits(.output(data, sequence)) { if gate.overflowed { server.clientSources[fd]?.cancel() }; return }
                server.registry.metrics.recordOutputNotification()
                server.sendDataFrame(data, sequence: sequence, to: fd)
            }
        }) else {
            return nil
        }
        outputSubscriptions[fd, default: []].append((surfaceID, token, deliveryID))
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
        return token
    }

    /// Record this client's requested size. In `smallest` mode the PTY becomes the
    /// minimum vote. In `owner` mode only the owner's vote changes the PTY; a
    /// non-owner records an advisory size and this returns without resizing.
    private func handleResize(surfaceID: String, rows: UInt16, cols: UInt16, fd: Int32) -> IPCResponse {
        guard TerminalGeometry.isValid(cols: Int(cols), rows: Int(rows)) else { return .error("Terminal dimensions exceed the supported grid limit.") }
        guard registry.surfaceSize(surfaceID) != nil else { return .error("Surface not found.") }
        guard !readOnlyClients.contains(fd) else { return .ok }
        let previousArbiter = sizeArbiter
        guard let size = sizeArbiter.vote(client: fd, surface: surfaceID, rows: rows, cols: cols) else { return .ok }
        let response = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: size.rows, cols: size.cols))
        if case .error = response { sizeArbiter = previousArbiter }
        return response
    }

    private func pushFollow(_ event: FollowEvent) {
        guard let line = try? event.jsonLine() else { return }
        for (fd, subscription) in eventSubscribers where subscription.accepts(event) {
            send(.follow(line), to: fd)
        }
    }

    /// Reply now when the child has already exited. Otherwise hold the socket until the
    /// exit, the command-finished mark, or the timeout. The client timeout must be longer
    /// than `timeout` so this error, not the client's own, is what the caller sees.
    private func handlePaneWait(surfaceID: String, until: String, timeout: Double, fd: Int32) {
        guard until == "child" || until == "command" else {
            send(.error("until must be child or command"), to: fd)
            return
        }
        guard timeout > 0 else {
            send(.error("timeout must be greater than 0"), to: fd)
            return
        }
        if until == "child", let status = registry.storedChildExit(surfaceID: surfaceID) {
            send(.text("{\"exit\":\(status)}"), to: fd)
            return
        }
        let id = UUID()
        paneWaits[id] = PaneWait(fd: fd, surfaceID: surfaceID, until: until)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.paneWaits.removeValue(forKey: id) != nil else { return }
            self.send(.error("timeout"), to: fd)
        }
    }

    private func finishPaneWaits(surfaceID: String, until: String, status: Int32) {
        let matches = paneWaits.filter { $0.value.surfaceID == surfaceID && $0.value.until == until }
        for (id, wait) in matches {
            paneWaits.removeValue(forKey: id)
            send(.text("{\"exit\":\(status)}"), to: wait.fd)
        }
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
        if let size = sizeArbiter.disconnect(client: fd, surface: surfaceID) {
            _ = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: size.rows, cols: size.cols))
        }
        sentOwnership[fd]?[surfaceID] = nil
        pushOwnership(surfaceID)
    }

    private func cancelSubscriptions(for fd: Int32) {
        let subscriptions = outputSubscriptions.removeValue(forKey: fd) ?? []
        for subscription in subscriptions {
            registry.cancelSubscription(surfaceID: subscription.surfaceID, token: subscription.token)
        }
        snapshotSubscribers.remove(fd)
        eventSubscribers.removeValue(forKey: fd)
        paneWaits = paneWaits.filter { $0.value.fd != fd }
        // Drop this client's votes. `smallest` mode grows back to the remaining
        // minimum; `owner` mode hands the surface to the most recent other voter.
        for (surfaceID, size) in sizeArbiter.disconnect(client: fd) {
            _ = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: size.rows, cols: size.cols))
        }
        streamClients.remove(fd)
        inputErrorClients.remove(fd)
        directiveSubscribers.remove(fd)
        notificationSubscribers.remove(fd)
        let surfaces = sentOwnership.removeValue(forKey: fd).map { Array($0.keys) } ?? []
        surfaces.forEach(pushOwnership)
    }

    private func applySizeMode(_ mode: SurfaceSizeMode) -> String? {
        let previous = sizeArbiter
        for (surfaceID, size) in sizeArbiter.setMode(mode) {
            if case let .error(message) = registry.handle(.resizeSurface(surfaceID: surfaceID, rows: size.rows, cols: size.cols)) {
                sizeArbiter = previous
                return "Size mode change could not be completed; previous voting rules were retained. Some panes may already have resized. Inspect their current sizes. " + message
            }
        }
        Set(outputSubscriptions.values.flatMap { $0.map(\.surfaceID) }).forEach(pushOwnership)
        return nil
    }

    /// Tell each client attached to `surfaceID` whether it owns the size and what the size is,
    /// when that changed for it. A client that hasn't voted yet hears once it does.
    private func pushOwnership(_ surfaceID: String) {
        guard let size = registry.surfaceSize(surfaceID) else { return }
        let owner = sizeArbiter.owner(of: surfaceID)
        let responder = sizeArbiter.responder(of: surfaceID)
        for (fd, subscriptions) in outputSubscriptions where streamClients.contains(fd) && subscriptions.contains(where: { $0.surfaceID == surfaceID }) {
            let state = SizeOwnership(
                surfaceID: surfaceID,
                owner: sizeArbiter.mode == .smallest || owner == nil || owner == fd,
                rows: size.rows, cols: size.cols, mode: sizeArbiter.mode, clientID: clients[fd]?.id,
                responder: responder == nil || responder == fd
            )
            guard sentOwnership[fd]?[surfaceID] != state else { continue }
            sentOwnership[fd, default: [:]][surfaceID] = state
            send(.sizeOwnership(state), to: fd)
        }
    }

    public func runLoop() {
        dispatchMain()
    }

    /// Cancel the accept loop and tear down all client connections + subscriptions.
    /// Lets a server shut down cleanly (used by integration tests and for an orderly
    /// daemon teardown).
    private func startHostCheckpointTimer() {
        checkpointTimerLock.lock(); defer { checkpointTimerLock.unlock() }
        guard checkpointTimer == nil, let host = SessionHostClient.configured else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.harness.daemon.checkpoints"))
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.registry.isQuiesced,
                  case let .text(text) = self.registry.observationCheckpoint() else { return }
            _ = try? host.request(.applicationCheckpoint(Data(text.utf8)), timeout: 1)
        }
        timer.resume(); checkpointTimer = timer
    }

    public func stop() {
        checkpointTimerLock.lock()
        checkpointTimer?.cancel(); checkpointTimer = nil
        checkpointTimerLock.unlock()
        // Stop the background timers first (they have their own queues), then tear down the
        // socket layer. Otherwise a scan/monitor tick could fire against a half-stopped server.
        AgentScanner.shared.stop()
        registry.stopMonitoring(); registry.power.suspend(); registry.notifications.suspend(); registry.suspendScheduling(); registry.suspendAISummaries()
        // Persist any buffered scrollback AND the latest layout snapshot before tearing down, so a
        // graceful restart replays the most recent output and restores the last committed layout
        // instead of losing the last debounce window of either.
        registry.flushAllScrollback()
        registry.flushSnapshot()
        // Flush the debounced stores (options / environment / hooks / paste buffers) so the last
        // mutation in any burst's debounce window is never silently discarded on shutdown.
        registry.flushAllStores()
        queue.sync {
            if let identity = listenerSocketIdentity {
                var current = stat()
                if lstat(socketURL.path, &current) == 0,
                   current.st_dev == identity.device, current.st_ino == identity.inode {
                    unlink(socketURL.path)
                }
                listenerSocketIdentity = nil
            }
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

/// An attach's live frames: held while its history is read, then sent from where the history
/// ends. Touched only on the server queue.
private final class AttachGate: @unchecked Sendable {
    private var held: [TerminalStreamFrame]? = []
    private var heldBytes = 0
    private var floor: UInt64 = 0
    private(set) var overflowed = false
    func admits(_ frame: TerminalStreamFrame) -> Bool {
        guard !overflowed else { return false }
        guard held == nil else {
            guard heldBytes <= (8 << 20) - frame.cost, held!.count < 32768 else { overflowed = true; held = []; return false }
            held?.append(frame); heldBytes += frame.cost; return false
        }
        return frame.sequence >= floor
    }
    func open(floor: UInt64) -> [TerminalStreamFrame] {
        self.floor = floor; defer { held = nil; heldBytes = 0 }
        return overflowed ? [] : (held ?? []).filter { $0.sequence >= floor }
    }
}
