import Foundation

/// tmux `wait-for` named channels — a scripting primitive to synchronize across panes/
/// clients. A `wait` blocks until another client `signal`s the channel; `lock`/`unlock`
/// give the channel mutex semantics.
///
/// This type is **pure**: it never touches sockets. `wait`/`lock` register a client's fd
/// and the caller defers the reply; `signal`/`unlock` return the fds whose deferred reply
/// the caller should now send. That keeps the blocking at the socket layer — the daemon's
/// serial queue never blocks, and the `SurfaceRegistry` lock is never involved (the
/// deadlock the project's design forbids). State is confined to the daemon's serial queue,
/// like the rest of `DaemonServer`, so no internal lock is needed.
final class WaitForRegistry {
    private struct Channel {
        var lockHolder: Int32?         // fd currently holding the lock (nil = free)
        var waiters: [Int32] = []      // fds blocked on `wait`
        var lockWaiters: [Int32] = []  // fds blocked on `lock` while held
    }
    private var channels: [String: Channel] = [:]

    /// Hard per-channel ceiling on the number of concurrently blocked `wait` fds. Without
    /// this a malicious or buggy script can park an unbounded number of connections on a
    /// single channel, pinning their reply buffers and exhausting daemon FDs. 1 024 is far
    /// above any realistic scripting workload; at the cap we reject immediately so the
    /// caller's socket unblocks rather than silently accumulating.
    static let maxWaitersPerChannel = 1024

    /// Number of channels currently carrying state. Exposed for diagnostics/tests to assert that
    /// emptied channels are pruned (so the map can't grow without bound).
    var activeChannelCount: Int { channels.count }

    /// `wait-for <channel>`: register the fd; the caller defers its reply until `signal`.
    /// Returns `true` if the fd was registered (reply stays deferred), `false` if the channel
    /// is at the per-channel cap (caller should send an immediate error reply to `fd`).
    @discardableResult
    func wait(channel: String, fd: Int32) -> Bool {
        let current = channels[channel]?.waiters.count ?? 0
        guard current < Self.maxWaitersPerChannel else {
            // At cap: reject immediately so the fd doesn't block indefinitely. The error
            // shape mirrors the registry's .error(_:) response used elsewhere in the IPC path.
            return false
        }
        channels[channel, default: Channel()].waiters.append(fd)
        return true
    }

    /// `wait-for -S <channel>`: wake every `wait`er. Returns their fds (the caller sends each
    /// its deferred reply). A signal with no waiters is a no-op (tmux doesn't latch it).
    func signal(channel: String) -> [Int32] {
        let woken = channels[channel]?.waiters ?? []
        channels[channel]?.waiters.removeAll()
        pruneIfEmpty(channel)
        return woken
    }

    /// `wait-for -L <channel>`: acquire the lock. Returns true if acquired now (reply
    /// immediately), false if the channel is held (fd registered; reply deferred to `unlock`).
    func lock(channel: String, fd: Int32) -> Bool {
        if channels[channel]?.lockHolder != nil {
            channels[channel, default: Channel()].lockWaiters.append(fd)
            return false
        }
        channels[channel, default: Channel()].lockHolder = fd
        return true
    }

    /// `wait-for -U <channel>`: release the lock. If a `lock`er is queued, the channel stays
    /// locked and is granted to it — its fd is returned so the caller sends its deferred reply.
    func unlock(channel: String) -> Int32? {
        guard channels[channel]?.lockHolder != nil else { return nil }
        if let next = channels[channel]?.lockWaiters.first {
            channels[channel]?.lockWaiters.removeFirst()
            channels[channel]?.lockHolder = next
            return next // stays locked, handed to `next`
        }
        channels[channel]?.lockHolder = nil
        pruneIfEmpty(channel)
        return nil
    }

    /// A channel with no holder, no waiters, and no queued lockers carries no state — drop it so a
    /// script that touches many unique channel names can't grow `channels` without bound.
    private func pruneIfEmpty(_ channel: String) {
        guard let c = channels[channel] else { return }
        if c.lockHolder == nil, c.waiters.isEmpty, c.lockWaiters.isEmpty {
            channels[channel] = nil
        }
    }

    /// Drop a disconnected client's fd from every channel (called on socket teardown). If the
    /// client held a lock, release it and hand it to the next queued `lock`er — otherwise a
    /// holder that crashes/detaches would wedge the channel forever, parking every later locker.
    /// Returns the fds newly granted the lock so the caller sends each its deferred reply.
    func remove(fd: Int32) -> [Int32] {
        var granted: [Int32] = []
        for key in channels.keys {
            channels[key]?.waiters.removeAll { $0 == fd }
            channels[key]?.lockWaiters.removeAll { $0 == fd }
            if channels[key]?.lockHolder == fd {
                if let next = channels[key]?.lockWaiters.first {
                    channels[key]?.lockWaiters.removeFirst()
                    channels[key]?.lockHolder = next
                    granted.append(next)
                } else {
                    channels[key]?.lockHolder = nil
                }
            }
        }
        // The departing client may have left channels empty (its wait/lock was the only state) —
        // drop them so a churn of clients × unique channels can't grow the map without bound.
        channels = channels.filter { !($0.value.lockHolder == nil && $0.value.waiters.isEmpty && $0.value.lockWaiters.isEmpty) }
        return granted
    }
}
