import Foundation
import HarnessCore

public final class DaemonServer: @unchecked Sendable {
    public let registry = SurfaceRegistry()
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon")
    private var clientBuffers: [Int32: Data] = [:]
    private var outputSubscriptions: [Int32: [(surfaceID: String, token: UUID)]] = [:]

    public init() {}

    public func start() throws {
        try HarnessPaths.ensureDirectories()
        if FileManager.default.fileExists(atPath: HarnessPaths.socketURL.path) {
            try FileManager.default.removeItem(at: HarnessPaths.socketURL)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socketFailed }

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
        clientBuffers[clientFD] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readClient(fd: clientFD, source: source)
        }
        source.setCancelHandler {
            self.cancelSubscriptions(for: clientFD)
            close(clientFD)
        }
        source.resume()
    }

    private func readClient(fd: Int32, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 {
            source.cancel()
            clientBuffers.removeValue(forKey: fd)
            return
        }
        var data = clientBuffers[fd] ?? Data()
        data.append(contentsOf: buffer.prefix(count))
        clientBuffers[fd] = data

        while let envelope = IPCCodec.decodeRequest(from: &data) {
            clientBuffers[fd] = data
            guard let request = envelope.request else { continue }
            if case let .subscribeSurfaceOutput(surfaceID) = request {
                handleSubscribe(surfaceID: surfaceID, fd: fd)
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

    private func send(_ response: IPCResponse, to fd: Int32) {
        guard let data = try? IPCCodec.encode(IPCReply(response: response)) else { return }
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    private func handleSubscribe(surfaceID: String, fd: Int32) {
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
}

public enum DaemonError: Error, CustomStringConvertible {
    case socketFailed
    case bindFailed
    case listenFailed

    public var description: String {
        switch self {
        case .socketFailed: "Failed to create socket"
        case .bindFailed: "Failed to bind socket"
        case .listenFailed: "Failed to listen on socket"
        }
    }
}
