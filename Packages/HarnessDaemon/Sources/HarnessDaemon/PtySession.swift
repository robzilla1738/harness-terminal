import Foundation
import HarnessCore

/// Shell session managed by the daemon (Process-based; suitable for CLI automation).
/// Phase 5 will replace the Process backing with a real `forkpty` PTY so detach/
/// reattach and live scrollback work — until then the public surface area is
/// already shaped to support those flows.
public final class PtySession: @unchecked Sendable {
    public let id: DaemonSurfaceID
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let readQueue = DispatchQueue(label: "com.robert.harness.pty-read")

    /// Forwarded to live subscribers (the running app + any harness-cli attach client).
    public var onOutput: ((Data) -> Void)?
    public var onExit: (() -> Void)?

    /// Append-only ring buffer of recent output bytes. Used for `replay()` so a
    /// reattaching client can replay history. Default 256 KiB.
    private var scrollback = Data()
    private let scrollbackLimit = 256 * 1024
    private let scrollbackLock = NSLock()
    private var sequence: UInt64 = 0

    /// Currently-attached subscribers. The daemon socket layer fans output to
    /// each entry. Detaching just removes the closure without killing the PTY.
    private var subscribers: [UUID: (Data) -> Void] = [:]
    private let subscribersLock = NSLock()

    public init(id: DaemonSurfaceID, cwd: String, shell: String) throws {
        self.id = id
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["HARNESS_SURFACE"] = id
        process.environment = env
        process.terminationHandler = { [weak self] _ in
            self?.onExit?()
        }
        try process.run()
        AgentDetector.registerRootPID(process.processIdentifier, forSurfaceKey: id)
        startReading()
    }

    public func write(_ data: Data) {
        stdinPipe.fileHandleForWriting.write(data)
    }

    public func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(data)
    }

    public func resize(rows _: UInt16, cols _: UInt16) {
        // No-op until forkpty/RealPty (Phase 5). Documented so callers see no surprise.
    }

    public func close() {
        if process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Returns the captured viewport — for now we just return the scrollback
    /// (which is the same buffer libghostty uses to repaint on reattach). When
    /// `includeHistory == false` the caller only gets the most recent ~16 KiB.
    public func captureScrollback(includeHistory: Bool) -> String {
        scrollbackLock.lock()
        let data: Data
        if includeHistory {
            data = scrollback
        } else {
            let limit = min(scrollback.count, 16 * 1024)
            data = scrollback.suffix(limit)
        }
        scrollbackLock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func replay(fromSequence: UInt64?) -> String {
        captureScrollback(includeHistory: true)
    }

    public func subscribe(_ handler: @escaping (Data) -> Void) -> UUID {
        let token = UUID()
        subscribersLock.lock()
        subscribers[token] = handler
        subscribersLock.unlock()
        return token
    }

    public func cancelSubscription(token: UUID? = nil) {
        subscribersLock.lock()
        if let token { subscribers.removeValue(forKey: token) } else { subscribers.removeAll() }
        subscribersLock.unlock()
    }

    /// Phase 5 alias — for now identical to `cancelSubscription` but will keep
    /// the underlying PTY alive when `RealPty` lands.
    public func detachSubscriber(token: UUID? = nil) {
        cancelSubscription(token: token)
    }

    private func startReading() {
        let handle = stdoutPipe.fileHandleForReading
        readQueue.async { [weak self] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                self?.handleOutput(data)
            }
        }
    }

    private func handleOutput(_ data: Data) {
        scrollbackLock.lock()
        scrollback.append(data)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
        sequence &+= UInt64(data.count)
        scrollbackLock.unlock()

        AgentDetector.recordActivity(forSurfaceKey: id)
        onOutput?(data)

        subscribersLock.lock()
        let handlers = Array(subscribers.values)
        subscribersLock.unlock()
        for handler in handlers { handler(data) }
    }
}

public enum PtyError: Error, CustomStringConvertible {
    case launchFailed

    public var description: String {
        "Failed to launch shell process"
    }
}
