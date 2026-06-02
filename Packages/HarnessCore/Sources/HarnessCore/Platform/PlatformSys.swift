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
