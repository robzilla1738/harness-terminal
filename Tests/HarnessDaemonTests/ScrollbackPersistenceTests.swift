import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// End-to-end persistence: a real `forkpty` shell writes output, the surface persists its
/// scrollback to disk, and a *fresh* `RealPty` over the same file replays that history — the
/// "daemon restart isn't a blank session" path. Live (spawns a shell), so gated like the other
/// PTY tests behind `HARNESS_LIVE_DAEMON_TESTS=1`.
final class ScrollbackPersistenceTests: XCTestCase {
    private var scrollbackURL: URL!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        scrollbackURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-scroll-\(UUID().uuidString).scroll")
    }

    override func tearDownWithError() throws {
        if let scrollbackURL { try? FileManager.default.removeItem(at: scrollbackURL) }
    }

    private func makePty(id: String) throws -> RealPty {
        let pty = try RealPty(
            id: id,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024,
            scrollbackURL: scrollbackURL
        )
        pty.start() // reading/exit-watching is now owner-initiated (deferred from init)
        return pty
    }

    func testHistoryReplaysAfterRespawnFromDisk() throws {
        let surfaceID = UUID().uuidString
        let marker = "HARNESS_PERSIST_MARKER"

        // First "daemon run": spawn, produce output containing the marker, persist, tear down.
        let first = try makePty(id: surfaceID)
        let saw = expectation(description: "marker observed in live output")
        saw.assertForOverFulfill = false
        let acc = OutputAccumulator()
        _ = first.subscribe { data, _ in
            if acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) { saw.fulfill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { first.write("echo \(marker)\n") }
        wait(for: [saw], timeout: 8)
        first.flushScrollback() // graceful-shutdown flush
        first.close()

        // Second "daemon run": a brand-new surface over the same persisted file must replay history.
        let second = try makePty(id: surfaceID)
        defer { second.close() }
        XCTAssertTrue(
            second.replay(fromSequence: nil).contains(marker),
            "reattach after restart should replay persisted scrollback, not start blank"
        )
    }

    /// PR-18 `clear-history`: `clearScrollback()` empties the in-memory ring AND resets the
    /// on-disk file *without* respawning the shell — the gap that previously forced users to
    /// `respawn-pane -k` (which kills the running process) just to clear their scrollback. The
    /// reborn-surface assertion proves the clear reached disk, not just memory (a memory-only
    /// clear would leave the marker to replay on the next daemon run).
    func testClearScrollbackEmptiesRingAndFileWithoutRespawn() throws {
        let surfaceID = UUID().uuidString
        let marker = "HARNESS_CLEAR_MARKER"

        let pty = try makePty(id: surfaceID)
        let saw = expectation(description: "marker observed in live output")
        saw.assertForOverFulfill = false
        let acc = OutputAccumulator()
        _ = pty.subscribe { data, _ in
            if acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) { saw.fulfill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { pty.write("echo \(marker)\n") }
        wait(for: [saw], timeout: 8)
        // handleOutput appends to the ring before fanning out to subscribers, so seeing the
        // marker means it is already in scrollback — no settle needed.
        XCTAssertTrue(pty.replay(fromSequence: nil).contains(marker), "scrollback should hold the marker before clearing")

        pty.clearScrollback()

        XCTAssertFalse(
            pty.replay(fromSequence: nil).contains(marker),
            "clear-history must empty the in-memory scrollback"
        )

        // The shell is the SAME process (no respawn): it keeps accepting input and streaming.
        let after = "HARNESS_AFTER_CLEAR"
        let alive = expectation(description: "same shell still live after clear")
        alive.assertForOverFulfill = false
        let acc2 = OutputAccumulator()
        _ = pty.subscribe { data, _ in
            if acc2.appendAndContains(String(decoding: data, as: UTF8.self), marker: after) { alive.fulfill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { pty.write("echo \(after)\n") }
        wait(for: [alive], timeout: 8)
        pty.flushScrollback()
        pty.close()

        // Fresh surface over the same file: the pre-clear marker must be gone from disk too.
        let reborn = try makePty(id: surfaceID)
        defer { reborn.close() }
        XCTAssertFalse(
            reborn.replay(fromSequence: nil).contains(marker),
            "clear-history must reset the on-disk scrollback file, not just memory"
        )
    }

    // MARK: - `persist-scrollback` opt-out (PR-36: secrets at rest)

    /// Disabling persistence at runtime must WIPE the on-disk log synchronously (the user's
    /// intent is "no scrollback at rest", not "no new writes"), keep it gone under further
    /// output, and resume persisting after re-enable.
    func testSuspendingPersistenceWipesDiskAndResumeRepersists() throws {
        let pty = try makePty(id: UUID().uuidString)
        defer { pty.close() }

        let acc = OutputAccumulator()
        _ = pty.subscribe { data, _ in _ = acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { pty.write("echo BEFORE_SUSPEND_MARK\n") }
        XCTAssertTrue(waitUntil { acc.contains("BEFORE_SUSPEND_MARK") }, "live output must arrive")
        pty.flushScrollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: scrollbackURL.path), "persisted before suspend")

        pty.setScrollbackPersistence(enabled: false) // synchronous wipe
        XCTAssertFalse(FileManager.default.fileExists(atPath: scrollbackURL.path), "suspend wipes the log")

        pty.write("echo WHILE_SUSPENDED_MARK\n")
        XCTAssertTrue(waitUntil { acc.contains("WHILE_SUSPENDED_MARK") })
        pty.flushScrollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scrollbackURL.path),
                       "output while suspended must never reach disk")

        pty.setScrollbackPersistence(enabled: true)
        pty.write("echo AFTER_RESUME_MARK\n")
        XCTAssertTrue(waitUntil { acc.contains("AFTER_RESUME_MARK") })
        pty.flushScrollback()
        let resumed = (try? String(contentsOf: scrollbackURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(resumed.contains("AFTER_RESUME_MARK"), "re-enable resumes persistence")
        XCTAssertFalse(resumed.contains("WHILE_SUSPENDED_MARK"),
                       "suspended-window output stays memory-only by design")
    }

    /// `.scroll` logs are owner-only (0600) — SECURITY-POSTURE.md's at-rest permission claim,
    /// asserted literally. Also covers the upgrade path: a pre-existing log with the old
    /// default (0644) permissions is tightened the first time a surface loads it.
    func testScrollbackFileIsOwnerOnly() throws {
        // Legacy file from a build that predates the tightening: created 0644.
        try Data("legacy".utf8).write(to: scrollbackURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scrollbackURL.path)

        let pty = try makePty(id: UUID().uuidString) // ScrollbackFile init restricts on load
        defer { pty.close() }
        let initPerms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: scrollbackURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(initPerms.intValue & 0o777, 0o600, "a pre-existing 0644 log must be tightened on load")

        // Fresh writes (atomic create + append) keep the file owner-only.
        let acc = OutputAccumulator()
        _ = pty.subscribe { data, _ in _ = acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { pty.write("echo PERMS_MARK\n") }
        XCTAssertTrue(waitUntil { acc.contains("PERMS_MARK") }, "live output must arrive")
        pty.flushScrollback()
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: scrollbackURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(perms.intValue & 0o777, 0o600, ".scroll files hold raw PTY output — owner-only")
    }

    /// Registry-level tests need a HARNESS_HOME of their own so they never touch the user's
    /// real daemon state. Env-var scoped (process-wide, fine — live tests run serially).
    private func withIsolatedHarnessHome(_ body: () throws -> Void) throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = URL(fileURLWithPath: "/tmp/hps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("HARNESS_HOME", dir.path, 1)
        defer {
            if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
            try? FileManager.default.removeItem(at: dir)
        }
        try HarnessPaths.ensureDirectories()
        try body()
    }

    /// The registry end of the option: spawning with `persist-scrollback off` (global scope)
    /// creates no scrollback file and removes a stale one from an earlier persisted run; the
    /// runtime `set-option` path wipes a live surface's log.
    func testRegistryHonorsPersistScrollbackOption() throws {
        try withIsolatedHarnessHome { try runRegistryHonorsPersistScrollbackOption() }
    }

    private func runRegistryHonorsPersistScrollbackOption() throws {
        let registry = SurfaceRegistry()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces), let seeded = initial.first else {
            return XCTFail("expected a seeded surface")
        }
        let seededURL = HarnessPaths.scrollbackFileURL(forSurfaceID: seeded.surfaceID)

        // Default-on: output reaches the seeded surface's log.
        _ = registry.handle(.sendData(surfaceID: seeded.surfaceID, data: Data("echo PERSIST_DEFAULT_ON\n".utf8)))
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: seededURL.path) },
                      "default persistence must write a scrollback file")

        // Runtime opt-out (pane-scoped) wipes the live surface's log and keeps it gone.
        guard case .ok = registry.handle(.setOption(
            scope: "pane", target: seeded.surfaceID, key: "persist-scrollback", rawValue: "off"
        )) else { return XCTFail("setOption failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededURL.path), "opt-out wipes the log now")

        // Spawn-time opt-out: with the global option off, a new surface starts with no file
        // and a leftover log from a previously-persisted run is removed.
        guard case .ok = registry.handle(.setOption(
            scope: "global", target: nil, key: "persist-scrollback", rawValue: "off"
        )) else { return XCTFail("setOption failed") }
        let newSurface = UUID().uuidString
        let staleURL = HarnessPaths.scrollbackFileURL(forSurfaceID: newSurface)
        try Data("stale log".utf8).write(to: staleURL)
        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: newSurface, cwd: NSTemporaryDirectory(), shell: nil, rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path),
                       "spawn with persistence off removes a stale log")
        _ = registry.handle(.sendData(surfaceID: newSurface, data: Data("echo NEVER_ON_DISK\n".utf8)))
        usleep(700_000) // bounded absence window: give a (buggy) write time to land
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path),
                       "a persistence-off surface never writes scrollback to disk")
    }

    /// The FRONT-END convention end to end: for `set-option -p` without `-T`, both the CLI
    /// (`callingPaneTarget`) and the GUI (`CommandIPCTranslator`) send the owning
    /// `PaneLeaf.id` — an independent UUID from the surface id the registry keys sessions
    /// by. The defect: a PaneID-targeted opt-out stored under a target no read consulted,
    /// returned ok, and wiped nothing. Asserts the live wipe AND the spawn-time read on a
    /// "daemon restart" (a second registry over the same HARNESS_HOME).
    func testPaneIDTargetedOptOutWipesLiveSurfaceAndSurvivesRestart() throws {
        try withIsolatedHarnessHome { try runPaneIDTargetedOptOut() }
    }

    private func runPaneIDTargetedOptOut() throws {
        let registry = SurfaceRegistry()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces), let seeded = initial.first else {
            return XCTFail("expected a seeded surface")
        }
        let seededURL = HarnessPaths.scrollbackFileURL(forSurfaceID: seeded.surfaceID)
        _ = registry.handle(.sendData(surfaceID: seeded.surfaceID, data: Data("echo PANEID_BEFORE\n".utf8)))
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: seededURL.path) },
                      "default persistence must write a scrollback file")

        // The PaneID a front-end would send for `-p` without `-T`.
        guard case let .snapshot(snapshot) = registry.handle(.getSnapshot) else {
            return XCTFail("no snapshot")
        }
        let leaf = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
            .flatMap { $0.rootPane.allLeaves() }
            .first { $0.surfaceID.uuidString == seeded.surfaceID }
        let paneTarget = try XCTUnwrap(leaf, "seeded surface must be in the layout").id.uuidString
        XCTAssertNotEqual(paneTarget, seeded.surfaceID,
                          "PaneID and surface id are independent UUIDs — the dual convention under test")

        guard case .ok = registry.handle(.setOption(
            scope: "pane", target: paneTarget, key: "persist-scrollback", rawValue: "off"
        )) else { return XCTFail("setOption failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededURL.path),
                       "a PaneID-targeted opt-out must wipe the live surface's log")
        _ = registry.handle(.sendData(surfaceID: seeded.surfaceID, data: Data("echo PANEID_AFTER\n".utf8)))
        usleep(700_000) // bounded absence window
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededURL.path),
                       "output after a PaneID-targeted opt-out must never reach disk")

        // "Daemon restart": a fresh registry over the same home respawns the surface; the
        // spawn-time read must resolve the PaneID-keyed value too (and remove a leftover log).
        registry.flushSnapshot()
        registry.flushAllStores()
        registry.stopMonitoring()
        try Data("stale log".utf8).write(to: seededURL)
        let revived = SurfaceRegistry()
        defer { revived.stopMonitoring() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededURL.path),
                       "respawn must resolve the PaneID-keyed opt-out at spawn and drop the stale log")
        _ = revived.handle(.sendData(surfaceID: seeded.surfaceID, data: Data("echo PANEID_REVIVED\n".utf8)))
        usleep(700_000) // bounded absence window
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededURL.path),
                       "a revived opted-out surface never writes scrollback to disk")
    }

    /// `persist-scrollback` is enforceable only at pane or global scope (OptionStore's
    /// fallback walks broader scopes with nil targets, so a targeted tab/session/workspace
    /// value is unreachable by every read path). Such a set must fail loudly, not store a
    /// value that silently never applies — it's a security control.
    func testNonPaneScopedPersistScrollbackIsRejected() throws {
        try withIsolatedHarnessHome {
            let registry = SurfaceRegistry()
            defer { registry.stopMonitoring() }
            for scope in ["tab", "session", "workspace"] {
                guard case let .error(message) = registry.handle(.setOption(
                    scope: scope, target: UUID().uuidString, key: "persist-scrollback", rawValue: "off"
                )) else {
                    return XCTFail("\(scope)-scoped persist-scrollback must be rejected loudly")
                }
                XCTAssertTrue(message.contains("pane- or global-scoped"), "unexpected error: \(message)")
            }
        }
    }

    /// A surface SPAWNED while `persist-scrollback` was off must resume on-disk persistence
    /// when the option is re-enabled — live, and across a live `respawn-pane`. (It spawns
    /// with a suspended log writer, not none; before the fix its absent `ScrollbackFile`
    /// made the pane permanently memory-only even after the option came back on.)
    func testSpawnedOffSurfaceResumesPersistenceOnReenableAndRespawn() throws {
        try withIsolatedHarnessHome { try runSpawnedOffSurfaceResumes() }
    }

    private func runSpawnedOffSurfaceResumes() throws {
        let registry = SurfaceRegistry()
        defer { registry.stopMonitoring() }
        guard case .ok = registry.handle(.setOption(
            scope: "global", target: nil, key: "persist-scrollback", rawValue: "off"
        )) else { return XCTFail("setOption failed") }

        let surfaceID = UUID().uuidString
        let url = HarnessPaths.scrollbackFileURL(forSurfaceID: surfaceID)
        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: surfaceID, cwd: NSTemporaryDirectory(), shell: nil, rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface failed") }
        _ = registry.handle(.sendData(surfaceID: surfaceID, data: Data("echo SPAWNED_OFF\n".utf8)))
        usleep(700_000) // bounded absence window
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a surface spawned with persistence off stays off disk")

        // Re-enable: persistence resumes for the live spawned-off surface, no respawn needed.
        guard case .ok = registry.handle(.setOption(
            scope: "global", target: nil, key: "persist-scrollback", rawValue: "on"
        )) else { return XCTFail("setOption failed") }
        _ = registry.handle(.sendData(surfaceID: surfaceID, data: Data("echo BACK_ON_DISK\n".utf8)))
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: url.path) },
                      "re-enabling must resume persistence for a surface spawned while off")

        // And a live respawn keeps persisting through the same (now-active) log writer.
        guard case .ok = registry.handle(.respawnPane(surfaceID: surfaceID, keepHistory: false)) else {
            return XCTFail("respawnPane failed")
        }
        // Poll-write: the respawned shell comes up asynchronously, so re-send until the
        // marker lands on disk rather than racing a single write against the new PTY.
        XCTAssertTrue(
            waitUntil(pollIntervalMicros: 200_000) {
                _ = registry.handle(.sendData(surfaceID: surfaceID, data: Data("echo AFTER_RESPAWN\n".utf8)))
                return (try? String(contentsOf: url, encoding: .utf8))?.contains("AFTER_RESPAWN") == true
            },
            "a live respawn of a re-enabled surface must persist scrollback"
        )
    }
}
