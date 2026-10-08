import Foundation
import HarnessCore

extension SurfaceRegistry {
    func searchOutput(query: String, caseSensitive: Bool, sessionID: SessionID?, offset: Int, epoch: String, cancelled: FlagBox) -> IPCResponse {
        guard !query.isEmpty, query.count <= 256, (0...100_000).contains(offset) else { return .error("Search requires 1–256 characters and a valid result offset.") }
        lock.lock()
        let snapshot = editor.snapshot
        let live = sessions
        lock.unlock()
        var results: [OutputSearchMatch] = []
        var visited: Set<SurfaceID> = []
        var skipped = 0
        for workspace in snapshot.workspaces {
            for session in workspace.sessions where sessionID == nil || session.id == sessionID {
                for tab in session.tabs {
                    for leaf in tab.rootPane.allLeaves() {
                        guard !cancelled.read() else { return .error("Search cancelled") }
                        guard visited.insert(leaf.surfaceID).inserted, let pty = live[leaf.surfaceID.uuidString] else { continue }
                        let text = pty.captureGrid(start: nil, end: nil, joinWrapped: false)
                        for (index, line) in text.components(separatedBy: "\n").enumerated() {
                            guard !cancelled.read() else { return .error("Search cancelled") }
                            guard line.range(of: query, options: caseSensitive ? [] : [.caseInsensitive]) != nil else { continue }
                            if skipped < offset { skipped += 1; continue }
                            if results.count == 100 { return searchReply(results, more: true, epoch: epoch, revision: snapshot.revision) }
                            results.append(OutputSearchMatch(workspaceID: workspace.id, sessionID: session.id, sessionName: SessionDisplayName.title(of: session, in: workspace),
                                                             tabID: tab.id, tabTitle: tab.title, paneID: leaf.id, surfaceID: leaf.surfaceID, line: index, text: line))
                        }
                    }
                }
            }
        }
        return searchReply(results, more: false, epoch: epoch, revision: snapshot.revision)
    }

    func validateOutputMatch(_ match: OutputSearchMatch, revision: Int, cancelled: FlagBox) -> IPCResponse {
        lock.lock()
        let snapshot = editor.snapshot
        let pty = sessions[match.surfaceID.uuidString]
        lock.unlock()
        guard snapshot.revision >= revision,
              let workspace = snapshot.workspaces.first(where: { $0.id == match.workspaceID }),
              let session = workspace.sessions.first(where: { $0.id == match.sessionID }),
              let tab = session.tabs.first(where: { $0.id == match.tabID }),
              tab.rootPane.allLeaves().contains(where: { $0.id == match.paneID && $0.surfaceID == match.surfaceID }),
              let pty, !cancelled.read() else { return .error("This pane moved or closed. Search again.") }
        let lines = pty.captureGrid(start: nil, end: nil, joinWrapped: false).components(separatedBy: "\n")
        guard lines.indices.contains(match.line), OutputSearch.fingerprint(lines[match.line]) == match.lineFingerprint else {
            return .error("This output moved or expired. Search again.")
        }
        return .ok
    }

    private func searchReply(_ matches: [OutputSearchMatch], more: Bool, epoch: String, revision: Int) -> IPCResponse {
        do { return .text(String(decoding: try JSONEncoder().encode(OutputSearchPage(matches: matches, hasMore: more, epoch: epoch, revision: revision)), as: UTF8.self)) }
        catch { return .error(error.localizedDescription) }
    }
}
