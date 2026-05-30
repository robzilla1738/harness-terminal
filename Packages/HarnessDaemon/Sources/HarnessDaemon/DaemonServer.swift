import Darwin
import Foundation
import HarnessCore

/// @unchecked Sendable: socket-accept and subscription state are confined to the serial `queue`.
public final class DaemonServer: @unchecked Sendable {
    public let registry = SurfaceRegistry()
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon")
    private var clientBuffers: [Int32: Data] = [:]
    private var clientSources: [Int32: DispatchSourceRead] = [:]
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
    /// `wait-for` named channels (queue-confined, like the other connection state).
    private let waitForRegistry = WaitForRegistry()
    private let startedAt = Date()

    public init() {
        // Push layout changes to snapshot subscribers (the attach-window compositor),
        // replacing its old 0.5s poll. Hop onto the serial queue for FD-safe sends.
        registry.onSnapshotCommitted = { [weak self] revision in
            guard let self else { return }
            self.queue.async { [weak self] in self?.pushSnapshotRevision(revision) }
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
            if case .pong = try? DaemonClient().request(.ping, timeout: 0.2) {
                throw DaemonError.alreadyRunning
            }
            try FileManager.default.removeItem(at: HarnessPaths.socketURL)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socketFailed }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        HarnessPaths.socketURL.path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, 104)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw DaemonError.bindFailed
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw DaemonError.listenFailed
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(listenerFD: fd)
        }
        source.resume()
        listener = source
        fputs("HarnessDaemon listening at \(HarnessPaths.socketURL.path)\n", stderr)
    }

    private func acceptConnection(listenerFD: Int32) {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        clientBuffers[clientFD] = Data()
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
                self.registry.fireClientDetached(label: removed.label)
            }
            self.clientBuffers.removeValue(forKey: clientFD)
            self.clientSources.removeValue(forKey: clientFD)
            self.cancelSubscriptions(for: clientFD)
            self.waitForRegistry.remove(fd: clientFD)
            close(clientFD)
        }
        clientSources[clientFD] = source
        source.resume()
    }

    private func readClient(fd: Int32, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 {
            source.cancel()
            return
        }
        var data = clientBuffers[fd] ?? Data()
        data.append(contentsOf: buffer.prefix(count))
        clientBuffers[fd] = data

        while let envelope = IPCCodec.decodeRequest(from: &data) {
            clientBuffers[fd] = data
            guard let request = envelope.request else { continue }
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
    }

    /// `wait-for`: register/wake fds on a named channel. `wait`/`lock` defer the reply (the
    /// client's socket read blocks) until a `signal`/`unlock` from another connection sends
    /// it. All on the serial queue — no blocking here, no registry lock.
    private func handleWaitFor(channel: String, mode: String, fd: Int32) {
        switch mode {
        case "signal":
            for waiter in waitForRegistry.signal(channel: channel) { send(.ok, to: waiter) }
            send(.ok, to: fd)
        case "lock":
            if waitForRegistry.lock(channel: channel, fd: fd) { send(.ok, to: fd) }
            // else: held — reply deferred until `unlock` grants it.
        case "unlock":
            if let granted = waitForRegistry.unlock(channel: channel) { send(.ok, to: granted) }
            send(.ok, to: fd)
        default: // "wait"
            waitForRegistry.wait(channel: channel, fd: fd)
            // reply deferred until a `signal`.
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
                snapshotRevision: registry.snapshot.revision
            )
            return .daemonStats(stats)
        default:
            return nil
        }
    }

    private func send(_ response: IPCResponse, to fd: Int32) {
        guard let data = try? IPCCodec.encode(IPCReply(response: response)) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = write(fd, base.advanced(by: written), raw.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                break
            }
        }
    }

    private func handleSubscribe(surfaceID: String, label: String?, fd: Int32) {
        guard let token = registry.subscribe(surfaceID: surfaceID, handler: { [weak self] data, sequence in
            guard let server = self else { return }
            server.queue.async { [weak server] in
                server?.send(.data(data, sequence: sequence), to: fd)
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
        }
        send(.ok, to: fd)
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
        queue.sync {
            listener?.cancel()
            listener = nil
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
