import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Build skew is informational. Only a protocol contract can make a daemon incompatible.
public enum DaemonCompatibility: String, Codable, Sendable {
    case compatible, incompatible, unknown
}

public struct DaemonUpgrade: Equatable, Sendable {
    public var runningBuild: Int?
    public var availableBuild: Int
    public var compatibility: DaemonCompatibility
    public var shellCount: Int?
    public var sessionHostBuild: Int?
    public var pipeConsumerCount: Int?
    public var sessionHostProtocolLevel: Int?
    public var shutdownPending: Bool?
    public var daemonAvailable: Bool?

    public init(stats: DaemonStats?, availableBuild: Int = HarnessVersion.build) {
        runningBuild = stats?.build
        self.availableBuild = availableBuild
        compatibility = stats?.compatibility ?? .unknown
        shellCount = stats?.surfaceCount; pipeConsumerCount = stats?.pipeConsumerCount
        sessionHostBuild = stats?.sessionHostBuild; sessionHostProtocolLevel = stats?.sessionHostProtocolLevel
        daemonAvailable = stats?.daemonAvailable; shutdownPending = stats?.shutdownPending
    }

    public var message: String {
        if shutdownPending == true { return "Session-host shutdown is waiting for owned processes to exit. Exclusive ownership is retained; no replacement has been started." }
        if daemonAvailable == false, sessionHostBuild != nil {
            return "The application daemon is unavailable. Your shells remain running in the session host. Use Replace Application Daemon to recover control services."
        }
        if compatibility != .compatible {
            if shellCount == nil {
                return "Session-service ownership cannot be verified. Existing programs have been preserved. Inspect daemon logs and the process owner before requesting an explicit stop."
            }
            return "The running session service needs attention. Your shells have been preserved. Use daemon-restart --force only when you are ready to stop them."
        }
        if let sessionHostBuild, sessionHostBuild != availableBuild || sessionHostProtocolLevel != DaemonStats.currentSessionHostProtocolLevel {
            return "Session host build \(sessionHostBuild) has an owner update available (build \(availableBuild), protocol \(DaemonStats.currentSessionHostProtocolLevel)). Your \(shellCount ?? 0) shells and \(pipeConsumerCount ?? 0) pipe consumers are preserved; close them to adopt the owner update, or explicitly restart sessions. Application daemon updates can preserve those shells."
        }
        if sessionHostBuild != nil { return "An application daemon update is available. Replace Application Daemon preserves all existing shells." }
        return "A session-service update is available. Your \(shellCount ?? 0) existing shells are preserved; close them to adopt it, or explicitly restart sessions."
    }
}

/// Advisory ownership check. Uncertainty always prevents an automatic replacement.
public enum DaemonOwnership {
    case absent, alive(Int32), uncertain

    public static func probe(pidFile: URL = HarnessPaths.daemonPIDURL, socket: URL = HarnessPaths.socketURL) -> DaemonOwnership {
        guard FileManager.default.fileExists(atPath: pidFile.path) else {
            return FileManager.default.fileExists(atPath: socket.path) ? .uncertain : .absent
        }
        guard let raw = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return .uncertain }
        if kill(pid, 0) != 0 {
            return errno == ESRCH ? .absent : .uncertain
        }
        if ProcessScan.isZombie(pid) { return .absent }
        if let executable = executablePath(pid: pid) {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return name == "HarnessDaemon" || name == "HarnessSessionHost" ? .alive(pid) : .absent
        }
        // macOS can lose the executable vnode after an atomic bundle exchange.
        // A matching kernel socket peer and process birth still identify its owner.
        return liveIdentity(pid: pid, socket: socket) == nil ? .uncertain : .alive(pid)
    }

    public static func probe(home: URL) -> DaemonOwnership {
        if home.standardizedFileURL == HarnessPaths.applicationSupport.standardizedFileURL { return probe() }
        return probe(pidFile: home.appendingPathComponent("daemon.pid"), socket: home.appendingPathComponent("harness.sock"))
    }

    public static func executablePath(pid: Int32) -> String? {
        #if os(macOS)
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        #else
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe"))
            .map(normalizeLinuxExecutablePath)
        #endif
    }

    struct LiveIdentity {
        var path: String?
        var name: String
        var generation: String
    }

    static func liveIdentity(pid: Int32, socket: URL) -> LiveIdentity? {
        guard let generation = ProcessScan.generation(pid) else { return nil }
        if let path = executablePath(pid: pid) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name == "HarnessDaemon" || name == "HarnessSessionHost" else { return nil }
            return LiveIdentity(path: path, name: name, generation: generation)
        }
        #if os(macOS)
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = bytes.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        let name = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard name == "HarnessDaemon" || name == "HarnessSessionHost",
              let fd = try? EndpointConnector.connect(.unix(path: socket.path), deadline: SocketDeadline(timeout: 0.3)) else { return nil }
        defer { close(fd) }
        guard localPeerMatches(fd: fd, pid: pid, generation: generation) else { return nil }
        return LiveIdentity(path: nil, name: name, generation: generation)
        #else
        return nil
        #endif
    }

    /// Bind an administrative request to the kernel peer, never to a claimed
    /// response PID alone. Birth identity also fences PID reuse before the write.
    static func localPeerMatches(fd: Int32, pid: Int32, generation: String) -> Bool {
        let peer: Int32, uid: UInt32
        #if os(macOS)
        var peerPID: Int32 = 0, peerUID: uid_t = 0, peerGID: gid_t = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(fd, &peerUID, &peerGID) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0,
              size == MemoryLayout<Int32>.size else { return false }
        peer = peerPID; uid = peerUID
        #else
        struct Credentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var credentials = Credentials(), size = socklen_t(MemoryLayout<Credentials>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0,
              size == MemoryLayout<Credentials>.size else { return false }
        peer = credentials.pid; uid = credentials.uid
        #endif
        return peer == pid && uid == getuid() && ProcessScan.generation(pid) == generation
    }

    /// Linux marks an executable inode that was atomically replaced as deleted;
    /// that marker does not mean its process has stopped owning the PTYs.
    static func normalizeLinuxExecutablePath(_ path: String) -> String {
        let suffix = " (deleted)"
        return path.hasSuffix(suffix) ? String(path.dropLast(suffix.count)) : path
    }
}

/// Held before reading stores or creating shells, so a losing startup has no side effects.
public final class DaemonInstanceLock: @unchecked Sendable {
    private let descriptor: Int32
    public init(directory: URL = HarnessPaths.runtimeDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_uid == getuid(),
              (identity.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), identity.st_nlink == 1, identity.st_size == 0, fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw POSIXError(.EPERM)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }
    }
    deinit { close(descriptor) }

    /// Keep new starts outside a service-definition change. Legacy live owners are
    /// detected separately because they do not hold this lock.
    public static func whileInactive(home: URL, _ action: () throws -> Void) throws -> Bool {
        let directory = home.standardizedFileURL == HarnessPaths.applicationSupport.standardizedFileURL
            ? HarnessPaths.runtimeDirectory : home
        guard let ownership = try? DaemonInstanceLock(directory: directory),
              case .absent = DaemonOwnership.probe(home: home) else { return false }
        try withExtendedLifetime(ownership) { try action() }
        return true
    }
}
