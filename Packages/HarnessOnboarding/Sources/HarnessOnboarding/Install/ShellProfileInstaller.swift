import Foundation

/// Self-contained PATH wiring for the onboarding wizard. It mirrors the CLI's
/// owner-only install location while keeping the onboarding module independent
/// from HarnessCore.
enum ShellProfileInstaller {
    enum Shell: String, CaseIterable {
        case zsh
        case bash
        case fish

        var profilePath: String {
            switch self {
            case .zsh: ".zshrc"
            case .bash: ".bash_profile"
            case .fish: ".config/fish/config.fish"
            }
        }
    }

    struct Profile: Identifiable, Equatable {
        var id: Shell { shell }
        let shell: Shell
        let profileURL: URL
        let line: String
        var alreadyHas: Bool
    }

    struct InstallResult: Equatable {
        let profileURL: URL
        let backupURL: URL?
        let alreadyConfigured: Bool
    }

    private static let markerBegin = "# >>> Harness CLI PATH >>>"
    private static let markerEnd = "# <<< Harness CLI PATH <<<"

    static func profiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binDirectory: URL = HarnessCLIPaths.binDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Profile] {
        Shell.allCases.map { shell in
            let url = profileURL(for: shell, home: home, environment: environment)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return Profile(
                shell: shell,
                profileURL: url,
                line: pathLine(for: shell, binDirectory: binDirectory),
                alreadyHas: contentHasPath(content, binDirectory: binDirectory)
            )
        }
    }

    static func profileURL(for shell: Shell, home: URL, environment: [String: String]) -> URL {
        switch shell {
        case .zsh:
            if let directory = environment["ZDOTDIR"], !directory.isEmpty {
                return URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent(".zshrc")
            }
        case .fish:
            if let directory = environment["XDG_CONFIG_HOME"], directory.hasPrefix("/") {
                return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("fish/config.fish")
            }
        case .bash:
            for name in [".bash_profile", ".bash_login", ".profile"] {
                let url = home.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return home.appendingPathComponent(shell.profilePath)
    }

    /// The profiles worth editing: the login shell's, plus any other shell whose profile already
    /// exists. A zsh user never gets a `.bash_profile` or a fish config created for them.
    static func relevantProfiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binDirectory: URL = HarnessCLIPaths.binDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShell: String? = currentLoginShell()
    ) -> [Profile] {
        let login = loginShell.flatMap { Shell(rawValue: URL(fileURLWithPath: $0).lastPathComponent) } ?? .zsh
        let all = profiles(home: home, binDirectory: binDirectory, environment: environment)
        return all.filter { $0.shell == login }
            + all.filter { $0.shell != login && FileManager.default.fileExists(atPath: $0.profileURL.path) }
    }

    /// The account's login shell from the user database (a GUI app's `$SHELL` can be stale or unset).
    static func currentLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return ProcessInfo.processInfo.environment["SHELL"]
        }
        return String(cString: shell)
    }

    @discardableResult
    static func install(
        _ shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binDirectory: URL = HarnessCLIPaths.binDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InstallResult {
        var profileURL = profileURL(for: shell, home: home, environment: environment)
        if (try? FileManager.default.attributesOfItem(atPath: profileURL.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            profileURL = profileURL.resolvingSymlinksInPath()
        }
        let body = blockBody(for: shell, binDirectory: binDirectory)
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A decoding or permission failure must never turn an existing profile into an empty one.
        let existing: String
        do { existing = try String(contentsOf: profileURL, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { existing = "" }
        if contentHasPath(existing, binDirectory: binDirectory), !hasHarnessBlock(existing) {
            return InstallResult(profileURL: profileURL, backupURL: nil, alreadyConfigured: true)
        }

        let updated: String
        if let range = harnessBlockRange(in: existing) {
            let replacement = "\(markerBegin)\n\(body)\n\(markerEnd)"
            updated = existing.replacingCharacters(in: range, with: replacement)
            if updated == existing {
                return InstallResult(profileURL: profileURL, backupURL: nil, alreadyConfigured: true)
            }
        } else {
            let block = "\(markerBegin)\n\(body)\n\(markerEnd)\n"
            if existing.isEmpty {
                updated = block
            } else {
                updated = existing + (existing.hasSuffix("\n") ? "" : "\n") + "\n" + block
            }
        }

        let backup: URL?
        if FileManager.default.fileExists(atPath: profileURL.path) {
            let url = profileURL.appendingPathExtension("harness-bak-\(UUID().uuidString.prefix(8))")
            try FileManager.default.copyItem(at: profileURL, to: url)
            backup = url
        } else {
            backup = nil
        }
        try Data(updated.utf8).write(to: profileURL, options: .atomic)
        return InstallResult(profileURL: profileURL, backupURL: backup, alreadyConfigured: false)
    }

    static func pathLine(for shell: Shell, binDirectory: URL = HarnessCLIPaths.binDirectory) -> String {
        switch shell {
        case .zsh, .bash:
            return "export PATH=\"\(shDoubleQuotedPath(binDirectory.path)):$PATH\""
        case .fish:
            return "set -gx PATH \(fishSingleQuotedPath(binDirectory.path)) $PATH"
        }
    }

    /// The full marked-block body. For bash this is the PATH export PLUS a guard that sources
    /// `.bashrc` — Harness spawns shells as `$SHELL -l`, and a bash LOGIN shell reads `.bash_profile`
    /// but NOT `.bashrc`, where `ShellIntegration` installs the OSC 133 prompt marks. Without this
    /// bridge a bash user gets PATH but silently no shell integration. zsh reads `.zshrc` for both
    /// login and interactive shells and fish reads `config.fish`, so only bash needs it.
    static func blockBody(for shell: Shell, binDirectory: URL = HarnessCLIPaths.binDirectory) -> String {
        let path = pathLine(for: shell, binDirectory: binDirectory)
        switch shell {
        case .bash:
            return path + "\n"
                + "# Source .bashrc in login shells so interactive setup (incl. Harness shell integration) applies\n"
                + "[ -n \"${BASH_VERSION:-}\" ] && [ -f ~/.bashrc ] && . ~/.bashrc"
        case .zsh, .fish:
            return path
        }
    }

    static func contentHasPath(_ content: String, binDirectory: URL = HarnessCLIPaths.binDirectory) -> Bool {
        let spellings = [binDirectory.path, shDoubleQuotedPath(binDirectory.path), fishSingleQuotedPath(binDirectory.path)]
        return content.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let assignsPath = trimmed.hasPrefix("export PATH=") || trimmed.hasPrefix("PATH=")
                || trimmed.hasPrefix("set -gx PATH ") || trimmed.hasPrefix("fish_add_path ")
            return assignsPath && spellings.contains(where: trimmed.contains)
        }
    }

    private static func hasHarnessBlock(_ content: String) -> Bool {
        harnessBlockRange(in: content) != nil
    }

    private static func harnessBlockRange(in content: String) -> Range<String.Index>? {
        guard let start = content.range(of: markerBegin)?.lowerBound,
              let endMarker = content.range(of: markerEnd, range: start ..< content.endIndex)
        else { return nil }
        return start ..< endMarker.upperBound
    }

    private static func shDoubleQuotedPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func fishSingleQuotedPath(_ path: String) -> String {
        "'" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            + "'"
    }
}
