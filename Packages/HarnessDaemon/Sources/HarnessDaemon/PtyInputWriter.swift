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
    private struct Barrier { var remaining: Int; var apply: @Sendable () -> Void; var cancel: @Sendable () -> Void }
    private var barriers: [Barrier] = []
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

    /// Control records share the input order. Later writes cannot cross a resize
    /// boundary, even when a large paste is waiting for the PTY to become writable.
    func perform(afterInput incoming: (fd: Int32, generation: UInt64), apply: @escaping @Sendable () -> Void, cancel: @escaping @Sendable () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard incoming.generation >= newestGeneration else { sysClose(incoming.fd); return false }
        if incoming.generation > newestGeneration { clearLocked(); newestGeneration = incoming.generation }
        guard barriers.count < 64 else { sysClose(incoming.fd); return false }
        if master == nil { master = incoming } else { sysClose(incoming.fd) }
        barriers.append(Barrier(remaining: pending.count, apply: apply, cancel: cancel))
        scheduleLocked(); return true
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
        let cancelled = barriers; barriers.removeAll()
        if !cancelled.isEmpty { queue.async { for barrier in cancelled { barrier.cancel() } } }
        if let master { sysClose(master.fd) }
        master = nil
    }

    private func scheduleLocked() {
        guard !scheduled, waiting == nil, (!pending.isEmpty || !barriers.isEmpty) else { return }
        scheduled = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        lock.lock()
        scheduled = false
        if barriers.first?.remaining == 0 {
            let control = barriers.removeFirst()
            scheduled = true
            lock.unlock()
            control.apply()
            lock.lock(); scheduled = false
            if pending.isEmpty, barriers.isEmpty { clearLocked() } else { scheduleLocked() }
            lock.unlock(); return
        }
        defer { lock.unlock() }
        guard let master else { return }
        // Bound each turn so admission and close never wait behind a huge paste.
        let count = min(pending.count, 65_536, barriers.first?.remaining ?? Int.max)
        let written = pending.withUnsafeBytes { sysWrite(master.fd, $0.baseAddress, count) }
        if written > 0 {
            pending.removeFirst(written)
            for index in barriers.indices { barriers[index].remaining -= written }
            if pending.isEmpty, barriers.isEmpty { clearLocked() } else { scheduleLocked() }
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
