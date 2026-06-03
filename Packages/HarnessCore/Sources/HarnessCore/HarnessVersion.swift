import Foundation

/// Single source of truth for the Harness version, readable from every process.
///
/// The app can read `Bundle.main` (e.g. `AboutPanelController`), but the daemon is a
/// separate launchd process where `Bundle.main` does not resolve to the app bundle —
/// so anything shared across the daemon/app boundary (the spawned shell's
/// `TERM_PROGRAM_VERSION`, the XTVERSION reply) reads these constants instead.
///
/// Bump these alongside `Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`)
/// in the release runbook.
public enum HarnessVersion {
    /// Marketing version, matches `CFBundleShortVersionString`.
    public static let short = "1.1.2"
    /// Build number, matches `CFBundleVersion`. Used as the secondary-DA firmware field.
    public static let build = 110
}
