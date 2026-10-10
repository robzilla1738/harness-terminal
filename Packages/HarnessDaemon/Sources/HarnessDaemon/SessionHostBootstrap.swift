import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SessionHostBootstrap {
    /// Existing service definitions continue invoking HarnessDaemon. New installations
    /// enter the stable owner before touching stores or forking any shell. An already
    /// running legacy daemon is never re-executed or signalled by this path.
    public static func enterOwnerIfAvailable() {
        guard ProcessInfo.processInfo.environment["HARNESS_SESSION_HOST_SOCKET"] == nil else { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let owner = HarnessToolLocator.companion("HarnessSessionHost", to: executable)
        guard FileManager.default.isExecutableFile(atPath: owner.path) else { return }
        let argv = ([owner.path] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
        owner.path.withCString { path in argv.withUnsafeBufferPointer { _ = execv(path, $0.baseAddress!) } }
        for item in argv { if let item { free(item) } }
        fputs("HarnessDaemon: cannot enter the installed session host; no shells were created.\n", harnessStderr)
        exit(1)
    }
}
