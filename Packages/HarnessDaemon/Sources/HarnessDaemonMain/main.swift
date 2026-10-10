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
    if case .uncertain = DaemonOwnership.probe() {
        daemonLog("session-service ownership is uncertain — refusing startup without creating shells or changing stores")
        exit(1)
    }
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

if CommandLine.arguments.dropFirst().first == "--terminal-pipe-worker" { exit(TerminalPipeWorker.runWorker()) }

/// Parent-loss cleanup only unlinks the socket inode this worker actually bound.
/// It performs no layout/history flush and never touches the owner's public socket.
private final class WorkerSocketOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var owned: (path: String, device: dev_t, inode: ino_t)?
    func record(_ url: URL?) {
        guard let url else { return }; var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return }
        lock.lock(); owned = (url.path, info.st_dev, info.st_ino); lock.unlock()
    }
    func removeOwnedSocket() {
        lock.lock(); let owned = owned; lock.unlock()
        guard let owned else { return }; var info = stat()
        if lstat(owned.path, &info) == 0, info.st_dev == owned.device, info.st_ino == owned.inode { _ = unlink(owned.path) }
    }
}
private let workerSocketOwnership = WorkerSocketOwnership()

// MARK: - Bootstrap

if CommandLine.arguments.dropFirst().contains("--search-regex-worker") { exit(IsolatedRegex.runWorker()) }
if CommandLine.arguments.dropFirst().first == "--managed-git-worker" { exit(ManagedGitWorker.runWorker()) }
SessionHostBootstrap.enterOwnerIfAvailable()
nonisolated(unsafe) private var retainedParentWatch: (any DispatchSourceProtocol)?
let hosted = ProcessInfo.processInfo.environment["HARNESS_SESSION_HOST_SOCKET"] != nil
let instanceLock: DaemonInstanceLock?
do { instanceLock = hosted ? nil : try DaemonInstanceLock() }
catch { fputs("HarnessDaemon: cannot acquire exclusive ownership of this home (\(error)); refusing startup\n", harnessStderr); exit(1) }
if !hosted { detectStaleInstance(); writePIDFile() }
let mutationLease: DaemonMutationLease?
if hosted {
    let environment = ProcessInfo.processInfo.environment
    guard let parent = environment["HARNESS_SESSION_HOST_PID"].flatMap(Int32.init), parent > 1,
          let identity = environment["HARNESS_SESSION_HOST_IDENTITY"], getppid() == parent, ProcessScan.generation(parent) == identity else {
        fputs("HarnessDaemon: hosted worker parent identity could not be verified; no stores or programs were mutated.\n", harnessStderr); exit(1)
    }
    // Parent loss exits immediately, rather than flushing stale state after another
    // host recovers. The write-lease descriptor remains held until all threads exit.
    #if canImport(Darwin)
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
    parentWatch.setEventHandler { workerSocketOwnership.removeOwnedSocket(); _exit(0) }; parentWatch.resume()
    #else
    let parentWatch = DispatchSource.makeTimerSource(queue: .global())
    parentWatch.schedule(deadline: .now(), repeating: 0.25)
    parentWatch.setEventHandler { if getppid() != parent { workerSocketOwnership.removeOwnedSocket(); _exit(0) } }; parentWatch.resume()
    #endif
    // Catch a parent that exited between the identity check and watcher arming.
    guard getppid() == parent, ProcessScan.generation(parent) == identity else { _exit(0) }
    do { mutationLease = try DaemonMutationLease(initiallyActive: environment["HARNESS_DAEMON_WARM"] != "1") }
    catch { fputs("HarnessDaemon: another worker holds the mutation lease; refusing activation without changing stores.\n", harnessStderr); exit(1) }
    // Keep the source alive for the executable's complete runLoop lifetime.
    retainedParentWatch = parentWatch
} else { mutationLease = nil }
daemonLog("HarnessDaemon starting (HARNESS_HOME=\(HarnessPaths.applicationSupport.path))")

// Ignore SIGPIPE process-wide: a PTY master or socket write that races a closing peer would
// otherwise kill the daemon. macOS additionally sets SO_NOSIGPIPE per socket fd; this covers the
// PTY masters (which can't use that option) and is the only protection on Linux.
ignoreSIGPIPE()

let workerSocket = ProcessInfo.processInfo.environment["HARNESS_DAEMON_SOCKET"].map { URL(fileURLWithPath: $0) }
let server = DaemonServer(enableVersionBanner: true, enablePowerManagement: true, socketURL: workerSocket ?? HarnessPaths.socketURL, mutationLease: mutationLease)
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

server.onShutdown = shutdown
installSignalHandlers(server: server, shutdown: shutdown)
atexit { removePIDFile() }

do {
    try server.start()
    workerSocketOwnership.record(workerSocket)
    if ProcessInfo.processInfo.environment["HARNESS_DAEMON_WARM"] != "1" {
        AgentScanner.shared.start(registry: server.registry); server.registry.activatePowerManagement()
    }
    daemonLog("HarnessDaemon ready (socket=\(HarnessPaths.socketURL.path))")
    server.runLoop()
} catch {
    daemonLog("HarnessDaemon failed: \(error)")
    removePIDFile()
    exit(1)
}
