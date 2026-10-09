import Foundation
import HarnessCore
import HarnessTerminalEngine

/// Pagination retains only a position and revision signatures, never whole captured histories.
struct OutputSearchCursor {
    var query: String
    var caseSensitive: Bool
    var sessionID: SessionID?
    var revision: Int
    var outputRevisions: [String: String]
    var pane = 0
    var line = 0
    var offset = 0
    var usedAt = Date()
}

extension SurfaceRegistry {
    func searchOutput(query: String, caseSensitive: Bool, sessionID: SessionID?, offset: Int,
                      epoch: String, cancelled: FlagBox, generation: String? = nil) -> IPCResponse {
        guard !query.isEmpty, query.count <= 256, (0...100_000).contains(offset) else {
            return .error("Search requires 1–256 characters and a valid result offset.")
        }
        lock.lock()
        let snapshot = editor.snapshot, live = sessions
        lock.unlock()
        var visited = Set<SurfaceID>()
        let targets = snapshot.workspaces.flatMap { workspace in
            workspace.sessions.filter { sessionID == nil || $0.id == sessionID }.flatMap { session in
                session.tabs.flatMap { tab in
                    tab.rootPane.allLeaves().compactMap { leaf -> (Workspace, SessionGroup, Tab, PaneLeaf, RealPty)? in
                        guard visited.insert(leaf.surfaceID).inserted, let pty = live[leaf.surfaceID.uuidString] else { return nil }
                        return (workspace, session, tab, leaf, pty)
                    }
                }
            }
        }
        let revisions = Dictionary(uniqueKeysWithValues: targets.map { ($0.4.id, $0.4.searchRevision) })
        let token = generation ?? UUID().uuidString
        var cursor = OutputSearchCursor(query: query, caseSensitive: caseSensitive, sessionID: sessionID,
                                        revision: snapshot.revision, outputRevisions: revisions)
        if let generation {
            outputSearchLock.lock()
            let stored = outputSearchCursors.removeValue(forKey: generation)
            outputSearchLock.unlock()
            guard let stored, Date().timeIntervalSince(stored.usedAt) < 60,
                  stored.query == query, stored.caseSensitive == caseSensitive, stored.sessionID == sessionID,
                  stored.offset == offset, stored.revision == snapshot.revision, stored.outputRevisions == revisions else {
                return .error("Search results expired because output or the session layout changed. Search again.")
            }
            cursor = stored
        }
        var results: [OutputSearchMatch] = []
        var skipped = generation == nil ? 0 : offset
        let needle = query.precomposedStringWithCanonicalMapping
        while cursor.pane < targets.count {
            if cancelled.read() { return .error("Search cancelled") }
            let (workspace, session, tab, leaf, pty) = targets[cursor.pane]
            guard let text = pty.searchSnapshot() else { cursor.pane += 1; cursor.line = 0; continue }
            while cursor.line < text.lineCount {
                if cancelled.read() { return .error("Search cancelled") }
                let index = cursor.line
                let logical = text.logicalText(startingAt: index)
                let line = String(logical.text.text.reversed().drop(while: { $0 == " " }).reversed())
                if line.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive]) != nil {
                    if skipped < offset { skipped += 1 }
                    else if results.count == 100 {
                        cursor.offset = offset + results.count
                        cursor.usedAt = Date()
                        outputSearchLock.lock()
                        outputSearchCursors = outputSearchCursors.filter { Date().timeIntervalSince($0.value.usedAt) < 60 }
                        if outputSearchCursors.count >= 32, let oldest = outputSearchCursors.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                            outputSearchCursors.removeValue(forKey: oldest)
                        }
                        outputSearchCursors[token] = cursor
                        outputSearchLock.unlock()
                        return searchReply(results, more: true, epoch: epoch, revision: snapshot.revision, generation: token)
                    } else {
                        results.append(OutputSearchMatch(workspaceID: workspace.id, sessionID: session.id,
                            sessionName: SessionDisplayName.title(of: session, in: workspace), tabID: tab.id,
                            tabTitle: tab.title, paneID: leaf.id, surfaceID: leaf.surfaceID, line: index, text: line))
                    }
                }
                cursor.line = logical.nextLine
            }
            cursor.pane += 1
            cursor.line = 0
        }
        return searchReply(results, more: false, epoch: epoch, revision: snapshot.revision, generation: token)
    }

    func validateOutputMatch(_ match: OutputSearchMatch, revision: Int, cancelled: FlagBox) -> IPCResponse {
        lock.lock()
        let snapshot = editor.snapshot, pty = sessions[match.surfaceID.uuidString]
        lock.unlock()
        guard snapshot.revision >= revision,
              let workspace = snapshot.workspaces.first(where: { $0.id == match.workspaceID }),
              let session = workspace.sessions.first(where: { $0.id == match.sessionID }),
              let tab = session.tabs.first(where: { $0.id == match.tabID }),
              tab.rootPane.allLeaves().contains(where: { $0.id == match.paneID && $0.surfaceID == match.surfaceID }),
              let pty, !cancelled.read(), let text = pty.searchSnapshot(),
              (0..<text.lineCount).contains(match.line) else { return .error("This pane moved or closed. Search again.") }
        let mapped = text.logicalText(startingAt: match.line).text
        guard OutputSearch.fingerprint(mapped.text) == match.lineFingerprint else {
            return .error("This output moved or expired. Search again.")
        }
        return .ok
    }

    private func searchReply(_ matches: [OutputSearchMatch], more: Bool, epoch: String, revision: Int, generation: String) -> IPCResponse {
        do {
            return .text(String(decoding: try JSONEncoder().encode(OutputSearchPage(matches: matches,
                hasMore: more, epoch: epoch, revision: revision, generation: generation)), as: UTF8.self))
        } catch { return .error(error.localizedDescription) }
    }
}
