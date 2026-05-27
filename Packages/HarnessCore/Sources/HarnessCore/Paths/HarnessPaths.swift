import Foundation

public enum HarnessPaths {
    private static var overrideRoot: URL? {
        guard let raw = ProcessInfo.processInfo.environment["HARNESS_HOME"], !raw.isEmpty else {
            if let bundled = Bundle.main.object(forInfoDictionaryKey: "HarnessPreviewHome") as? String,
               !bundled.isEmpty
            {
                return URL(fileURLWithPath: (bundled as NSString).expandingTildeInPath, isDirectory: true)
            }
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var applicationSupport: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Harness", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        applicationSupport.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var socketURL: URL {
        applicationSupport.appendingPathComponent("harness.sock")
    }

    public static var snapshotURL: URL {
        sessionsDirectory.appendingPathComponent("layout.json")
    }

    public static var settingsURL: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }
}
