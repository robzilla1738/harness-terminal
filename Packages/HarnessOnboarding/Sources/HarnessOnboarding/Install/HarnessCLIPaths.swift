import Foundation

/// Self-contained path helpers for the onboarding installer.
/// Mirrors the relevant pieces of HarnessCore.HarnessPaths so the wizard can
/// install to exactly the same locations the real harness-cli expects — without
/// any build or runtime dependency on the main monorepo.
enum HarnessCLIPaths {
    static var hasHomeOverride: Bool { overrideRoot != nil }

    private static var overrideRoot: URL? {
        let environment = ProcessInfo.processInfo.environment["HARNESS_HOME"]
        let bundled = Bundle.main.object(forInfoDictionaryKey: "HarnessPreviewHome") as? String
        guard let raw = [environment, bundled].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var applicationSupport: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Harness", isDirectory: true)
    }

    static var binDirectory: URL {
        applicationSupport.appendingPathComponent("bin", isDirectory: true)
    }

    static var installedCLIPath: URL {
        binDirectory.appendingPathComponent("harness-cli")
    }

    static var installedDaemonPath: URL {
        binDirectory.appendingPathComponent("HarnessDaemon")
    }

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.robert.harness.daemon.plist")
    }

    static let launchAgentLabel = "com.robert.harness.daemon"

    static func ensureDirectories() throws {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: applicationSupport.path)
    }
}