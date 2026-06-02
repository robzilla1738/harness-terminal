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

/// Cross-platform terminal window size (`struct winsize`). Spelled the same on both platforms,
/// aliased here so call sites don't have to module-qualify it (`Darwin.winsize` won't resolve on
/// Linux).
public typealias WinSize = winsize

// MARK: - Raw syscalls that collide with same-named Swift methods

// `read`/`write`/`close` clash with instance methods (e.g. `RealPty.write`) and with Foundation, so
// callers used to disambiguate with `Darwin.` — which doesn't exist on Linux. These thin wrappers
// give one portable spelling.

@inline(__always)
public func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

@inline(__always)
public func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

@inline(__always)
public func sysClose(_ fd: Int32) -> Int32 {
    close(fd)
}

/// `connect(2)`, wrapped so callers (e.g. `EndpointConnector`, which has its own `connect(_:)`
/// overload) can reach the POSIX one without name ambiguity.
@inline(__always)
public func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
    connect(fd, addr, len)
}

// MARK: - Peer credentials

/// The UID of the process on the other end of a connected `AF_UNIX` stream socket, or nil if it
/// can't be determined. Uses `getpeereid` on Darwin/BSD and `SO_PEERCRED` on Linux — both read
/// credentials the kernel recorded at connect time, so a peer can't spoof them. Returning the UID
/// (rather than a bool) lets the daemon compare against its own `geteuid()`.
public func peerUID(ofSocket fd: Int32) -> uid_t? {
    #if canImport(Darwin)
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
    return uid
    #elseif canImport(Glibc)
    var cred = ucred()
    var len = socklen_t(MemoryLayout<ucred>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 else { return nil }
    return cred.uid
    #else
    return nil
    #endif
}

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
