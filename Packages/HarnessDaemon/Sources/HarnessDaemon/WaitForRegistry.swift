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
        var locked = false
        var waiters: [Int32] = []      // fds blocked on `wait`
        var lockWaiters: [Int32] = []  // fds blocked on `lock` while held
    }
    private var channels: [String: Channel] = [:]

    /// `wait-for <channel>`: register the fd; the caller defers its reply until `signal`.
    func wait(channel: String, fd: Int32) {
        channels[channel, default: Channel()].waiters.append(fd)
    }

    /// `wait-for -S <channel>`: wake every `wait`er. Returns their fds (the caller sends each
    /// its deferred reply). A signal with no waiters is a no-op (tmux doesn't latch it).
    func signal(channel: String) -> [Int32] {
        let woken = channels[channel]?.waiters ?? []
        channels[channel]?.waiters.removeAll()
        return woken
    }

    /// `wait-for -L <channel>`: acquire the lock. Returns true if acquired now (reply
    /// immediately), false if the channel is held (fd registered; reply deferred to `unlock`).
    func lock(channel: String, fd: Int32) -> Bool {
        if channels[channel]?.locked == true {
            channels[channel, default: Channel()].lockWaiters.append(fd)
            return false
        }
        channels[channel, default: Channel()].locked = true
        return true
    }

    /// `wait-for -U <channel>`: release the lock. If a `lock`er is queued, the channel stays
    /// locked and is granted to it — its fd is returned so the caller sends its deferred reply.
    func unlock(channel: String) -> Int32? {
        guard channels[channel]?.locked == true else { return nil }
        if let next = channels[channel]?.lockWaiters.first {
            channels[channel]?.lockWaiters.removeFirst()
            return next // stays locked, handed to `next`
        }
        channels[channel]?.locked = false
        return nil
    }

    /// Drop a disconnected client's fd from every channel (called on socket teardown).
    func remove(fd: Int32) {
        for key in channels.keys {
            channels[key]?.waiters.removeAll { $0 == fd }
            channels[key]?.lockWaiters.removeAll { $0 == fd }
        }
    }
}
