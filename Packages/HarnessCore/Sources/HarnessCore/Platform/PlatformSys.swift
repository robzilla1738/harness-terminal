// Single place the POSIX system library is imported and the handful of platform differences the
// daemon/CLI rely on are smoothed over. Everything else (`socket`, `bind`, `ioctl`, `errno`, the
// `AF_*`/`O_*`/`TIOC*` constants, `sockaddr_un`, …) is shared between Darwin and Glibc and used
// directly once one of these modules is imported, so callers still do their own conditional import
// of the system module — this file owns the *typed* shims where the two platforms diverge.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - stderr

/// A concurrency-safe stderr `FILE*` for the codebase's `fputs(_, harnessStderr)` logging idiom.
///
/// Swift 6 rejects direct references to the C `stderr` global on Linux (Glibc exposes it as a
/// mutable `var`, "not concurrency-safe"). Opening our own unbuffered stream on fd 2 sidesteps that
/// without referencing the flagged global, and behaves like real stderr (unbuffered, fd 2) on both
/// platforms. `nonisolated(unsafe)`: a `FILE*` isn't `Sendable`, but a write-only unbuffered stderr
/// stream is safe to share — `fputs` on it is atomic for the small lines we log.
public nonisolated(unsafe) let harnessStderr: UnsafeMutablePointer<FILE> = {
    guard let stream = fdopen(2, "w") else { fatalError("fdopen(stderr) failed") }
    setvbuf(stream, nil, _IONBF, 0)
    return stream
}()

// MARK: - Sockets

/// `socket(AF_UNIX, SOCK_STREAM, 0)`, portable: `SOCK_STREAM` is an `Int32` on Darwin but a
/// `__socket_type` enum on Glibc, so the literal call doesn't type-check on Linux.
@inline(__always)
public func makeUnixStreamSocket() -> Int32 {
    #if canImport(Glibc)
    return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    return socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
}

// MARK: - Raw syscalls that collide with same-named Swift methods

// `read`/`write`/`close` clash with instance methods (e.g. `RealPty.write`) and with Foundation, so
// callers used to disambiguate with `Darwin.` — which doesn't exist on Linux. These thin wrappers
// give one portable spelling.

// `@discardableResult` mirrors C, where these results are implicitly ignorable — without it the
// wrappers (unlike the raw C calls they replace) emit unused-result warnings at every fd-close site.
@inline(__always)
@discardableResult
public func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

@inline(__always)
@discardableResult
public func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

@inline(__always)
@discardableResult
public func sysClose(_ fd: Int32) -> Int32 {
    close(fd)
}

/// `connect(2)`, wrapped so callers (e.g. `EndpointConnector`, which has its own `connect(_:)`
/// overload) can reach the POSIX one without name ambiguity.
@inline(__always)
@discardableResult
public func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
    connect(fd, addr, len)
}

/// Decode a fixed-size C buffer that may or may not contain a trailing NUL. Used for OS APIs such
/// as `proc_pidinfo` that return a bounded path buffer rather than an owned C string.
public func decodeBoundedCString(_ pointer: UnsafePointer<CChar>, capacity: Int) -> String {
    let bytes = UnsafeBufferPointer(start: pointer, count: capacity)
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// Peer-credential lookup for the control socket lives in the `CHarnessSys` C shim
// (`harness_peer_uid`), because Linux's `struct ucred` / `SO_PEERCRED` are gated behind
// `_GNU_SOURCE`, which the Swift Glibc module doesn't expose.

// MARK: - SIGPIPE

/// Ignore `SIGPIPE` process-wide. macOS sockets set `SO_NOSIGPIPE` per-fd, but that option doesn't
/// exist on Linux and a PTY master can't use it at all — so a write that races a closing peer would
/// otherwise kill the process. The daemon installs this at boot; the per-fd option stays a Darwin
/// optimization on top.
public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// Set `SO_NOSIGPIPE` on a socket where the platform supports it (Darwin only); a no-op elsewhere,
/// where `ignoreSIGPIPE()` covers the same hazard process-wide.
@inline(__always)
public func setNoSigPipe(_ fd: Int32) {
    #if canImport(Darwin)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #endif
}
