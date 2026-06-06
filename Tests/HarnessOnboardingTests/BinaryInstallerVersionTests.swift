import XCTest
@testable import HarnessOnboarding

/// Re-running onboarding from an *older* Harness.app (Help → Welcome re-opens the wizard) must never
/// silently downgrade a newer installed daemon/CLI. These tests pin the version-aware overwrite
/// decision in `BinaryInstaller.copyReplacing`.
final class BinaryInstallerVersionTests: XCTestCase {
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-binaryinstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Newer bundled source over an older installed copy → overwrite (upgrade).
    @MainActor
    func testNewerSourceOverwritesOlderInstalled() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("NEW-119", to: src)
        try write("OLD-110", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: 119, installedBuild: 110)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(read(dest), "NEW-119")
    }

    /// Older bundled source over a newer installed copy → keep the installed (no downgrade).
    @MainActor
    func testOlderSourceKeepsNewerInstalled() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("OLD-110", to: src)
        try write("NEW-119", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: 110, installedBuild: 119)

        XCTAssertEqual(outcome, .keptNewerInstalled)
        XCTAssertEqual(read(dest), "NEW-119", "the newer installed binary must be left untouched")
    }

    /// Equal builds with identical bytes → skip the copy entirely (idempotent re-run).
    @MainActor
    func testEqualBytesAreSkipped() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("SAME-119", to: src)
        try write("SAME-119", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: 119, installedBuild: 119)

        XCTAssertEqual(outcome, .skippedIdentical)
        XCTAssertEqual(read(dest), "SAME-119")
    }

    /// Identical bytes are skipped even if the probe couldn't read either build (byte-equality wins).
    @MainActor
    func testIdenticalBytesSkippedWithoutBuildInfo() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("IDENTICAL", to: src)
        try write("IDENTICAL", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: nil, installedBuild: nil)

        XCTAssertEqual(outcome, .skippedIdentical)
    }

    /// Differing bytes with no build info on either side → fall back to overwrite (original behaviour).
    @MainActor
    func testDifferingBytesWithoutBuildInfoOverwrites() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("A", to: src)
        try write("B", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: nil, installedBuild: nil)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(read(dest), "A")
    }

    /// Equal build numbers but different bytes (e.g. a rebuild at the same build) → overwrite, since
    /// "keep installed" only triggers when the installed build is strictly newer.
    @MainActor
    func testEqualBuildDifferentBytesOverwrites() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("rebuilt", to: src)
        try write("original", to: dest)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: 119, installedBuild: 119)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(read(dest), "rebuilt")
    }

    /// No existing install → plain copy.
    @MainActor
    func testCopiesWhenDestinationMissing() throws {
        let dir = try makeDir()
        let src = dir.appendingPathComponent("src")
        let dest = dir.appendingPathComponent("dest")
        try write("NEW", to: src)

        let outcome = try BinaryInstaller.copyReplacing(
            src: src, dest: dest, executable: false, sourceBuild: 119, installedBuild: nil)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(read(dest), "NEW")
    }

    /// The default `buildNumberProbe` runs `<binary> version --json` and parses `cliBuild`.
    @MainActor
    func testBuildNumberProbeParsesCliBuildFromVersionJSON() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("harness-cli")
        // A stand-in that emits the same JSON shape as `harness-cli version --json`.
        try write(#"""
        #!/bin/sh
        echo '{"cliVersion":"1.6.0","cliBuild":119,"daemonRunning":false}'
        """#, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertEqual(BinaryInstaller.buildNumberProbe(fake), 119)
    }

    /// A binary with no `version` support (non-zero exit / no JSON) yields nil — the daemon case.
    @MainActor
    func testBuildNumberProbeReturnsNilForUnsupportedBinary() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("HarnessDaemon")
        try write(#"""
        #!/bin/sh
        exit 1
        """#, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
        // Missing file is also nil.
        XCTAssertNil(BinaryInstaller.buildNumberProbe(dir.appendingPathComponent("does-not-exist")))
    }

    /// Exit 0 with empty stdout (no JSON at all) yields nil, not a crash or a bogus build.
    @MainActor
    func testBuildNumberProbeReturnsNilForEmptyOutput() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("harness-cli")
        try write("#!/bin/sh\nexit 0\n", to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
    }

    /// Malformed / truncated JSON yields nil — never a parse crash mid-install.
    @MainActor
    func testBuildNumberProbeReturnsNilForMalformedJSON() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("harness-cli")
        try write(#"""
        #!/bin/sh
        echo '{"cliVersion":"1.6.0","cliBuild":'
        """#, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
        // Valid JSON missing the cliBuild field is also nil.
        try write(#"""
        #!/bin/sh
        echo '{"cliVersion":"1.6.0"}'
        """#, to: fake)
        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
    }

    /// A file that exists but is not executable yields nil (the pre-run guard).
    @MainActor
    func testBuildNumberProbeReturnsNilForNonExecutableFile() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("harness-cli")
        try write("not a binary", to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fake.path)
        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
    }

    /// The wizard-freeze regression (v1.7 audit): a wedged binary must surface as "no version
    /// info" within `probeTimeout` (+ escalation slack) instead of hanging the main actor —
    /// the unbounded `waitUntilExit` locked onboarding's Continue/Skip forever.
    @MainActor
    func testBuildNumberProbeTimesOutOnHungBinary() throws {
        let dir = try makeDir()
        let fake = dir.appendingPathComponent("harness-cli")
        try write("#!/bin/sh\nsleep 600\n", to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let start = Date()
        XCTAssertNil(BinaryInstaller.buildNumberProbe(fake))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, BinaryInstaller.probeTimeout + 3,
                          "the probe must give up within the bounded window, not block forever")
    }
}
