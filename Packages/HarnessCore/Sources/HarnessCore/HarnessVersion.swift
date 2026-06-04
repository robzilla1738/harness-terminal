import Foundation

/// Single source of truth for the Harness version, readable from every process.
///
/// The app can read `Bundle.main` (e.g. `AboutPanelController`), but the daemon is a
/// separate launchd process where `Bundle.main` does not resolve to the app bundle —
/// so anything shared across the daemon/app boundary (the spawned shell's
/// `TERM_PROGRAM_VERSION`, the XTVERSION reply) reads these constants instead.
///
/// Bump these alongside `Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`)
/// in the release runbook. `Scripts/package-app.sh` and the release workflow fail the
/// build when the two disagree (v1.3.0/v1.3.1 shipped daemons that reported 1.2.0).
public enum HarnessVersion {
    /// Marketing version, matches `CFBundleShortVersionString`.
    public static let short = "1.3.1"
    /// Build number, matches `CFBundleVersion`. Used as the secondary-DA firmware field
    /// and as the daemon↔app/CLI staleness handshake in `daemonStats`.
    public static let build = 113
}
