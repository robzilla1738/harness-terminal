import Foundation

/// OSC 133 shell integration: the per-shell scripts that emit semantic prompt marks (`133;A`)
/// and command-finished status (`133;D;<exit>`), plus an installer that drops the script under
/// the Harness home and wires a `source` line into the user's shell rc — idempotently, backing
/// the rc up first. These scripts are the runtime source of truth (the copies under
/// `docs/shell-integration/` mirror them for reading); the daemon exports `$HARNESS`, which they
/// gate on, so they activate only inside a Harness pane.
public enum ShellIntegration {
    public enum Shell: String, CaseIterable, Sendable {
        case bash, zsh, fish

        /// Resolve a shell path or name (`/bin/zsh`, `zsh`, `-fish`) to a known shell.
        public static func detect(from shellPath: String) -> Shell? {
            let name = (shellPath as NSString).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            switch name {
            case "bash": return .bash
            case "zsh": return .zsh
            case "fish": return .fish
            default: return nil
            }
        }
    }

    public struct InstallResult: Sendable, Equatable {
        /// Where the script was written.
        public let scriptPath: URL
        /// The rc file the source line was added to.
        public let rcPath: URL
        /// The exact line wired into the rc (for display).
        public let sourceLine: String
        /// True when the rc already had the integration (nothing appended this run).
        public let alreadyWired: Bool
        /// Backup of the rc if one was made before editing it.
        public let rcBackedUp: URL?
    }

    /// The script body for a shell — the runtime source of truth.
    public static func script(for shell: Shell) -> String {
        switch shell {
        case .zsh: return zshScript
        case .bash: return bashScript
        case .fish: return fishScript
        }
    }

    /// The file the script is written to under the Harness home.
    public static func scriptURL(for shell: Shell) -> URL {
        HarnessPaths.applicationSupport
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent("harness.\(shell.rawValue)")
    }

    /// The conventional rc file for a shell (honoring `$ZDOTDIR` for zsh).
    public static func rcURL(for shell: Shell, homeOverride: URL? = nil) -> URL {
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        switch shell {
        case .bash: return home.appendingPathComponent(".bashrc")
        case .zsh:
            if let zdot = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdot.isEmpty, homeOverride == nil {
                return URL(fileURLWithPath: (zdot as NSString).expandingTildeInPath)
                    .appendingPathComponent(".zshrc")
            }
            return home.appendingPathComponent(".zshrc")
        case .fish: return home.appendingPathComponent(".config/fish/config.fish")
        }
    }

    private static let markerBegin = "# >>> Harness shell integration >>>"
    private static let markerEnd = "# <<< Harness shell integration <<<"

    /// Write the script under the Harness home and wire a guarded `source` line into the shell's
    /// rc. Idempotent (a marker block guards against duplicate appends) and the rc is backed up
    /// before the first edit. Creating the rc (and `~/.config/fish/`) if absent.
    @discardableResult
    public static func install(_ shell: Shell, homeOverride: URL? = nil) throws -> InstallResult {
        let scriptURL = homeOverride.map {
            $0.appendingPathComponent("Library/Application Support/Harness/shell-integration/harness.\(shell.rawValue)")
        } ?? scriptURL(for: shell)
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script(for: shell).utf8).write(to: scriptURL, options: .atomic)

        let rc = rcURL(for: shell, homeOverride: homeOverride)
        let sourceLine = sourceLine(for: shell, scriptPath: scriptURL)
        let wired = try ShellRCWiring.wire(into: rc, begin: markerBegin, end: markerEnd, body: sourceLine)
        return InstallResult(scriptPath: scriptURL, rcPath: rc, sourceLine: sourceLine,
                             alreadyWired: wired.alreadyWired, rcBackedUp: wired.backedUp)
    }

    /// The `source` line for a shell (fish has no `[ -f ]` test syntax).
    public static func sourceLine(for shell: Shell, scriptPath: URL) -> String {
        switch shell {
        case .bash, .zsh: return "[ -f \"\(scriptPath.path)\" ] && source \"\(scriptPath.path)\""
        case .fish: return "test -f \"\(scriptPath.path)\"; and source \"\(scriptPath.path)\""
        }
    }

    // MARK: - Scripts (runtime source of truth; docs/shell-integration/ mirrors these)

    private static let zshScript = """
    # Harness shell integration for zsh — OSC 133 semantic prompts.
    # Emits OSC 133;A to mark each prompt and OSC 133;D;<exit> to report the previous command's
    # status, so Harness draws the prompt gutter, colors success/failure, and jumps between
    # prompts. Active only inside a Harness pane (the daemon exports $HARNESS).
    if [[ -n "$HARNESS" && "$TERM" != "dumb" ]]; then
      autoload -Uz add-zsh-hook 2>/dev/null
      __harness_precmd() {
        printf '\\033]133;D;%s\\007' "$?"
        printf '\\033]133;A\\007'
      }
      if (( ${+functions[add-zsh-hook]} )); then
        add-zsh-hook precmd __harness_precmd
      else
        precmd_functions+=(__harness_precmd)
      fi
    fi
    """

    private static let bashScript = """
    # Harness shell integration for bash — OSC 133 semantic prompts.
    # Emits OSC 133;A to mark each prompt and OSC 133;D;<exit> to report the previous command's
    # status, so Harness draws the prompt gutter, colors success/failure, and jumps between
    # prompts. Active only inside a Harness pane (the daemon exports $HARNESS).
    if [ -n "$HARNESS" ] && [ "$TERM" != "dumb" ]; then
      __harness_precmd() {
        printf '\\001\\033]133;D;%s\\007\\002' "$?"
      }
      case ";${PROMPT_COMMAND};" in
        *";__harness_precmd;"*) : ;;
        *) PROMPT_COMMAND="__harness_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
      esac
      case "$PS1" in
        *'133;A'*) : ;;
        *) PS1='\\[\\033]133;A\\007\\]'"$PS1" ;;
      esac
    fi
    """

    private static let fishScript = """
    # Harness shell integration for fish — OSC 133 semantic prompts.
    # Emits OSC 133;A to mark each prompt and OSC 133;D;<exit> to report the previous command's
    # status, so Harness draws the prompt gutter, colors success/failure, and jumps between
    # prompts. Active only inside a Harness pane (the daemon exports $HARNESS).
    # Interactive only (kitty/Ghostty do the same): `exit` in a sourced file skips the rest
    # of the file, so scripts and `fish -c` never register the hooks (the vendor_conf.d
    # vehicle would otherwise run this for every fish).
    status is-interactive; or exit
    if set -q HARNESS; and test "$TERM" != dumb
        function __harness_osc133_prompt --on-event fish_prompt
            printf '\\033]133;A\\007'
        end
        function __harness_osc133_postexec --on-event fish_postexec
            printf '\\033]133;D;%s\\007' $status
        end
    end
    """
}
