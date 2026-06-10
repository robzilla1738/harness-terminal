import AppKit
import Foundation
import HarnessCore

/// Event-driven git-branch labels: one `FileWatcher` on the resolved `HEAD` file per unique
/// repository (worktrees resolve to distinct `HEAD`s), shared by every tab inside that
/// repository — replacing the old 2 s poll that spawned `git rev-parse` per tab per tick.
///
/// All state is main-actor. File I/O (repository resolution + `HEAD` reads) runs on a
/// background queue so a wedged filesystem can never stall the main thread; results hop
/// back to main and are reconciled against the *current* tab set, so a stale completion
/// (tab closed / cwd moved mid-read) is harmless — the next `update` self-heals.
///
/// Dedup contract: `onBranchChange` fires only when a read branch differs from the value
/// the daemon's snapshot already carries (and from anything this monitor already sent and
/// is still round-tripping), so a steady-state reconcile produces **zero** IPC.
@MainActor
final class GitBranchMonitor {
    /// One tab as the monitor needs it: identity, where it lives, and the branch the
    /// daemon's snapshot currently shows (the dedup baseline for pushes).
    struct TabRecord {
        var workspaceID: WorkspaceID
        var tabID: TabID
        var cwd: String
        var snapshotBranch: String?
    }

    /// Wrapper so dictionaries can cache "checked: no value" without the `[Key: Value?]`
    /// assign-nil-removes-the-key trap.
    private struct Cached<Value> {
        var value: Value
    }

    /// Fired when a tab's branch is known to differ from the daemon's snapshot value.
    /// A `nil` branch clears the label (the tab's directory is not in a repository).
    var onBranchChange: ((WorkspaceID, TabID, String?) -> Void)?

    private var tabs: [TabID: TabRecord] = [:]
    /// cwd → resolved repository (`value == nil`: checked, not in a repository — the
    /// negative cache). Pruned to live cwds on every reconcile; negative entries are
    /// additionally dropped when a tab is first seen in — or moves into — the directory
    /// (it may have just been `git init`-ed) and wholesale on `refreshAll` (app re-activate).
    private var repoByCwd: [String: Cached<GitHEADReader.Repository?>] = [:]
    /// Resolved-`HEAD` path → live watcher.
    private var watchers: [String: FileWatcher] = [:]
    /// Resolved-`HEAD` path → last branch read from disk.
    private var branchByHead: [String: Cached<String?>] = [:]
    /// Branch most recently *sent* per tab, suppressing duplicate IPC while the daemon's
    /// snapshot still carries the older value (push round-trip in flight). Cleared once the
    /// snapshot catches up.
    private var lastSent: [TabID: Cached<String?>] = [:]
    private var resolvesInFlight: Set<String> = []
    /// cwds whose cache was invalidated while a resolve was already mid-flight (a `git
    /// init` racing the I/O queue): the in-flight result is stale by definition, so the
    /// completion re-resolves instead of caching it. Mirror of `rereadRequested`.
    private var reresolveRequested: Set<String> = []
    private var readsInFlight: Set<String> = []
    /// `HEAD` paths whose watcher fired while a read was already in flight — re-read on
    /// completion so the final state on disk always wins.
    private var rereadRequested: Set<String> = []
    private var paused = false
    /// Serial background lane for all file I/O; results hop to main.
    private let ioQueue = DispatchQueue(label: "com.robert.harness.git-branch-monitor", qos: .utility)

    /// Reconcile against the latest snapshot's tab set (called on every daemon sync).
    /// Cheap when nothing moved: dictionary diffs only, no file I/O.
    func update(tabs newTabs: [TabRecord]) {
        var next: [TabID: TabRecord] = [:]
        for record in newTabs {
            // A tab first seen in — or moved into — a directory previously cached as "not
            // a repository" re-checks it: the user may have just created the repo and
            // cd-ed in. (`tabs[record.tabID]` nil ⇒ new tab ⇒ the `!=` holds.)
            if tabs[record.tabID]?.cwd != record.cwd,
               let cached = repoByCwd[record.cwd], cached.value == nil {
                repoByCwd.removeValue(forKey: record.cwd)
            }
            next[record.tabID] = record
        }
        tabs = next

        // Drop duplicate-suppression entries once the snapshot caught up (or the tab is gone).
        for (tabID, sent) in lastSent {
            guard let record = next[tabID] else {
                lastSent.removeValue(forKey: tabID)
                continue
            }
            if record.snapshotBranch == sent.value {
                lastSent.removeValue(forKey: tabID)
            }
        }

        pruneCaches()
        guard !paused else { return }
        for record in tabs.values { evaluate(record) }
    }

    /// Stop watching while the app is inactive — branch flips made while away are picked
    /// up by `resume()`'s full refresh.
    func pause() {
        paused = true
        watchers.removeAll()
    }

    func resume() {
        paused = false
        refreshAll()
    }

    /// Forget everything learned from disk and re-resolve/re-read every tab. Used on app
    /// re-activate, where any number of external `git` operations may have happened.
    func refreshAll() {
        guard !paused else { return }
        repoByCwd.removeAll()
        branchByHead.removeAll()
        watchers.removeAll()
        rereadRequested.removeAll()
        // Also forget what we *sent*: if the IPC behind a send failed, the snapshot never
        // echoes it back and the suppression would wedge that label forever — re-activate
        // is the self-heal point, so re-send is the safe direction.
        lastSent.removeAll()
        for record in tabs.values { evaluate(record) }
    }

    /// Drop cache/watcher entries no live tab references, so a long session can't
    /// accumulate state for every directory it ever visited.
    private func pruneCaches() {
        let liveCwds = Set(tabs.values.map(\.cwd))
        let staleCwds = repoByCwd.keys.filter { !liveCwds.contains($0) }
        for cwd in staleCwds { repoByCwd.removeValue(forKey: cwd) }
        reresolveRequested.formIntersection(liveCwds)
        let liveHeads = Set(repoByCwd.values.compactMap { $0.value?.headFileURL.path })
        let staleHeads = watchers.keys.filter { !liveHeads.contains($0) }
        for head in staleHeads {
            watchers.removeValue(forKey: head)
            branchByHead.removeValue(forKey: head)
            rereadRequested.remove(head)
        }
    }

    /// Drive one tab toward a consistent state: resolve its repository if unknown, ensure
    /// the repository's `HEAD` is watched and read, and push a differing branch.
    private func evaluate(_ record: TabRecord) {
        guard let cached = repoByCwd[record.cwd] else {
            scheduleResolve(cwd: record.cwd)
            return
        }
        guard let repository = cached.value else {
            // Known non-repository: clear a stale label if the snapshot still shows one.
            send(branch: nil, for: record)
            return
        }
        ensureWatcher(for: repository)
        if let read = branchByHead[repository.headFileURL.path] {
            send(branch: read.value, for: record)
        } else {
            scheduleBranchRead(repository)
        }
    }

    private func scheduleResolve(cwd: String) {
        guard resolvesInFlight.insert(cwd).inserted else {
            // A resolve for this cwd is mid-flight against possibly-stale disk state (the
            // negative-cache invalidation lands here when a `git init` raced the I/O
            // queue). Have the completion re-run rather than trust — and cache — a result
            // read before the world changed.
            reresolveRequested.insert(cwd)
            return
        }
        ioQueue.async { [weak self] in
            let repository = GitHEADReader.resolveRepository(startingAt: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolvesInFlight.remove(cwd)
                    guard !self.paused else { return }
                    if self.reresolveRequested.remove(cwd) != nil {
                        // Invalidated mid-flight — this result may predate the change.
                        self.scheduleResolve(cwd: cwd)
                        return
                    }
                    // Only cache while a live tab still cares; otherwise the entry would
                    // sit until the next prune with nothing to invalidate it.
                    guard self.tabs.values.contains(where: { $0.cwd == cwd }) else { return }
                    self.repoByCwd[cwd] = Cached(value: repository)
                    for record in self.tabs.values where record.cwd == cwd {
                        self.evaluate(record)
                    }
                }
            }
        }
    }

    private func ensureWatcher(for repository: GitHEADReader.Repository) {
        let headPath = repository.headFileURL.path
        guard watchers[headPath] == nil else { return }
        // FileWatcher survives git's lockfile+rename update style (re-arms on rename) and
        // delivers debounced on the main queue, so `assumeIsolated` is hop-free and safe.
        watchers[headPath] = FileWatcher(url: repository.headFileURL) { [weak self] in
            MainActor.assumeIsolated {
                self?.headChanged(repository)
            }
        }
    }

    private func headChanged(_ repository: GitHEADReader.Repository) {
        guard !paused else { return }
        let headPath = repository.headFileURL.path
        // The watcher outliving its prune window (event already queued) must not
        // resurrect cache entries for a repository no tab is in anymore.
        guard watchers[headPath] != nil else { return }
        if readsInFlight.contains(headPath) {
            rereadRequested.insert(headPath)
            return
        }
        scheduleBranchRead(repository)
    }

    private func scheduleBranchRead(_ repository: GitHEADReader.Repository) {
        let headPath = repository.headFileURL.path
        guard readsInFlight.insert(headPath).inserted else { return }
        let url = repository.headFileURL
        ioQueue.async { [weak self] in
            let branch = GitHEADReader.readBranch(headFileURL: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readsInFlight.remove(headPath)
                    guard !self.paused else { return }
                    if self.rereadRequested.remove(headPath) != nil {
                        // HEAD moved again mid-read — this result may be stale; read once more
                        // and let that final read populate the cache.
                        self.scheduleBranchRead(repository)
                        return
                    }
                    self.branchByHead[headPath] = Cached(value: branch)
                    for record in self.tabs.values {
                        guard let cached = self.repoByCwd[record.cwd],
                              cached.value?.headFileURL.path == headPath else { continue }
                        self.send(branch: branch, for: record)
                    }
                }
            }
        }
    }

    /// Push `branch` for the tab iff it differs from what the daemon already shows (or from
    /// what we already sent and is still round-tripping) — the zero-IPC-at-steady-state gate.
    private func send(branch: String?, for record: TabRecord) {
        let baseline: String?
        if let sent = lastSent[record.tabID] {
            baseline = sent.value
        } else {
            baseline = record.snapshotBranch
        }
        guard branch != baseline else { return }
        lastSent[record.tabID] = Cached(value: branch)
        onBranchChange?(record.workspaceID, record.tabID, branch)
    }
}
