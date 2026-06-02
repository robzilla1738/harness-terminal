import Foundation

/// Generates static shell-completion scripts for `harness-cli` from the canonical
/// `CLICommandCatalog`, so the command list is defined once and the fish/zsh/bash scripts can
/// never drift. Used by `harness-cli completions <shell>` and by `ShellCompletionInstaller`
/// (the `install` flow), which now emit the identical fish script.
public enum CompletionGenerator {
    /// The completion script for `shell`, ready to print to stdout or write to a completion dir.
    public static func script(for shell: ShellIntegration.Shell) -> String {
        switch shell {
        case .fish: return fish()
        case .zsh: return zsh()
        case .bash: return bash()
        }
    }

    // MARK: - fish

    private static func fish() -> String {
        let names = CLICommandCatalog.canonicalNames.joined(separator: " ")
        let jsonNames = CLICommandCatalog.jsonCommands.map(\.name).joined(separator: " ")
        // Subcommand names come from the catalog; the per-argument hints below are fish-specific
        // and intentionally curated (value sets for flags). `--json`/`--pretty` are attached to
        // exactly the catalog's JSON-capable commands.
        return """
        # Fish completion for harness-cli — generated from CLICommandCatalog by
        # CompletionGenerator (do not hand-edit; run `harness-cli completions fish`).

        set -l __harness_cli_subcommands \(names)

        complete -c harness-cli -f -n "not __fish_seen_subcommand_from $__harness_cli_subcommands" \\
            -a "$__harness_cli_subcommands"

        complete -c harness-cli -n "__fish_seen_subcommand_from new-tab new-session" -l workspace -d "Workspace name or UUID"
        complete -c harness-cli -n "__fish_seen_subcommand_from new-tab new-session" -l cwd       -d "Working directory"
        complete -c harness-cli -n "__fish_seen_subcommand_from new-split" -l tab        -d "Tab UUID"
        complete -c harness-cli -n "__fish_seen_subcommand_from new-split" -l direction  -a "horizontal vertical"
        complete -c harness-cli -n "__fish_seen_subcommand_from select-pane" -l pane     -d "Pane UUID"
        complete -c harness-cli -n "__fish_seen_subcommand_from select-pane" -l dir      -a "L R U D"
        complete -c harness-cli -n "__fish_seen_subcommand_from attach respawn-pane paste-buffer notify send send-keys capture-pane copy-mode detect-agent" -l surface -d "Surface UUID"
        complete -c harness-cli -n "__fish_seen_subcommand_from attach" -l detach-keys   -d "Detach key sequence (e.g. C-a d)"
        complete -c harness-cli -n "__fish_seen_subcommand_from respawn-pane" -l clear-history -d "Drop scrollback on respawn"
        complete -c harness-cli -n "__fish_seen_subcommand_from select-layout" -l tab     -d "Tab UUID"
        complete -c harness-cli -n "__fish_seen_subcommand_from select-layout" -l layout  -a "even-horizontal even-vertical main-horizontal main-vertical tiled"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-buffer" -l name      -d "Buffer name"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-buffer" -l data      -d "Inline data"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-buffer" -l stdin     -d "Read data from stdin"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-option" -s g -d "Global scope"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-option" -s s -d "Session scope"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-option" -s t -d "Tab scope"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-option" -s p -d "Pane scope"
        complete -c harness-cli -n "__fish_seen_subcommand_from set-option" -s w -d "Workspace scope"
        complete -c harness-cli -n "__fish_seen_subcommand_from bind-key unbind-key list-keys" -s T -d "Key table" -a "root prefix copy-mode command"
        complete -c harness-cli -n "__fish_seen_subcommand_from bind-hook unbind-hook list-hooks" -l event \\
            -a "after-new-tab after-new-session after-kill-tab after-split-pane after-kill-pane after-resize-pane pane-exited client-attached client-detached agent-state-changed notification-posted"
        complete -c harness-cli -n "__fish_seen_subcommand_from install-hooks" \\
            -a "codex claude-code cursor grok opencode pi hermes openclaw"
        complete -c harness-cli -n "__fish_seen_subcommand_from completions" -a "zsh fish bash" -d "Shell"
        complete -c harness-cli -n "__fish_seen_subcommand_from list-agents" -l waiting -d "Only agents waiting on you"
        complete -c harness-cli -n "__fish_seen_subcommand_from \(jsonNames)" -l json   -d "Machine-readable JSON output"
        complete -c harness-cli -n "__fish_seen_subcommand_from \(jsonNames)" -l pretty -d "Indent JSON output (with --json)"
        """
    }

    // MARK: - zsh

    private static func zsh() -> String {
        let entries = CLICommandCatalog.commands.map { cmd in
            "    '\(zshEscape(cmd.name)):\(zshEscape(cmd.summary))'"
        }.joined(separator: "\n")
        return """
        #compdef harness-cli
        # zsh completion for harness-cli — generated from CLICommandCatalog by
        # CompletionGenerator (do not hand-edit; run `harness-cli completions zsh`).
        # Use either way: source it from ~/.zshrc after `compinit`
        #   (e.g. `source <(harness-cli completions zsh)`), or save it as `_harness-cli`
        #   in a directory on your $fpath.

        _harness_cli() {
          local -a __harness_commands
          __harness_commands=(
        \(entries)
          )
          if (( CURRENT == 2 )); then
            _describe -t commands 'harness-cli command' __harness_commands
            return
          fi
          case "${words[2]}" in
            completions) (( CURRENT == 3 )) && compadd zsh fish bash ;;
          esac
        }

        # Run when autoloaded from $fpath (funcstack is this file's function); otherwise the file
        # was sourced, so register the function with the completion system. Guard compdef so a
        # source before `compinit` is a harmless no-op rather than an error.
        if [ "${funcstack[1]:-}" = "_harness_cli" ] || [ "${funcstack[1]:-}" = "_harness-cli" ]; then
          _harness_cli "$@"
        elif (( $+functions[compdef] )); then
          compdef _harness_cli harness-cli
        fi
        """
    }

    /// Escape a value for a single-quoted zsh array element (`'…'`). Replaces each `'` with the
    /// standard `'\\''` close/escape/reopen sequence so apostrophes in summaries are safe.
    private static func zshEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - bash

    private static func bash() -> String {
        let names = CLICommandCatalog.canonicalNames.joined(separator: " ")
        return """
        # bash completion for harness-cli — generated from CLICommandCatalog by
        # CompletionGenerator (do not hand-edit; run `harness-cli completions bash`).
        _harness_cli() {
          local cur="${COMP_WORDS[COMP_CWORD]}"
          local commands="\(names)"
          if [ "$COMP_CWORD" -eq 1 ]; then
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
          fi
          if [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = "completions" ]; then
            COMPREPLY=( $(compgen -W "zsh fish bash" -- "$cur") )
            return 0
          fi
        }
        complete -F _harness_cli harness-cli
        """
    }
}
