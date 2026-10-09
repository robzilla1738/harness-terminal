#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

/// Bounded, whole-write admission before dispatching work. The nonblocking descriptor is
/// pinned to the shell generation at admission, so queued input cannot reach a replacement.
final class PtyInputWriter: @unchecked Sendable {
    static let maxPending = 8 * 1024 * 1024
    private let queue: DispatchQueue
    private let limit: Int
    private let lock = NSLock()
    private var pending = Data()
    private var master: (fd: Int32, generation: UInt64)?
    private var newestGeneration: UInt64 = 0
    private var scheduled = false
    private var waiting: DispatchSourceWrite?
    private var waitToken: UUID?

    init(queue: DispatchQueue, limit: Int = maxPending) {
        self.queue = queue
        self.limit = limit
    }

    /// Takes ownership of the supplied dup, including on rejection. No partial paste is admitted.
    @discardableResult
    func write(_ data: Data, master incoming: (fd: Int32, generation: UInt64)?) -> Bool {
        guard let incoming else { return data.isEmpty }
        guard !data.isEmpty else { sysClose(incoming.fd); return true }
        lock.lock()
        defer { lock.unlock() }
        guard incoming.generation >= newestGeneration else { sysClose(incoming.fd); return false }
        if incoming.generation > newestGeneration {
            clearLocked()
            newestGeneration = incoming.generation
        }
        guard data.count <= limit - pending.count else { sysClose(incoming.fd); return false }
        if master == nil { master = incoming } else { sysClose(incoming.fd) }
        pending.append(data)
        scheduleLocked()
        return true
    }

    func reset() {
        lock.lock()
        clearLocked()
        lock.unlock()
    }

    private func clearLocked() {
        waiting?.cancel()
        waiting = nil
        waitToken = nil
        pending.removeAll(keepingCapacity: false)
        if let master { sysClose(master.fd) }
        master = nil
    }

    private func scheduleLocked() {
        guard !scheduled, waiting == nil, !pending.isEmpty else { return }
        scheduled = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        guard let master else { return }
        // Bound each turn so admission and close never wait behind a huge paste.
        let count = min(pending.count, 65_536)
        let written = pending.withUnsafeBytes { sysWrite(master.fd, $0.baseAddress, count) }
        if written > 0 {
            pending.removeFirst(written)
            if pending.isEmpty { clearLocked() } else { scheduleLocked() }
        } else if written < 0, errno == EINTR {
            scheduleLocked()
        } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            let fd = sysDup(master.fd)
            guard fd >= 0 else { clearLocked(); return }
            let token = UUID()
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                source.cancel()
                guard let self else { return }
                self.lock.lock()
                if self.waitToken == token {
                    self.waiting = nil
                    self.waitToken = nil
                    self.scheduleLocked()
                }
                self.lock.unlock()
            }
            source.setCancelHandler { sysClose(fd) }
            waiting = source
            waitToken = token
            source.resume()
        } else {
            clearLocked() // the pinned shell has exited
        }
    }

    deinit {
        waiting?.cancel()
        if let master { sysClose(master.fd) }
    }
}
