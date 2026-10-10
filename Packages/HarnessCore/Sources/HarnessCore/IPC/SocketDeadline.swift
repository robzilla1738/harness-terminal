#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One monotonic budget shared by connect, write, and read; signals never extend it.
struct SocketDeadline {
    private let end: UInt64

    init(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? min(max(timeout, 0), 86_400) : 0
        end = DispatchTime.now().uptimeNanoseconds &+ UInt64(seconds * 1_000_000_000)
    }

    func wait(_ fd: Int32, events: Int16) throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < end else { throw DaemonClientError.timeout }
            let milliseconds = Int32(min((end - now + 999_999) / 1_000_000, UInt64(100)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw DaemonClientError.connectionFailed }
                return
            }
            if result == 0 { continue }
            if errno != EINTR { throw DaemonClientError.connectionFailed }
        }
    }

    func write(_ data: Data, to fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw DaemonClientError.writeFailed }
        if flags & O_NONBLOCK == 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 {
            throw DaemonClientError.writeFailed
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try wait(fd, events: Int16(POLLOUT))
                #if canImport(Darwin)
                let flags = Int32(MSG_DONTWAIT)
                #else
                let flags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
                #endif
                let count = send(fd, base.advanced(by: offset), raw.count - offset, flags)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                else { throw DaemonClientError.writeFailed }
            }
        }
    }
}
