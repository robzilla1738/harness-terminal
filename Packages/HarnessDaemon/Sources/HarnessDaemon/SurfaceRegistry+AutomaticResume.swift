import Foundation
import HarnessCore

extension SurfaceRegistry {
    /// Only newly created startup shells qualify. Candidate-daemon adoption retains
    /// createdShell=false, so replacement never re-runs a provider command.
    func scheduleAutomaticRestores() {
        lock.lock()
        let leaves = editor.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allLeaves() }
        let targets = leaves.compactMap { leaf -> (SessionPty, UUID)? in
            guard leaf.resumeAutomatically == true, let runID = leaf.lastAgentRunID,
                  let pty = sessions[leaf.surfaceID.uuidString], pty.createdShell,
                  automaticResumeStarted.insert(pty.streamIdentity ?? pty.id).inserted else { return nil }
            return (pty, runID)
        }
        lock.unlock()
        for (pty, runID) in targets {
            guard automaticResumeSlots.wait(timeout: .now()) == .success else {
                publishObserverFailure("Automatic resume reached its 128-pane pending restore budget. Remaining panes require manual Resume; no command was submitted.")
                continue
            }
            automaticResumeQueue.addOperation { [weak self, weak pty] in
                guard let self else { return }; defer { self.automaticResumeSlots.signal() }
                guard let pty else { return }
                do {
                    guard let run = try self.activity.store.run(runID), run.hostID == self.activity.hostID else { throw ResumeError.unavailable }
                    let command = try AgentResume.command(for: run); try AgentResume.validateFiles(for: run)
                    let deadline = Date().addingTimeInterval(20)
                    while Date() < deadline {
                        self.lock.lock()
                        let leaf = self.editor.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allLeaves() }.first { $0.surfaceID.uuidString == pty.id }
                        let permitted = !self.quiesced && self.sessions[pty.id] === pty && leaf?.resumeAutomatically == true && leaf?.lastAgentRunID == runID
                        self.lock.unlock()
                        guard permitted else { return }
                        let state = try pty.liveState()
                        if let identity = state.freshShellIdentity {
                            self.lock.lock()
                            guard !self.quiesced, self.sessions[pty.id] === pty else { self.lock.unlock(); return }
                            self.hostedMutations.enter(); self.lock.unlock()
                            defer { self.hostedMutations.leave() }
                            if let local = pty.local { try local.insertResume(command, expectedIdentity: identity, submit: true) }
                            else { _ = try pty.query(.automaticResume(pty.id, command, identity)) }
                            return
                        }
                        // No retry follows an attempted submission. Polling only waits for
                        // shell integration's first untouched prompt before submitting once.
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                    throw ResumeError.shellChanged
                } catch {
                    self.publishObserverFailure("Automatic resume did not complete for pane " + pty.id + ": " + error.localizedDescription + " Use manual Resume after inspecting the pane; uncertain input was not retried.")
                }
            }
        }
    }
}
