import Foundation
import AppKit

/// The one-click installer logic for the standalone Harness CLI onboarding experience.
///
/// It is deliberately self-contained (no link to HarnessCore) but follows the exact
/// same paths, plist template, and launchctl patterns as the real `harness-cli install`
/// and `LaunchAgentInstaller` so that the result is 100% compatible with a future
/// full Harness.app or CLI-only distribution.
@MainActor
enum BinaryInstaller {
    enum DetectionStatus: Equatable {
        case found(version: String?, path: URL)
        case willInstall
        case notFound

        var display: String {
            switch self {
            // Fall back to the detected binary's name so the Daemon row reads "Found HarnessDaemon"
            // — not the CLI's "Found harness-cli" (both rows pass version: nil today).
            case .found(let v, let path): "Found \(v ?? path.lastPathComponent)"
            case .willInstall: "Will install"
            case .notFound: "Not found in common locations"
            }
        }

        var isReady: Bool {
            switch self {
            case .found, .willInstall: true
            case .notFound: false
            }
        }
    }

    struct InstallReport {
        let cliInstalled: Bool
        let daemonInstalled: Bool
        let launchAgentInstalled: Bool
        let messages: [String]
    }

    enum InstallError: LocalizedError {
        case missingBundledTools(messages: [String])

        var errorDescription: String? {
            switch self {
            case .missingBundledTools(let messages):
                return (messages + ["Harness.app is missing its bundled command-line tools. Rebuild or reinstall Harness."])
                    .joined(separator: "\n")
            }
        }
    }

    // MARK: - Detection (the locations the real harness-cli install also checks)

    /// The `Contents/MacOS` directory of the host app. Embedded in Harness.app this is where
    /// the bundled `harness-cli` + `HarnessDaemon` live (copied in by the "Copy Bundled Tools"
    /// build step), so the Install step copies straight out of the running bundle.
    nonisolated private static var bundledMacOSDir: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    static func detectCLI() -> DetectionStatus {
        let candidates: [URL] = [
            // 1. Inside the running app bundle's MacOS dir (Harness.app embeds the binaries)
            bundledMacOSDir?.appendingPathComponent("harness-cli"),
            // 2. Next to the app (the "all-in-one DMG" layout)
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("harness-cli"),
            // 3. Inside a sibling Harness.app (if the user has the GUI version)
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/harness-cli"),
            // 4. Already installed by a previous run or the GUI app
            HarnessCLIPaths.installedCLIPath,
            // 5. Dev builds
            URL(fileURLWithPath: ".build/release/harness-cli", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                // Best-effort version (the real binary prints nothing on --version today,
                // so we just report the path; the UI shows "Found").
                return .found(version: nil, path: url)
            }
        }
        return .willInstall   // we will copy from the best candidate we can find at install time
    }

    static func detectDaemon() -> DetectionStatus {
        let candidates: [URL] = [
            bundledMacOSDir?.appendingPathComponent("HarnessDaemon"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("HarnessDaemon"),
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon"),
            HarnessCLIPaths.installedDaemonPath,
            URL(fileURLWithPath: ".build/release/HarnessDaemon", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        ].compactMap { $0 }
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return .found(version: nil, path: url)
            }
        }
        return .willInstall
    }

    // MARK: - The actual install (idempotent, user-friendly)

    // NOTE: performInstall and its helpers are `nonisolated` because they touch only the
    // filesystem and spawn Processes — they read/write no @MainActor state.  The one
    // exception is `buildNumberProbe`, which is a `static var` and therefore @MainActor-
    // isolated.  Callers that need to run off the main thread should capture the closure
    // in a local `let` before leaving the main actor (the call site in SetupStepView does
    // exactly this via `Task.detached`).  See SetupStepView.performInstall for the pattern.

    nonisolated static func performInstall(cliSource: URL?, daemonSource: URL?, probe: (@Sendable (URL) -> Int?)? = nil) throws -> InstallReport {
        var messages: [String] = []
        var cliOK = false
        var daemonOK = false
        var agentOK = false

        try HarnessCLIPaths.ensureDirectories()

        // Re-running onboarding from an *older* Harness.app (Help → Welcome re-opens this wizard)
        // must never silently downgrade a newer installed daemon/CLI. The bundled CLI + daemon
        // always ship from the same app build, so a single source-vs-installed `harness-cli`
        // build-number comparison governs the overwrite decision for *both* binaries (the daemon
        // has no version flag of its own). The v1.3.2 BinaryRefresher doesn't heal this — it
        // byte-diffs against the launching app's own bundle, not the previously installed copy.
        let cliSrc = cliSource ?? findBestSource(named: "harness-cli")
        let daemonSrc = daemonSource ?? findBestSource(named: "HarnessDaemon")
        // Use the caller-provided probe closure (captured before going off-main) so we
        // never touch the @MainActor `buildNumberProbe` static var from a nonisolated context.
        // The default (nil) falls back to the same DispatchSemaphore-bounded implementation
        // that the static var holds, but avoids the actor-isolation issue.
        let resolvedProbe: (URL) -> Int? = probe ?? BinaryInstaller.defaultBuildNumberProbe
        let sourceBuild = cliSrc.flatMap { resolvedProbe($0) }
        let installedBuild = resolvedProbe(HarnessCLIPaths.installedCLIPath)

        // Copy CLI
        if let src = cliSrc {
            let dest = HarnessCLIPaths.installedCLIPath
            let outcome = try copyReplacing(src: src, dest: dest, executable: true,
                                            sourceBuild: sourceBuild, installedBuild: installedBuild)
            messages.append(outcome.message(binary: "harness-cli", dest: dest))
            cliOK = true
        } else {
            messages.append("harness-cli source not found; skipping binary copy")
        }

        // Copy Daemon — same build comparison as the CLI (they ship together from one app build).
        if let src = daemonSrc {
            let dest = HarnessCLIPaths.installedDaemonPath
            let outcome = try copyReplacing(src: src, dest: dest, executable: true,
                                            sourceBuild: sourceBuild, installedBuild: installedBuild)
            messages.append(outcome.message(binary: "HarnessDaemon", dest: dest))
            daemonOK = true
        } else {
            messages.append("HarnessDaemon source not found; skipping binary copy")
        }

        guard cliOK, daemonOK else {
            throw InstallError.missingBundledTools(messages: messages)
        }

        // LaunchAgent (always try; uses the exact template we captured from the real installer)
        if daemonOK || FileManager.default.fileExists(atPath: HarnessCLIPaths.installedDaemonPath.path) {
            let daemonPath = HarnessCLIPaths.installedDaemonPath
            let home = HarnessCLIPaths.applicationSupport
            let log = home.appendingPathComponent("logs/daemon.log")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

            let plistContent = launchAgentPlist(daemonPath: daemonPath, harnessHome: home, logPath: log)
            let plistURL = HarnessCLIPaths.launchAgentURL
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let existed = FileManager.default.fileExists(atPath: plistURL.path)
            let changed = (try? String(contentsOf: plistURL, encoding: .utf8)) != plistContent

            if changed {
                if existed {
                    _ = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
                }
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
            }

            let result = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            if result.status == 0 || result.status == 37 || result.status == 5 {
                agentOK = true
                messages.append("LaunchAgent installed → \(plistURL.path)")
            } else {
                messages.append("LaunchAgent bootstrap returned \(result.status): \(result.output)")
            }
            _ = runLaunchctl(["enable", "gui/\(getuid())/\(HarnessCLIPaths.launchAgentLabel)"])
        } else {
            messages.append("No daemon binary available — LaunchAgent not installed")
        }

        return InstallReport(
            cliInstalled: cliOK,
            daemonInstalled: daemonOK,
            launchAgentInstalled: agentOK,
            messages: messages
        )
    }

    // MARK: - Helpers

    nonisolated private static func findBestSource(named binary: String) -> URL? {
        if let bundled = bundledMacOSDir?.appendingPathComponent(binary),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let relative = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(binary)
        if FileManager.default.fileExists(atPath: relative.path) { return relative }

        let app = URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/\(binary)")
        if FileManager.default.fileExists(atPath: app.path) { return app }

        return nil
    }

    /// What an overwrite attempt decided to do, so the wizard can surface it (e.g. a "kept newer
    /// installed daemon" status when re-run from an older app).
    enum CopyOutcome: Equatable {
        case copied
        case skippedIdentical
        case keptNewerInstalled

        func message(binary: String, dest: URL) -> String {
            switch self {
            case .copied:             "\(binary) → \(dest.path)"
            case .skippedIdentical:   "\(binary) already current → \(dest.path)"
            case .keptNewerInstalled: "kept newer installed \(binary) → \(dest.path)"
            }
        }
    }

    /// How long `buildNumberProbe` waits for `version --json` before declaring the binary
    /// unresponsive. The probe runs off the main thread (see `performInstall` + the
    /// `Task.detached` in `SetupStepView`), so this bound is the maximum extra latency
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
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
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

    /// The exact plist template captured from the real LaunchAgentInstaller at project creation.
    nonisolated private static func launchAgentPlist(daemonPath: URL, harnessHome: URL, logPath: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HarnessCLIPaths.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath.path)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HARNESS_HOME</key>
                <string>\(harnessHome.path)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
                <key>Crashed</key>
                <true/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logPath.path)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath.path)</string>
            <key>ThrottleInterval</key>
            <integer>5</integer>
        </dict>
        </plist>
        """
    }

    nonisolated private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
