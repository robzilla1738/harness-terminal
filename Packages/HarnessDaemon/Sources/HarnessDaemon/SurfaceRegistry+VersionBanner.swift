import Foundation
import HarnessCore

/// The first-run / what's-new banner one-shot. Mechanically extracted from
/// `SurfaceRegistry.swift` (PR-31): same member, zero logic change. The pending state
/// (`pendingVersionBanner`/`versionBannerStore`/`versionAckRetryNeeded`) stays on the
/// class; both call sites (init's first-install seed, `createOrEnsureSurface`'s
/// freshly-created path) run under the registry lock, exactly as before.
extension SurfaceRegistry {
    /// Consume the pending one-shot banner: render at the surface's spawn width and write
    /// it into the surface's output stream (scrollback + fan-out, like real shell output).
    /// The `update-banner` option (default on) suppresses the output; either way the state
    /// file records the current build immediately, so the banner never repeats — not on
    /// later surfaces, and not after a daemon restart. The on-screen render stays
    /// at-most-once per run regardless; only the durable ack is retried on failure.
    func injectVersionBannerIfPending(into session: RealPty, columns: Int) {
        if versionAckRetryNeeded { versionAckRetryNeeded = !versionBannerStore.markSeen() }
        guard let banner = pendingVersionBanner else { return }
        pendingVersionBanner = nil
        // Ack BEFORE the option check: suppressing the banner still consumes the one-shot.
        versionAckRetryNeeded = !versionBannerStore.markSeen()
        guard optionStore.get("update-banner")?.boolValue ?? true else { return }
        let bytes: Data
        switch banner {
        case .welcome:
            bytes = TerminalBanner.welcome(version: HarnessVersion.short, columns: columns)
        case .whatsNew:
            bytes = TerminalBanner.whatsNew(ReleaseNotes.current, columns: columns)
        }
        session.injectSyntheticOutput(bytes)
    }
}
