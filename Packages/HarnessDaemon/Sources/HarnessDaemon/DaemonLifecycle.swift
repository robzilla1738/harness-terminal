#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

/// Pure, side-effect-free lifecycle decisions shared by `HarnessDaemonMain`. Kept in the
/// library (not the executable) so they're unit-testable without launching the daemon.
public enum DaemonLifecycle {
    /// What the bootstrap should do about a leftover PID file.
    public enum PriorInstanceDecision: Equatable {
        /// The recorded PID is a live HarnessDaemon — refuse to start (two daemons sharing a
        /// socket would corrupt the snapshot store).
        case refuse
        /// No live daemon owns the PID — remove the stale file and proceed. Covers a dead PID
        /// *and* a recycled PID now owned by an unrelated process (PID reuse after `kill -9`,
        /// which leaves the file behind, then macOS hands the number to something else).
        case stale
        /// No prior instance to reason about (no file, or an unparsable one already removed).
        case proceed
    }

    /// Decide whether a leftover PID belongs to a live daemon. Injectable probes keep this
    /// pure for tests; production passes the real `kill(_:0)` + `proc_pidpath` lookups.
    ///
    /// The identity check is the fix for the PID-reuse false positive: `kill(pid, 0) == 0`
    /// alone means *some* process owns the number, not that it's our daemon. After a `kill -9`
    /// (PID file survives) the kernel can recycle that PID to an unrelated process; honoring the
    /// bare liveness probe made the fresh daemon `exit(1)` with nothing listening, and the
    /// `KeepAlive` supervisor then thrashed. We only refuse when the live process actually *is*
    /// a HarnessDaemon binary. The authoritative socket ping in `DaemonServer.start()` remains
    /// the real two-daemon guard; this is the cheap fast-path so we don't even try to bind.
    public static func priorInstanceDecision(
        priorPID: pid_t,
        ownPID: pid_t,
        isAlive: (pid_t) -> Bool,
        executablePath: (pid_t) -> String?
    ) -> PriorInstanceDecision {
        // Our own PID in the file (re-exec / same process) is never a competing instance.
        if priorPID == ownPID { return .proceed }
        guard isAlive(priorPID) else { return .stale }
        guard let path = executablePath(priorPID),
              URL(fileURLWithPath: path).lastPathComponent == "HarnessDaemon"
        else {
            // Alive, but not our daemon — a recycled PID, or a binary whose name only
            // contains "HarnessDaemon" as a substring (e.g. "HarnessDaemon-old"). Exact
            // basename comparison prevents both false positives from recycled PIDs and
            // spoofing via a process named something like "not-HarnessDaemon". If this
            // daemon is ever deployed under a different binary name (e.g. wrapped for
            // testing), this check will treat the prior instance as stale — which is safe
            // because DaemonServer.start()'s socket ping is the authoritative guard.
            return .stale
        }
        return .refuse
    }

    /// `kill(pid, 0)` probes existence without delivering a signal. ESRCH ⇒ gone; EPERM ⇒
    /// the PID exists but is owned by another user (still "alive" for our purposes).
    public static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The absolute path of the executable backing `pid`, or nil if it can't be resolved
    /// (dead, or not permitted). Mirrors `AgentDetector.pidPath`.
    public static func executablePath(of pid: pid_t) -> String? {
        #if canImport(Darwin)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(MAXPATHLEN))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        #else
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard len > 0 else { return nil }
        return String(decoding: buffer[0 ..< len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    /// Remove a PID file **only if we own it** — its trimmed contents equal `ownPID`. Guards the
    /// bind-race where a losing daemon's `catch`/`atexit` cleanup must not delete the *winner's*
    /// freshly written PID file. Returns true iff a file existed, was owned by us, and was removed.
    @discardableResult
    public static func removeOwnedPIDFile(at url: URL, ownPID: pid_t) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let recorded = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              recorded == ownPID
        else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
