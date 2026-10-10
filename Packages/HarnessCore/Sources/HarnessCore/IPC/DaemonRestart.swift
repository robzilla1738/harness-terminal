import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Administration is explicit. Probe failure and version skew never authorize a signal.
public enum DaemonRestart {
    public enum Failure: Error, CustomStringConvertible {
        case refused(String)
        public var description: String { switch self { case let .refused(message): return message } }
    }

    /// Stop only the verified local service, and wait until its process has exited.
    /// An old daemon has no atomic empty check, so it requires explicit force.
    public static func stop(force: Bool, timeout: TimeInterval = 8) throws -> URL {
        let client = DaemonClient()
        let stats: DaemonStats?
        if case let .daemonStats(value)? = try? client.request(.daemonStats, timeout: 1) { stats = value }
        else { stats = nil }
        guard let stats, case let .alive(pid) = DaemonOwnership.probe(),
              let identity = DaemonOwnership.liveIdentity(pid: pid, socket: HarnessPaths.socketURL),
              stats.pid == pid else {
            throw Failure.refused("Cannot verify the session-service owner. Existing shells have been preserved.")
        }
        let executable: URL
        if let path = identity.path { executable = URL(fileURLWithPath: path) }
        else if let current = Bundle.main.executableURL { executable = HarnessToolLocator.companion(identity.name, to: current) }
        else { executable = HarnessPaths.applicationSupport.appendingPathComponent("bin/" + identity.name) }
        if stats.supports(DaemonStats.guardedRestart) {
            let response = try client.requestFromLocalOwner(.shutdownDaemon(requireEmpty: !force), pid: pid, generation: identity.generation, timeout: 2)
            guard case .ok = response else {
                if case let .error(message) = response { throw Failure.refused(message) }
                throw Failure.refused("Shutdown was not acknowledged; existing shells have been preserved.")
            }
        } else {
            guard force else {
                throw Failure.refused("This daemon cannot atomically verify an empty session set. Close your work and use --force for an explicit restart.")
            }
            guard case let .daemonStats(confirmed) = try client.requestFromLocalOwner(.daemonStats, pid: pid, generation: identity.generation, timeout: 1),
                  confirmed.pid == pid, ProcessScan.generation(pid) == identity.generation, kill(pid, SIGTERM) == 0 else {
                throw Failure.refused("The verified daemon could not be stopped.")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return executable }
            if let current = ProcessScan.generation(pid), current != identity.generation { return executable }
            if ProcessScan.isZombie(pid) { return executable }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.refused("Shutdown is still in progress. No replacement was started; retry after the service exits.")
    }
}
