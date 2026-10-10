import AppKit
import Sparkle

/// Wraps Sparkle's standard updater. It checks the appcast declared in Info.plist
/// (`SUFeedURL` → thebestterminal.com/appcast.xml) on a schedule and on demand, and verifies every
/// downloaded update against the EdDSA public key (`SUPublicEDKey`) before installing — so a
/// tampered or unsigned build is rejected. The Check-for-Updates menu item targets `controller`.
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    /// Only bundles with a configured feed start background checks. Isolated previews have
    /// no feed and must not interrupt their first-run flow with an unusable updater prompt.
    let controller = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    /// The action the "Check for Updates…" menu item points at (`SPUStandardUpdaterController`
    /// implements `checkForUpdates(_:)`).
    static let checkForUpdatesAction = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
}
