import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension HarnessCLI {
    static func handleUninstall(_ args: [String]) throws {
        guard !args.contains("--host"), !args.contains(where: { $0.hasPrefix("--host=") }) else { throw DaemonRestart.Failure.refused("Run uninstall locally on the intended host.") }
        switch DaemonOwnership.probe() {
        case .alive: _ = try DaemonRestart.stop(force: restartAuthorization(args))
        case .uncertain: throw DaemonRestart.Failure.refused("The session owner cannot be verified. Uninstallation was refused; programs and files remain preserved.")
        case .absent: break
        }
        if !HarnessPaths.hasHomeOverride { try ServiceInstallers.current.uninstall() }
        if args.contains("--service-only") { print("Managed service removed; installed tools and user data preserved."); return }
        let removed = try DaemonInstanceLock.whileInactive(home: HarnessPaths.applicationSupport) {
            try BinaryRefresher.withInstalledToolsLock {
                let directory = BinaryRefresher.binDirectory
                var paths: [URL] = []
                var bundles: [URL] = []
                for name in ["HarnessSessionHost", "HarnessDaemon", "harness-cli"] {
                    let path = directory.appendingPathComponent(name); var info = stat()
                    guard lstat(path.path, &info) == 0 else { if errno == ENOENT { continue }; throw POSIXError(.EIO) }
                    guard info.st_uid == getuid() else { throw DaemonRestart.Failure.refused("An installed tool is not owned by this user; removal was refused: " + path.path) }
                    if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        guard let bundle = try BinaryRefresher.ownedHelperBundle(forInstalledExecutable: path) else { throw DaemonRestart.Failure.refused("An installed tool alias is not managed by Harness; removal was refused: " + path.path) }
                        bundles.append(bundle)
                    } else if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) { throw DaemonRestart.Failure.refused("An installed tool is not an owned executable; removal was refused: " + path.path) }
                    paths.append(path)
                }
                for path in paths { try FileManager.default.removeItem(at: path) }
                for bundle in bundles { try FileManager.default.removeItem(at: bundle) }
            }
        }
        guard removed else { throw LaunchAgentInstaller.InstallError.serviceNotInactive }
        print("Harness tools and managed service removed. Settings, layouts, credentials, worktrees, captured history, shell integration and unrelated bin files remain available.")
    }
}
