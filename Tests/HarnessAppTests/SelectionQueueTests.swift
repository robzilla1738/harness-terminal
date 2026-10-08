import Foundation
import HarnessCore
import XCTest
@testable import HarnessApp

/// `SelectionQueue`: selections still waiting give way to newer ones of their kind, the rest
/// go out in the order they were asked for once everything queued before them has.
final class SelectionQueueTests: XCTestCase {
    /// Records what went out; the first send blocks until `release`, so later ones wait behind it.
    private final class Daemon: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var blocked = false
        private var log: [String] = []

        var sent: [String] { lock.withLock { log } }

        func send(_ request: IPCRequest) {
            let first = lock.withLock {
                log.append("\(request)")
                defer { blocked = true }
                return !blocked
            }
            if first { gate.wait() }
        }

        func release() { gate.signal() }
    }

    private let workspace = UUID(), otherWorkspace = UUID()
    private let tab = UUID(), paneA = UUID(), paneB = UUID(), paneC = UUID()
    private let sessionA = UUID(), sessionB = UUID()

    func testWaitingSelectionsGiveWayToNewerOnesOfTheirKind() {
        let daemon = Daemon()
        let queue = SelectionQueue(send: daemon.send)
        queue.async(.ping) // in flight: everything after it waits
        queue.async(.selectPane(tabID: tab, paneID: paneA))
        queue.async(.selectPane(tabID: tab, paneID: paneB))
        queue.async(.selectSession(workspaceID: workspace, sessionID: sessionA))
        queue.async(.selectWorkspace(id: workspace))
        queue.async(.selectSession(workspaceID: otherWorkspace, sessionID: sessionB))
        queue.async(.selectWorkspace(id: otherWorkspace))
        queue.async(.selectPane(tabID: tab, paneID: paneC))
        daemon.release()
        queue.sync {}
        XCTAssertEqual(daemon.sent, [
            "ping",
            "\(IPCRequest.selectSession(workspaceID: otherWorkspace, sessionID: sessionB))",
            "\(IPCRequest.selectWorkspace(id: otherWorkspace))",
            "\(IPCRequest.selectPane(tabID: tab, paneID: paneC))",
        ])
    }

    func testOtherRequestsAlwaysGoOut() {
        let daemon = Daemon()
        let queue = SelectionQueue(send: daemon.send)
        queue.async(.ping)
        queue.async(.selectWorkspaceByName(name: "a"))
        queue.async(.selectWorkspaceByName(name: "b"))
        daemon.release()
        queue.sync {}
        XCTAssertEqual(daemon.sent, ["ping", #"selectWorkspaceByName(name: "a")"#, #"selectWorkspaceByName(name: "b")"#])
    }

    func testASelectionAlreadySentIsNotReplaced() {
        let daemon = Daemon()
        daemon.release()
        let queue = SelectionQueue(send: daemon.send)
        queue.async(.selectPane(tabID: tab, paneID: paneA))
        queue.sync {}
        queue.async(.selectPane(tabID: tab, paneID: paneB))
        queue.sync {}
        XCTAssertEqual(daemon.sent, [
            "\(IPCRequest.selectPane(tabID: tab, paneID: paneA))",
            "\(IPCRequest.selectPane(tabID: tab, paneID: paneB))",
        ])
    }
}
