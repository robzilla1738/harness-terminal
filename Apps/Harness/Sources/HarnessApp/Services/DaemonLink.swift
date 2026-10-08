import Foundation
import HarnessCore

/// A daemon the app stays attached to while another one is active: a remote host whose
/// windows are behind, or this Mac while a remote window is in front. It keeps that
/// daemon's snapshot current from its revision pushes, so its windows and sidebar rows stay
/// live. Commands always go to the active daemon (the key window's); a window on a linked
/// daemon makes its daemon active when it comes to the front.
@MainActor
final class DaemonLink {
    /// `DaemonSidebar.localID` or the remote host's name.
    let owner: String
    private(set) var endpoint: Endpoint
    private(set) var snapshot: SessionSnapshot
    /// Called on the main actor after the snapshot changes.
    var onChange: ((DaemonLink) -> Void)?
    /// A client directive from this daemon (a CLI `copy-mode` aimed at one of its panes).
    var onDirective: ((ClientDirective) -> Void)?

    private var service: DaemonSessionService
    private var subscription: DaemonSubscription?
    private var generation = 0
    private var retryDelay: TimeInterval = 1
    private var fetching = false
    /// A push (or a reconnect) arrived mid-fetch: fetch again when this one lands.
    private var refetch = false

    init(owner: String, endpoint: Endpoint, snapshot: SessionSnapshot) {
        self.owner = owner
        self.endpoint = endpoint
        self.snapshot = snapshot
        service = DaemonSessionService(endpoint: endpoint)
    }

    /// Follow the daemon's pushes, at `endpoint` when a reconnect moved it.
    func start(endpoint: Endpoint? = nil) {
        if let endpoint, endpoint != self.endpoint {
            self.endpoint = endpoint
            service = DaemonSessionService(endpoint: endpoint)
        }
        generation += 1
        let generation = generation
        subscription?.cancel()
        subscription = try? service.subscribeSnapshot(
            label: "harness-app",
            onRevision: { [weak self] revision in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.generation, revision != self.snapshot.revision else { return }
                        self.refresh()
                    }
                }
            },
            onDirective: { [weak self] directive in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.generation else { return }
                        self.onDirective?(directive)
                    }
                }
            },
            onEnd: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.generation else { return }
                        self.subscription = nil
                        self.scheduleRetry()
                    }
                }
            }
        )
        if subscription == nil {
            scheduleRetry()
        } else {
            retryDelay = 1
            refresh()
        }
    }

    func stop() {
        generation += 1
        subscription?.cancel()
        subscription = nil
    }

    /// Fetch the snapshot off the main thread (a remote daemon answers over SSH).
    private func refresh() {
        guard !fetching else {
            refetch = true
            return
        }
        fetching = true
        refetch = false
        let service = service
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = try? service.fetchSnapshot()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetching = false
                    let current = generation == self.generation
                    if current, let fresh, fresh != self.snapshot {
                        self.snapshot = fresh
                        self.onChange?(self)
                    }
                    // A stale answer (from before a reconnect) or a push that landed meanwhile.
                    if self.refetch || !current, self.subscription != nil { self.refresh() }
                }
            }
        }
    }

    /// A dropped push channel retries with backoff; a dead tunnel is the coordinator's to revive.
    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(delay * 2, 8)
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation, self.subscription == nil else { return }
                self.start()
            }
        }
    }
}
