import Foundation
import HarnessCore

extension SurfaceRegistry {
    func buildAISummaryInput(workspaceID: UUID?, from: Date, to: Date, categories: Set<SummaryContentCategory>) throws -> AISummaryInput {
        lock.lock()
        let workspace = workspaceID.flatMap { id in editor.snapshot.workspaces.first { $0.id == id } }
        let unavailableWorkspace = workspaceID != nil && workspace == nil
        let leaves = (workspace.map { [$0] } ?? editor.snapshot.workspaces).flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allLeaves() }.filter { $0.content?.isTerminal != false }
        let ids = Set(leaves.map { $0.surfaceID.uuidString })
        let permitted = ids.filter { resolvedPersistScrollback(forSurfaceKey: $0) }
        lock.unlock()
        guard !unavailableWorkspace else { throw AISummaryError.unavailable("The selected workspace no longer exists.") }
        guard ids.count <= 64 else { throw AISummaryError.configuration("Select a workspace with at most 64 terminal surfaces for this bounded summary.") }
        let scopes: [String?] = workspaceID == nil ? [nil] : ids.sorted().map(Optional.some)
        var digests: [ActivityDigest] = [], directories: [String] = [], excerpts: [String] = []
        let usage = try usage.summary(from: from, to: to)
        for surface in scopes {
            let (totals, events, truncated) = try activity.store.digestEvents(from: from, to: to, surfaceID: surface)
            var digest = ActivityDigest(hostID: activity.hostID, from: from, to: to, totals: totals, timeline: events, timelineTruncated: truncated, usage: usage, historyUnavailable: activity.unavailable())
            digest.tests = try activity.store.testSummary(from: from, to: to, surfaceID: surface); digests.append(digest)
        }
        if categories.contains(.repositoryDetails) {
            for id in permitted {
                let page = try activity.store.list(surfaceID: id, offset: 0, limit: 500)
                directories += page.runs.compactMap { $0.repository?.commonDirectory ?? $0.directory }
            }
        }
        if categories.contains(.transcriptExcerpts) {
            for id in permitted.sorted().prefix(4) {
                if let output = try? readCommandOutput(surfaceID: id, maximum: 2048), !output.evicted { excerpts.append(output.text) }
            }
        }
        let input = try AISummaryInputBuilder.build(digests: digests, surfaceIDs: Array(ids), categories: categories, repositoryDetails: directories, excerpts: excerpts)
        // Check policy once more after reading; an opt-out during input construction
        // refuses the submission instead of sending a stale captured-text snapshot.
        lock.lock(); let changed = permitted.contains { !resolvedPersistScrollback(forSurfaceKey: $0) }; lock.unlock()
        guard !changed else { throw AISummaryError.unavailable("Persistence changed while preparing the digest. Review the current content before generating again.") }
        return input
    }
}
