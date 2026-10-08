#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

/// Keystrokes and pastes to one PTY, without ever blocking a thread. The master is
/// non-blocking: a write takes what the PTY accepts, the rest waits in order, and a write
/// source finishes the job when the program drains its input. A pane frozen with Ctrl-S, or
/// a program that stops reading, costs a buffer instead of a parked GCD worker.
///
/// Every write goes to a private dup of the master, taken under the owner's lock: close or
/// respawn can then close the master without the fd number being recycled under a pending
/// write. Input queued for a shell that has since been respawned is dropped.
final class PtyInputWriter: @unchecked Sendable {
    /// Typed input never gets near this; it bounds a giant paste into a frozen pane.
    static let maxPending = 8 * 1024 * 1024

    typealias Master = @Sendable () -> (fd: Int32, generation: UInt64)?

    private let queue: DispatchQueue
    /// The current master (a fresh dup the caller now owns) and its shell generation.
    /// Set with each write; read on the queue.
    private var currentMaster: Master = { nil }
    private var pending = Data()
    private var pendingGeneration: UInt64?
    private var waiting: DispatchSourceWrite?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func write(_ data: Data, master: @escaping Master) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            currentMaster = master
            let room = Self.maxPending - pending.count
            guard room > 0 else { return }
            pending.append(data.prefix(room))
            if waiting == nil { drain() }
        }
    }

    /// Forget queued input (the surface closed). Runs on the writer's queue.
    func reset() {
        queue.async { [self] in
            waiting?.cancel()
            waiting = nil
            pending.removeAll()
        }
    }

    /// Write until the PTY is full or the input is gone. On the writer's queue.
    private func drain() {
        guard !pending.isEmpty, let master = currentMaster() else { return }
        if let generation = pendingGeneration, generation != master.generation {
            // The shell this input was typed into is gone.
            pending.removeAll()
            pendingGeneration = nil
            sysClose(master.fd)
            return
        }
        pendingGeneration = master.generation
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { sysWrite(master.fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                waitForRoom(master.fd)
                return
            }
            pending.removeAll() // the PTY is gone (EIO / EBADF)
            break
        }
        pendingGeneration = nil
        sysClose(master.fd)
    }

    /// Resume when the PTY can take more. The source owns `fd` and closes it when cancelled.
    private func waitForRoom(_ fd: Int32) {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            guard let self else { return }
            self.waiting = nil
            self.drain()
        }
        source.setCancelHandler { sysClose(fd) }
        waiting = source
        source.resume()
    }
}
