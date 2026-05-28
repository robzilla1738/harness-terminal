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

    private struct ClientRecord {
        let id: UUID
        var label: String
        let connectedAt: Date
    }
    private var clients: [Int32: ClientRecord] = [:]
    private var clientFDsByID: [UUID: Int32] = [:]
    private let startedAt = Date()

    public init() {}

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
            }
            self.clientBuffers.removeValue(forKey: clientFD)
            self.clientSources.removeValue(forKey: clientFD)
            self.cancelSubscriptions(for: clientFD)
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

    private func cancelSubscriptions(for fd: Int32) {
        let subscriptions = outputSubscriptions.removeValue(forKey: fd) ?? []
        for subscription in subscriptions {
            registry.cancelSubscription(surfaceID: subscription.surfaceID, token: subscription.token)
        }
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
