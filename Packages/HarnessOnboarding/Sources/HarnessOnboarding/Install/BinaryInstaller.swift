import Foundation
import AppKit
import HarnessCore

/// Installs `harness-cli` and `HarnessDaemon` into Application Support for the onboarding wizard.
///
/// Uses the same atomic copy and session-preserving service installer as the CLI and app.
@MainActor
enum BinaryInstaller {
    enum InstallError: LocalizedError {
        case missingBundledTools

        var errorDescription: String? {
            "This copy of Harness is missing its command-line tools. Reinstall Harness from the DMG."
        }
    }

    /// The `Contents/MacOS` directory of the host app. Embedded in Harness.app this is where
    /// the bundled `harness-cli` + `HarnessDaemon` live (copied in by the "Copy Bundled Tools"
    /// build step), so installs copy straight out of the running bundle.
    nonisolated private static var bundledMacOSDir: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    /// Where to copy `binary` from: the running bundle, a sibling of it (an Xcode build), or an
    /// installed Harness.app. Nil when none has it.
    nonisolated static func bundledSource(named binary: String) -> URL? {
        [
            Bundle.main.executableURL.map { HarnessToolLocator.companion(binary, to: $0) },
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(binary),
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/\(binary)"),
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Install

    // `performInstall` and its helpers are `nonisolated`: they touch only the filesystem and spawn
    // processes. `buildNumberProbe` is a main-actor static var, so a caller leaving the main actor
    // captures it first and passes it as `probe` (see `OnboardingSetup.installBinaries`).

    nonisolated static func performInstall(cliSource: URL? = nil, daemonSource: URL? = nil,
                                           probe: (@Sendable (URL) -> Int?)? = nil) throws {
        guard let cliSrc = cliSource ?? bundledSource(named: "harness-cli"),
              let daemonSrc = daemonSource ?? bundledSource(named: "HarnessDaemon") else {
            throw InstallError.missingBundledTools
        }
        try HarnessCLIPaths.ensureDirectories()

        // Re-running onboarding from an *older* Harness.app (Help → Welcome re-opens this wizard)
        // must never silently downgrade a newer installed daemon/CLI. The bundled CLI + daemon
        // always ship from the same app build, so a single source-vs-installed `harness-cli`
        // build-number comparison governs the overwrite decision for *both* binaries (the daemon
        // has no version flag of its own).
        let resolvedProbe: (URL) -> Int? = probe ?? BinaryInstaller.defaultBuildNumberProbe
        let sourceBuild = resolvedProbe(cliSrc)
        let installedBuild = resolvedProbe(HarnessCLIPaths.installedCLIPath)
        try copyReplacing(src: cliSrc, dest: HarnessCLIPaths.installedCLIPath, executable: true,
                          sourceBuild: sourceBuild, installedBuild: installedBuild)
        let ownerSrc = HarnessToolLocator.companion("HarnessSessionHost", to: daemonSrc)
        if FileManager.default.isExecutableFile(atPath: ownerSrc.path) {
            try copyReplacing(src: ownerSrc, dest: BinaryRefresher.installedSessionHostPath, executable: true,
                              sourceBuild: sourceBuild, installedBuild: installedBuild)
        } else if daemonSource == nil { throw InstallError.missingBundledTools }
        try copyReplacing(src: daemonSrc, dest: HarnessCLIPaths.installedDaemonPath, executable: true,
                          sourceBuild: sourceBuild, installedBuild: installedBuild)

        installLaunchAgentIfNeeded()
    }

    /// Point launchd at the installed daemon, but only when there is no working LaunchAgent yet.
    /// By the time the wizard runs, the app has usually registered one for the bundled daemon, and
    /// rewriting it would `bootout` that daemon along with every shell and agent running in it. The
    /// app moves the agent to the installed copy itself the next time its daemon fails to answer.
    /// Best-effort: the app starts a daemon on its own when launchd won't.
    nonisolated private static func installLaunchAgentIfNeeded() {
        guard !HarnessCLIPaths.hasHomeOverride else { return }
        _ = try? LaunchAgentInstaller.install(daemonPath: HarnessCLIPaths.installedDaemonPath,
                                             harnessHome: HarnessCLIPaths.applicationSupport)
    }

    /// The daemon a LaunchAgent plist runs (its first `ProgramArguments` entry), if it parses.
    nonisolated static func launchAgentDaemonPath(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    // MARK: - Helpers

    /// What an overwrite attempt decided to do (e.g. keep a newer installed daemon when re-run
    /// from an older app).
    enum CopyOutcome: Equatable {
        case copied
        case skippedIdentical
        case keptNewerInstalled
    }

    /// How long `buildNumberProbe` waits for `version --json` before declaring the binary
    /// unresponsive. The probe runs off the main thread (see `OnboardingSetup.installBinaries`),
    /// so this bound is the maximum extra latency
    /// the install step can add per binary before giving up and proceeding on the
    /// no-build fallback path. `nonisolated` so the Sendable probe closure below can read it.
    nonisolated static let probeTimeout: TimeInterval = 3

    /// The actual build-number probe implementation.  `nonisolated` + `let` so
    /// `performInstall` can access it safely from a detached task without touching the
    /// @MainActor-isolated `buildNumberProbe` static var.  The two always hold the same
    /// code; `buildNumberProbe` is kept for backwards compatibility with existing tests.
    nonisolated static let defaultBuildNumberProbe: @Sendable (URL) -> Int? = { url in
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = ["version", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + BinaryInstaller.probeTimeout) == .timedOut {
            // Wedged binary: terminate, escalate once, report "no version info".
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return nil
        }
        // Read only after exit so a child that never closes stdout can't block us — the version
        // JSON is tiny (far below the pipe buffer), so nothing was lost while waiting. The read
        // itself stays bounded too: a grandchild inheriting the write end would hold EOF open.
        let box = ProbeOutputBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.store((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
            readDone.signal()
        }
        guard readDone.wait(timeout: .now() + 1) != .timedOut else { return nil }
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: box.take()) as? [String: Any],
              let build = object["cliBuild"] as? Int else { return nil }
        return build
    }

    /// Read a binary's build number by running `<binary> version --json` and parsing `cliBuild`.
    /// Overridable so tests can stage fake source/installed builds without real executables.
    /// Returns nil when the binary is absent or doesn't answer (e.g. HarnessDaemon has no version
    /// flag — the daemon's overwrite decision reuses the CLI build instead). Every wait below is
    /// bounded: the old unbounded `readToEnd` + `waitUntilExit` hung the main thread for good if
    /// a corrupted/stuck binary never exited.
    ///
    /// In production code, prefer `defaultBuildNumberProbe` (nonisolated) when calling from a
    /// detached task — this var is @MainActor-isolated (being a static var on a @MainActor type).
    /// Tests override this var to inject fake probes without spawning real processes.
    static var buildNumberProbe: @Sendable (URL) -> Int? = defaultBuildNumberProbe

    /// Copy `src` over `dest`, but never *downgrade*: skip a byte-identical install, and when the
    /// bytes differ keep the installed copy if its build is newer than the source's. With no build
    /// info on either side we fall back to the original replace-in-place behaviour.
    /// `internal` (not private) so the version-decision is unit-testable without invoking the real
    /// launchctl bootstrap in `performInstall`.
    @discardableResult
    nonisolated static func copyReplacing(src: URL, dest: URL, executable: Bool,
                                          sourceBuild: Int? = nil, installedBuild: Int? = nil) throws -> CopyOutcome {
        if src.standardizedFileURL.path == dest.standardizedFileURL.path {
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            return .skippedIdentical
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            // Identical bytes — nothing to do (and definitely no downgrade).
            if filesAreIdentical(src, dest) {
                if executable {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                }
                return .skippedIdentical
            }
            // Different bytes: keep the installed copy when it is strictly newer than the source.
            if let installedBuild, let sourceBuild, installedBuild > sourceBuild {
                return .keptNewerInstalled
            }
        }
        if executable {
            try BinaryRefresher.copyExecutable(from: src, to: dest)
        } else {
            try Data(contentsOf: src).write(to: dest, options: .atomic)
        }
        return .copied
    }

    /// Cheap byte-equality: compare sizes first, then contents only if they match.
    nonisolated private static func filesAreIdentical(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let sizeA = (try? fm.attributesOfItem(atPath: a.path)[.size]) as? Int
        let sizeB = (try? fm.attributesOfItem(atPath: b.path)[.size]) as? Int
        if let sizeA, let sizeB, sizeA != sizeB { return false }
        guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b) else { return false }
        return dataA == dataB
    }


}

/// Lock-boxed pipe output so `buildNumberProbe`'s bounded read can hand bytes across queues
/// without a captured-var data race.
private final class ProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func store(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
