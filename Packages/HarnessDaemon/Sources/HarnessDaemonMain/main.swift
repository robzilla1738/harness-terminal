#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessDaemonCore

// MARK: - Logging

/// Serializes the size-check→rotate→append sequence below. `daemonLog` is called from
/// four signal `DispatchSource`s on the `.global()` *concurrent* queue, so without this
/// gate parallel handlers could double-rotate or clobber each other's non-`O_APPEND`
/// writes. No reentrancy: `daemonLog` never calls itself, so `.sync` can't deadlock.
private let daemonLogQueue = DispatchQueue(label: "com.robert.harness.daemonLog")

/// Shared ISO 8601 formatter for log timestamps. Hoisted to file scope so we pay the
/// allocation and calendar-setup cost once, not on every log call.
///
/// `nonisolated(unsafe)` is correct here: ISO8601DateFormatter is documented thread-safe
/// on macOS 10.12+ (it was made Sendable in the SDK as of the concurrency annotations
/// sweep). We never mutate this after initialisation, so all concurrent reads are safe.
/// The formatter is write-once (no calendar/locale changes after init), which is the
/// documented precondition for thread-safety.
private nonisolated(unsafe) let daemonLogFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    // Keep the default options (fractional seconds off, timezone Z suffix) — these
    // match what the previous per-call formatter produced, so log format is unchanged.
    return f
}()

/// Append a line to `~/Library/Application Support/Harness/logs/daemon.log` and
/// (best-effort) duplicate to stderr so `launchctl print` shows recent output.
/// The log file is bounded — rotated to `daemon.log.1` when it crosses 4 MiB.
@Sendable
func daemonLog(_ message: String) {
    let line = "[\(daemonLogFormatter.string(from: Date())) pid=\(getpid())] \(message)\n"
    fputs(line, harnessStderr)
    daemonLogQueue.sync {
        let url = HarnessPaths.daemonLogURL
        try? HarnessPaths.ensureDirectories()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > 4 * 1024 * 1024 {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("daemon.log.1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - PID file

private func writePIDFile() {
    try? HarnessPaths.ensureDirectories()
    let pidString = "\(getpid())\n"
    try? pidString.write(to: HarnessPaths.daemonPIDURL, atomically: true, encoding: .utf8)
}

/// Unconditional removal — used when reclaiming a *stale/foreign* PID file
/// (`detectStaleInstance`), where the file by design isn't ours to own-check.
private func removeForeignPIDFile() {
    try? FileManager.default.removeItem(at: HarnessPaths.daemonPIDURL)
}

/// Owner-checked removal — only deletes the file if it still records *our* PID.
/// Guards the bind-race where a losing daemon's `catch`/`atexit` cleanup must not
/// delete the winner's freshly written PID file.
private func removePIDFile() {
    DaemonLifecycle.removeOwnedPIDFile(at: HarnessPaths.daemonPIDURL, ownPID: getpid())
}

// MARK: - Signal handling

/// Install handlers for orderly shutdown (SIGTERM, SIGINT), config reload (SIGHUP),
/// and runtime stats dump (SIGUSR1). DispatchSource is used because POSIX
/// `signal(2)` handlers may only call async-signal-safe functions and we want to
/// touch Swift state (the server, the log) on shutdown.
private func installSignalHandlers(server: DaemonServer, shutdown: @escaping @Sendable () -> Void) {
    func install(_ signo: Int32, _ handler: @escaping @Sendable () -> Void) {
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        // Retain the source so it stays alive for the process lifetime.
        signalSources.append(source)
    }
    install(SIGTERM) {
        daemonLog("received SIGTERM — graceful shutdown")
        shutdown()
    }
    install(SIGINT) {
        daemonLog("received SIGINT — graceful shutdown")
        shutdown()
    }
    install(SIGHUP) {
        daemonLog("received SIGHUP — reloading agent table")
        // Agent table is loaded on each scan tick; no further action needed today.
        // settings.json / keybindings.json reload land in later phases.
    }
    install(SIGUSR1) {
        let telemetry = server.registry.surfaceTelemetry
        daemonLog("stats: surfaces=\(telemetry.surfaceCount) scrollback=\(telemetry.scrollbackBytes)B")
        daemonLog(server.registry.metrics.summary())
    }
}

/// DispatchSource holders must outlive their registration; the array keeps them alive.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

// MARK: - Stale instance handling

/// If a previous daemon left a PID file behind and that PID is no longer a live
/// HarnessDaemon, remove it before we start. If a live daemon owns the PID, exit with
/// a clear message — two daemons sharing a socket would corrupt the snapshot store.
///
/// The identity check matters: after `kill -9` the PID file survives, and macOS can
/// recycle the freed PID to an unrelated process. A bare `kill(pid, 0)` liveness probe
/// then false-positives, making the fresh daemon `exit(1)` with nothing listening and
/// the `KeepAlive` supervisor thrashing. We only refuse when the live PID is actually a
/// HarnessDaemon binary; `DaemonServer.start()`'s socket ping is the authoritative guard.
private func detectStaleInstance() {
    guard FileManager.default.fileExists(atPath: HarnessPaths.daemonPIDURL.path) else { return }
    guard let raw = try? String(contentsOf: HarnessPaths.daemonPIDURL, encoding: .utf8),
          let priorPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        removeForeignPIDFile()
        return
    }
    switch DaemonLifecycle.priorInstanceDecision(
        priorPID: priorPID,
        ownPID: getpid(),
        isAlive: DaemonLifecycle.processIsAlive,
        executablePath: DaemonLifecycle.executablePath
    ) {
    case .proceed:
        return
    case .refuse:
        daemonLog("another HarnessDaemon (pid \(priorPID)) is already running — refusing to start")
        exit(1)
    case .stale:
        daemonLog("removing stale PID file from pid \(priorPID)")
        removeForeignPIDFile()
    }
}

// MARK: - Bootstrap

detectStaleInstance()
writePIDFile()
daemonLog("HarnessDaemon starting (HARNESS_HOME=\(HarnessPaths.applicationSupport.path))")

// Ignore SIGPIPE process-wide: a PTY master or socket write that races a closing peer would
// otherwise kill the daemon. macOS additionally sets SO_NOSIGPIPE per socket fd; this covers the
// PTY masters (which can't use that option) and is the only protection on Linux.
ignoreSIGPIPE()

let server = DaemonServer(enableVersionBanner: true)
nonisolated(unsafe) var hasShutDown = false
let shutdownLock = NSLock()

let shutdown: @Sendable () -> Void = {
    shutdownLock.lock()
    let already = hasShutDown
    hasShutDown = true
    shutdownLock.unlock()
    guard !already else { return }
    server.stop()
    removePIDFile()
    daemonLog("HarnessDaemon stopped")
    exit(0)
}

installSignalHandlers(server: server, shutdown: shutdown)
atexit { removePIDFile() }

do {
    try server.start()
    AgentScanner.shared.start(registry: server.registry)
    daemonLog("HarnessDaemon ready (socket=\(HarnessPaths.socketURL.path))")
    server.runLoop()
} catch {
    daemonLog("HarnessDaemon failed: \(error)")
    removePIDFile()
    exit(1)
}
