# Fish completion for harness-cli. Kept hand-curated so it stays terse and
# accurate; regenerate after adding a new subcommand or flag.

set -l __harness_cli_subcommands \
    ping list-workspaces list-surfaces list-agents get-snapshot \
    list-sessions list-windows list-panes has-session list-commands \
    new-workspace new-session new-tab new-split \
    select-workspace select-session select-tab \
    close-tab close-session promote-session demote-session \
    send send-keys capture-pane \
    kill-pane swap-pane resize-pane zoom-pane copy-mode \
    rename-tab rename-session rename-workspace \
    detect-agent install-hooks attach notify \
    daemon-stats list-clients detach-client \
    bind-key unbind-key list-keys \
    set-buffer list-buffers show-buffer delete-buffer paste-buffer \
    select-layout next-layout previous-layout rotate-window \
    break-pane join-pane respawn-pane select-pane \
    set-option show-options bind-hook unbind-hook list-hooks display-message \
    install

complete -c harness-cli -f -n "not __fish_seen_subcommand_from $__harness_cli_subcommands" \
    -a "$__harness_cli_subcommands"

# Common flags shared across many subcommands.
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
complete -c harness-cli -n "__fish_seen_subcommand_from bind-hook unbind-hook list-hooks" -l event \
    -a "after-new-tab after-new-session after-kill-tab after-split-pane after-kill-pane after-resize-pane pane-exited client-attached client-detached agent-state-changed notification-posted"
complete -c harness-cli -n "__fish_seen_subcommand_from install-hooks" \
    -a "codex claude-code cursor pi hermes openclaw aider gemini goose"
complete -c harness-cli -n "__fish_seen_subcommand_from list-agents" -l waiting -d "Only agents waiting on you"
complete -c harness-cli -n "__fish_seen_subcommand_from list-agents" -l json    -d "Machine-readable JSON output"
