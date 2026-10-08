import AppKit
import HarnessCore
import UniformTypeIdentifiers

struct DefaultTerminalStatus: Equatable {
    var missingItems: [String]
    var isDefault: Bool { missingItems.isEmpty }

    var summary: String {
        if isDefault {
            return "Harness is default for SSH/Telnet/man-page links, terminal command files, shell scripts, and executables."
        }
        return "Not default for: \(missingItems.joined(separator: ", "))."
    }
}

enum DefaultTerminalRegistrationError: LocalizedError {
    case failed([String])

    var errorDescription: String? {
        switch self {
        case let .failed(messages):
            return messages.joined(separator: "\n")
        }
    }
}

@MainActor
enum DefaultTerminalManager {
    private static let urlSchemes = ["ssh", "telnet", "x-man-page"]
    private static let commandFileTypeIdentifier = "com.apple.terminal.shell-script"
    private static let commandFileType = UTType(filenameExtension: "command")
        ?? UTType(importedAs: commandFileTypeIdentifier)

    static func status() -> DefaultTerminalStatus {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return DefaultTerminalStatus(missingItems: ["app registration"])
        }

        var missing: [String] = []
        for scheme in urlSchemes where defaultHandler(forScheme: scheme) != bundleID {
            missing.append("\(scheme)://")
        }
        if defaultHandlerForCommandFiles() != bundleID {
            missing.append(".command/.tool files")
        }
        if defaultHandler(forContentType: .unixExecutable) != bundleID {
            missing.append("executables")
        }
        if defaultHandler(forContentType: .shellScript) != bundleID {
            missing.append("shell scripts")
        }
        return DefaultTerminalStatus(missingItems: missing)
    }

    static func setAsDefault() async throws {
        let appURL = Bundle.main.bundleURL
        var failures: [String] = []

        for scheme in urlSchemes {
            do {
                try await setDefaultApplication(appURL, forScheme: scheme)
            } catch {
                failures.append("\(scheme)://: \(error.localizedDescription)")
            }
        }

        do {
            try await setDefaultApplication(appURL, forContentType: commandFileType)
        } catch {
            failures.append(".command/.tool files: \(error.localizedDescription)")
        }

        do {
            try await setDefaultApplication(appURL, forContentType: .unixExecutable)
        } catch {
            failures.append("executables: \(error.localizedDescription)")
        }

        do {
            try await setDefaultApplication(appURL, forContentType: .shellScript)
        } catch {
            failures.append("shell scripts: \(error.localizedDescription)")
        }

        if !failures.isEmpty {
            throw DefaultTerminalRegistrationError.failed(failures)
        }
    }

    // The completion handlers are `@Sendable` so they are NOT inferred as `@MainActor`-isolated
    // (inherited from the enclosing `@MainActor enum`). NSWorkspace invokes them on a background
    // queue, and a MainActor-isolated closure entered off-main trips the Swift 6 executor-isolation
    // check and traps. `@Sendable` makes them non-isolated; they only resume a `Sendable`
    // continuation, valid from any thread. The NSWorkspace call itself still runs on the main actor.
    private static func setDefaultApplication(_ appURL: URL, forScheme scheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func setDefaultApplication(_ appURL: URL, forContentType contentType: UTType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: contentType) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func defaultHandler(forScheme scheme: String) -> String? {
        guard let url = URL(string: "\(scheme)://harness.invalid") else { return nil }
        return bundleIdentifierForDefaultApplication(toOpen: url)
    }

    private static func defaultHandlerForCommandFiles() -> String? {
        bundleIdentifierForDefaultApplication(toOpen: URL(fileURLWithPath: "/tmp/harness-default-terminal.command"))
    }

    private static func bundleIdentifierForDefaultApplication(toOpen url: URL) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private static func defaultHandler(forContentType type: UTType) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }
}

@MainActor
enum DefaultTerminalOpener {
    /// Opens each URL as a terminal. `asWindow` only affects a bare directory open (a folder from the
    /// Finder "New Harness Window Here" service): it opens a new session in a new window. ssh/telnet/
    /// man-page and file-with-command requests always open a tab in the active session.
    static func open(_ urls: [URL], asWindow: Bool = false) {
        // Finder folders and local files open on this Mac, even with a remote window in front:
        // a new window there, or a tab in a window on this Mac.
        if asWindow {
            SessionCoordinator.shared.activate(owner: DaemonSidebar.localID)
        } else {
            SessionCoordinator.shared.showDaemon(DaemonSidebar.localID)
        }
        for url in urls {
            guard let request = DefaultTerminalLaunchRequest.make(for: url) else { continue }
            if asWindow, request.command == nil, let cwd = request.cwd {
                (NSApp.delegate as? AppDelegate)?.newWindow(cwd: cwd, name: request.title)
            } else {
                SessionCoordinator.shared.openDefaultTerminalLaunch(request)
            }
        }
    }
}
