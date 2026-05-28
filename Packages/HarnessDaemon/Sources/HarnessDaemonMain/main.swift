import Darwin
import Foundation
import HarnessCore
import HarnessDaemonCore

// MARK: - Logging

/// Append a line to `~/Library/Application Support/Harness/logs/daemon.log` and
/// (best-effort) duplicate to stderr so `launchctl print` shows recent output.
/// The log file is bounded — rotated to `daemon.log.1` when it crosses 4 MiB.
@Sendable
func daemonLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date())) pid=\(getpid())] \(message)\n"
    fputs(line, stderr)
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

// MARK: - PID file

private func writePIDFile() {
    try? HarnessPaths.ensureDirectories()
    let pidString = "\(getpid())\n"
    try? pidString.write(to: HarnessPaths.daemonPIDURL, atomically: true, encoding: .utf8)
}

private func removePIDFile() {
    try? FileManager.default.removeItem(at: HarnessPaths.daemonPIDURL)
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
    }
}

/// DispatchSource holders must outlive their registration; the array keeps them alive.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

// MARK: - Stale instance handling

/// If a previous daemon left a PID file behind and that PID is no longer alive,
/// remove it before we start. If the PID *is* alive, exit with a clear message —
/// two daemons sharing a socket would corrupt the snapshot store.
private func detectStaleInstance() {
    guard FileManager.default.fileExists(atPath: HarnessPaths.daemonPIDURL.path) else { return }
    guard let raw = try? String(contentsOf: HarnessPaths.daemonPIDURL),
          let priorPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        removePIDFile()
        return
    }
    if priorPID == getpid() { return }
    // kill(pid, 0) probes existence without sending a signal.
    if kill(priorPID, 0) == 0 {
        daemonLog("another HarnessDaemon (pid \(priorPID)) is already running — refusing to start")
        exit(1)
    }
    daemonLog("removing stale PID file from pid \(priorPID)")
    removePIDFile()
}

// MARK: - Bootstrap

detectStaleInstance()
writePIDFile()
daemonLog("HarnessDaemon starting (HARNESS_HOME=\(HarnessPaths.applicationSupport.path))")

let server = DaemonServer()
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
