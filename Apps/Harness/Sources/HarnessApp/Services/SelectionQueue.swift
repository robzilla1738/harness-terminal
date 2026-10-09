import Foundation
import HarnessCore

/// Selections (session, workspace, pane focus) sent to one daemon off the main thread, in
/// order. Latest wins per kind: a selection still waiting is dropped when one of its kind is
/// queued after it, so quick clicks never stack round trips ahead of the next command, and the
/// ones left go out in the order they were asked for (a session before its workspace).
final class SelectionQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.robert.harness.selections", qos: .userInitiated)
    private let send: @Sendable (IPCRequest) -> Void
    private let lock = NSLock()
    /// The ticket of the latest selection queued per kind (guarded by `lock`).
    private var latest: [String: Int] = [:]
    private var tickets = 0
    private var epoch = 0

    init(send: @escaping @Sendable (IPCRequest) -> Void) {
        self.send = send
    }

    func async(_ request: IPCRequest) {
        let kind = Self.kind(of: request)
        let (ticket, batch) = lock.withLock {
            tickets += 1
            if let kind { latest[kind] = tickets }
            return (tickets, epoch)
        }
        queue.async { [self] in
            guard lock.withLock({ batch != epoch || (kind.map { latest[$0] == ticket } ?? true) }) else { return }
            send(request)
        }
    }

    func perform(_ body: @escaping @Sendable () -> Void) {
        lock.withLock {
            epoch += 1 // A command is an ordering barrier for earlier selections.
            latest.removeAll(keepingCapacity: true)
            queue.async(execute: body)
        }
    }

    /// Run `body` once the selections already queued have gone out, so a fetch or command sees
    /// (and acts on) the session in front.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    /// Selections of one kind replace each other; anything else always goes out.
    private static func kind(of request: IPCRequest) -> String? {
        switch request {
        case .selectSession: "session"
        case .selectWorkspace: "workspace"
        case .selectPane: "pane"
        default: nil
        }
    }
}
