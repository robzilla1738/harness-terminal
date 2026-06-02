#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Opens a connected socket to an `Endpoint`, returning the fd (caller owns it). The framing
/// (`IPCCodec`) and subscription read loop (`DaemonSubscription`) are transport-agnostic, so this is
/// the single place that knows how to establish the byte stream — letting `DaemonClient` target a
/// local socket or a tunnelled remote one through the same code.
public enum EndpointConnector {
    public static func connect(_ endpoint: Endpoint) throws -> Int32 {
        switch endpoint {
        case let .unix(path):
            return try connectUnix(path: path)
        case .tcp:
            // A native encrypted TCP transport is a later phase; until then, remote access goes
            // through an SSH tunnel that presents the daemon as a local Unix socket.
            throw EndpointError.notYetSupported("native TCP transport (use an SSH tunnel for now)")
        }
    }

    private static func connectUnix(path: String) throws -> Int32 {
        // Validate before opening the fd so an over-long path can't leak a socket — and so a deep
        // HARNESS_HOME (or tunnel path) fails clearly instead of silently truncating to the wrong
        // socket.
        guard path.utf8.count < HarnessPaths.maxSocketPathLength else {
            throw EndpointError.pathTooLong(path: path, limit: HarnessPaths.maxSocketPathLength)
        }
        let fd = makeUnixStreamSocket()
        guard fd >= 0 else { throw EndpointError.connectionFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, sunPathCapacity - 1)
                dest[sunPathCapacity - 1] = 0
            }
        }
        // connect() can be interrupted by a signal (EINTR). For a blocking AF_UNIX stream socket the
        // connect completes synchronously, so retry on EINTR rather than spuriously failing.
        var connected: Int32 = -1
        repeat {
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while connected != 0 && errno == EINTR
        guard connected == 0 else {
            close(fd)
            throw EndpointError.connectionFailed
        }
        setNoSigPipe(fd)
        return fd
    }
}
