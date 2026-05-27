import Foundation

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
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> DaemonSubscription {
        let fd = try connectSocket()
        let payload = try IPCCodec.encode(IPCEnvelope(request: .subscribeSurfaceOutput(surfaceID: surfaceID)))
        try payload.withUnsafeBytes { raw in
            guard write(fd, raw.baseAddress, raw.count) == raw.count else {
                close(fd)
                throw DaemonClientError.writeFailed
            }
        }
        let subscription = DaemonSubscription(fd: fd)
        subscription.start(onData: onData, onEnd: onEnd)
        return subscription
    }

    private func performRequest(_ ipcRequest: IPCRequest, timeout: TimeInterval) throws -> IPCResponse {
        let fd = try connectSocket()
        defer { close(fd) }

        let payload = try IPCCodec.encode(IPCEnvelope(request: ipcRequest))
        try payload.withUnsafeBytes { raw in
            guard write(fd, raw.baseAddress, raw.count) == raw.count else {
                throw DaemonClientError.writeFailed
            }
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var temp = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let count = read(fd, &temp, temp.count)
            if count > 0 {
                buffer.append(contentsOf: temp.prefix(count))
                if let reply = IPCCodec.decodeReply(from: &buffer) {
                    return reply.response
                }
            } else if count == 0 {
                break
            }
            usleep(10_000)
        }
        throw DaemonClientError.timeout
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonClientError.connectionFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        HarnessPaths.socketURL.path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, 104)
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw DaemonClientError.connectionFailed
        }
        return fd
    }
}

public final class DaemonSubscription: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-subscription")
    private var cancelled = false

    init(fd: Int32) {
        self.fd = fd
    }

    public func cancel() {
        queue.sync {
            guard !cancelled else { return }
            cancelled = true
            close(fd)
        }
    }

    fileprivate func start(
        onData: @escaping @Sendable (Data, UInt64) -> Void,
        onEnd: (@Sendable () -> Void)?
    ) {
        queue.async { [fd] in
            var buffer = Data()
            var temp = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &temp, temp.count)
                if count <= 0 { break }
                buffer.append(contentsOf: temp.prefix(count))
                while let reply = IPCCodec.decodeReply(from: &buffer) {
                    if case let .data(data, sequence) = reply.response {
                        onData(data, sequence)
                    }
                }
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

    public var description: String {
        switch self {
        case .connectionFailed: "Could not connect to HarnessDaemon"
        case .writeFailed: "Failed to write IPC request"
        case .timeout: "HarnessDaemon request timed out"
        }
    }
}
