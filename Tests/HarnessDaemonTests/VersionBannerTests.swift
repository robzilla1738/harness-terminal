import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// First-run / what's-new banner: pending-banner policy, version-state persistence, and
/// the registry integration (who gets the injection, exactly once). Integration tests run
/// against an isolated `HARNESS_HOME` like `SurfaceRegistryTests`.
final class VersionBannerTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Policy

    func testDecidePendingMatrix() {
        // Fresh machine: nothing on disk at all.
        XCTAssertEqual(
            VersionBannerStore.decidePending(lastSeenBuild: nil, currentBuild: 121, hadExistingLayout: false),
            .welcome
        )
        // Update from a build that predates the banner: layout exists, no state.
        XCTAssertEqual(
            VersionBannerStore.decidePending(lastSeenBuild: nil, currentBuild: 121, hadExistingLayout: true),
            .whatsNew
        )
        // Normal update.
        XCTAssertEqual(
            VersionBannerStore.decidePending(lastSeenBuild: 120, currentBuild: 121, hadExistingLayout: true),
            .whatsNew
        )
        // Already shown for this build.
        XCTAssertNil(VersionBannerStore.decidePending(lastSeenBuild: 121, currentBuild: 121, hadExistingLayout: true))
        // Downgrade shows nothing.
        XCTAssertNil(VersionBannerStore.decidePending(lastSeenBuild: 122, currentBuild: 121, hadExistingLayout: true))
    }

    // MARK: - Persistence

    func testStoreRoundTripAndCorruptFile() throws {
        let store = VersionBannerStore()
        XCTAssertNil(store.loadLastSeenBuild(), "missing file reads as never-shown")
        store.markSeen(build: 117, version: "1.5.0")
        XCTAssertEqual(store.loadLastSeenBuild(), 117)
        store.markSeen()
        XCTAssertEqual(store.loadLastSeenBuild(), HarnessVersion.build)
        // Corrupt state must read as never-shown, not crash or block the banner forever.
        try Data("{not json".utf8).write(to: HarnessPaths.versionStateURL)
        XCTAssertNil(store.loadLastSeenBuild())
    }

    /// A failed ack must leave the persisted state empty, so a daemon RESTART re-reads
    /// "never shown" and re-banners — the one-shot is gated on a durable ack, never an
    /// in-memory per-run flag. (Same-run no-replay after a failed ack is covered by
    /// `testFailedAckRetriesWithoutReplayingBanner`; this pins the across-restart half.)
    func testFailedAckLeavesBannerPendingForNextLaunch() throws {
        // A directory where the state file belongs makes every atomic write fail.
        try FileManager.default.createDirectory(
            at: HarnessPaths.versionStateURL, withIntermediateDirectories: true
        )
        let store = VersionBannerStore()
        XCTAssertFalse(store.markSeen(), "an unwritable ack must report failure")
        XCTAssertNil(store.loadLastSeenBuild(), "a failed ack must not read back as a recorded build")

        // The next launch re-reads empty state → the banner is still pending either way.
        XCTAssertEqual(
            VersionBannerStore.decidePending(
                lastSeenBuild: store.loadLastSeenBuild(),
                currentBuild: HarnessVersion.build,
                hadExistingLayout: false
            ),
            .welcome
        )
        XCTAssertEqual(
            VersionBannerStore.decidePending(
                lastSeenBuild: store.loadLastSeenBuild(),
                currentBuild: HarnessVersion.build,
                hadExistingLayout: true
            ),
            .whatsNew,
            "a never-acked banner must replay on the next launch"
        )
    }

    // MARK: - Registry integration (spawns real PTYs)

    private func capture(_ registry: SurfaceRegistry, _ surfaceID: String) -> String {
        guard case let .text(text) = registry.handle(.capturePane(surfaceID: surfaceID, includeScrollback: true))
        else { return "" }
        return text
    }

    private func waitForCapture(
        _ registry: SurfaceRegistry,
        surfaceID: String,
        contains needle: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        waitUntil(timeout: timeout) { capture(registry, surfaceID).contains(needle) }
    }

    private func surfaceIDs(_ registry: SurfaceRegistry) -> Set<String> {
        guard case let .surfaces(list) = registry.handle(.listSurfaces) else { return [] }
        return Set(list.map(\.surfaceID))
    }

    func testFreshInstallInjectsWelcomeIntoSeededSurfaceOnce() throws {
        try skipUnlessLiveDaemonTests()
        // No layout.json, no version state → registry seeds the default tab AND welcomes there.
        let registry = SurfaceRegistry(enableVersionBanner: true)
        guard let first = surfaceIDs(registry).first else { return XCTFail("expected a seeded surface") }
        XCTAssertTrue(
            waitForCapture(registry, surfaceID: first, contains: "Try this"),
            "welcome banner missing from the seeded first surface"
        )
        // Consumed + persisted immediately — one-shot across restarts too.
        XCTAssertEqual(VersionBannerStore().loadLastSeenBuild(), HarnessVersion.build)

        // The next tab is banner-free.
        guard let workspaceID = registry.snapshot.workspaces.first?.id else { return XCTFail("no workspace") }
        let before = surfaceIDs(registry)
        _ = registry.handle(.newTab(workspaceID: workspaceID, cwd: nil, shell: nil))
        guard let second = surfaceIDs(registry).subtracting(before).first else {
            return XCTFail("newTab spawned no surface")
        }
        usleep(500_000) // give a hypothetical (buggy) second injection time to land
        XCTAssertFalse(capture(registry, second).contains("Try this"))
    }

    func testUpdateBannersFirstNewTabAndSparesRestoredPanes() throws {
        try skipUnlessLiveDaemonTests()
        // An existing install mid-update: a restorable layout + state from an older build.
        try SessionStore().saveImmediately(SessionSnapshot())
        VersionBannerStore().markSeen(build: HarnessVersion.build - 1, version: "0.0.0")

        let registry = SurfaceRegistry(enableVersionBanner: true)
        guard let restored = surfaceIDs(registry).first else { return XCTFail("expected a restored surface") }
        usleep(500_000)
        XCTAssertFalse(
            capture(registry, restored).contains("Harness updated"),
            "boot restore must never banner existing panes"
        )

        guard let workspaceID = registry.snapshot.workspaces.first?.id else { return XCTFail("no workspace") }
        let before = surfaceIDs(registry)
        _ = registry.handle(.newTab(workspaceID: workspaceID, cwd: nil, shell: nil))
        guard let fresh = surfaceIDs(registry).subtracting(before).first else {
            return XCTFail("newTab spawned no surface")
        }
        XCTAssertTrue(
            waitForCapture(registry, surfaceID: fresh, contains: "Harness updated"),
            "what's-new banner missing from the first fresh surface after an update"
        )
        XCTAssertTrue(capture(registry, fresh).contains(ReleaseNotes.current.version))
        XCTAssertEqual(VersionBannerStore().loadLastSeenBuild(), HarnessVersion.build)
    }

    func testUpdateBannerOptionSuppressesOutputButStillMarksSeen() throws {
        try skipUnlessLiveDaemonTests()
        try SessionStore().saveImmediately(SessionSnapshot())
        VersionBannerStore().markSeen(build: HarnessVersion.build - 1, version: "0.0.0")

        let registry = SurfaceRegistry(enableVersionBanner: true)
        registry.optionStore.set(.bool(false), key: "update-banner")
        guard let workspaceID = registry.snapshot.workspaces.first?.id else { return XCTFail("no workspace") }
        let before = surfaceIDs(registry)
        _ = registry.handle(.newTab(workspaceID: workspaceID, cwd: nil, shell: nil))
        guard let fresh = surfaceIDs(registry).subtracting(before).first else {
            return XCTFail("newTab spawned no surface")
        }
        usleep(500_000)
        XCTAssertFalse(capture(registry, fresh).contains("Harness updated"))
        // Still recorded: turning the option back on must not resurrect an old banner.
        XCTAssertEqual(VersionBannerStore().loadLastSeenBuild(), HarnessVersion.build)
    }

    func testDowngradeReRecordsLowerBuildWithoutBanner() throws {
        try skipUnlessLiveDaemonTests()
        // State from a FUTURE build (downgrade): no banner, but the lower build must be
        // re-stamped so the eventual re-upgrade banners again.
        try SessionStore().saveImmediately(SessionSnapshot())
        VersionBannerStore().markSeen(build: HarnessVersion.build + 1, version: "99.0.0")

        let registry = SurfaceRegistry(enableVersionBanner: true)
        XCTAssertEqual(
            VersionBannerStore().loadLastSeenBuild(), HarnessVersion.build,
            "downgrade must re-record the lower build at init"
        )
        guard let workspaceID = registry.snapshot.workspaces.first?.id else { return XCTFail("no workspace") }
        let before = surfaceIDs(registry)
        _ = registry.handle(.newTab(workspaceID: workspaceID, cwd: nil, shell: nil))
        guard let fresh = surfaceIDs(registry).subtracting(before).first else {
            return XCTFail("newTab spawned no surface")
        }
        usleep(500_000)
        XCTAssertFalse(capture(registry, fresh).contains("Harness updated"), "downgrade shows nothing")
    }

    func testFailedAckRetriesWithoutReplayingBanner() throws {
        try skipUnlessLiveDaemonTests()
        // Block the ack: a DIRECTORY at version-state.json makes the atomic write fail.
        try FileManager.default.createDirectory(
            at: HarnessPaths.versionStateURL, withIntermediateDirectories: true
        )
        let registry = SurfaceRegistry(enableVersionBanner: true) // fresh install → welcome
        guard let first = surfaceIDs(registry).first else { return XCTFail("expected a seeded surface") }
        XCTAssertTrue(waitForCapture(registry, surfaceID: first, contains: "Try this"))
        XCTAssertNil(VersionBannerStore().loadLastSeenBuild(), "ack could not have landed")

        // Unblock and create another surface: the ack retries; the banner must NOT re-render.
        try FileManager.default.removeItem(at: HarnessPaths.versionStateURL)
        guard let workspaceID = registry.snapshot.workspaces.first?.id else { return XCTFail("no workspace") }
        let before = surfaceIDs(registry)
        _ = registry.handle(.newTab(workspaceID: workspaceID, cwd: nil, shell: nil))
        guard let second = surfaceIDs(registry).subtracting(before).first else {
            return XCTFail("newTab spawned no surface")
        }
        usleep(500_000)
        XCTAssertFalse(capture(registry, second).contains("Try this"), "banner renders at most once per run")
        XCTAssertEqual(
            VersionBannerStore().loadLastSeenBuild(), HarnessVersion.build,
            "failed ack must be retried on the next surface"
        )
    }

    func testDisabledRegistryNeverBanners() throws {
        try skipUnlessLiveDaemonTests()
        let registry = SurfaceRegistry() // default: banner disabled (every embedded/test registry)
        guard let first = surfaceIDs(registry).first else { return XCTFail("expected a seeded surface") }
        usleep(500_000)
        XCTAssertFalse(capture(registry, first).contains("Try this"))
        XCTAssertNil(VersionBannerStore().loadLastSeenBuild())
    }
}
