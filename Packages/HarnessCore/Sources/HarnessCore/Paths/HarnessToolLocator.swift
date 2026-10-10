import Foundation

/// Companion tools may be plain siblings on Linux/development builds or the
/// executable of a macOS helper bundle carrying its own provisioning profile.
public enum HarnessToolLocator {
    public static func companion(_ name: String, to executable: URL) -> URL {
        let executable = executable.resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS",
           directory.deletingLastPathComponent().lastPathComponent == "Contents" {
            let bundle = directory.deletingLastPathComponent().deletingLastPathComponent()
            if bundle.pathExtension == "app", bundle.lastPathComponent != "Harness.app",
               ["HarnessDaemon.app", "HarnessSessionHost.app", "harness-cli.app"].contains(bundle.lastPathComponent) {
                return bundle.deletingLastPathComponent().appendingPathComponent(name + ".app/Contents/MacOS/" + name)
            }
        }
        return directory.appendingPathComponent(name)
    }
}
