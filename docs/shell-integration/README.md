# Shell integration (OSC 133 semantic prompts)

Harness understands the **OSC 133** shell-integration protocol. When your shell emits these
marks, Harness records where each prompt begins and whether the command launched from it
succeeded — powering:

- **Jump-to-prompt** navigation (previous/next prompt) in the terminal and copy mode.
- A **prompt gutter** with a success/failure indicator (green for exit 0, red otherwise).

The marks are purely informational — Harness never writes anything back to your shell, and a
shell without integration behaves exactly as before.

## Install

Source the snippet for your shell from its rc file. Each snippet is a no-op outside a Harness
terminal (it checks `$HARNESS`, which the daemon exports into every pane).

| Shell | rc file | line to add |
|-------|---------|-------------|
| bash | `~/.bashrc` | `source "<harness>/docs/shell-integration/harness.bash"` |
| zsh | `~/.zshrc` | `source "<harness>/docs/shell-integration/harness.zsh"` |
| fish | `~/.config/fish/config.fish` | `source "<harness>/docs/shell-integration/harness.fish"` |

(The shipped app installs these snippets alongside `harness-cli`; use that path in place of
`<harness>` once installed.)

## What gets emitted

Each snippet emits the two marks Harness consumes:

- `OSC 133 ; A` — **prompt start**, on the line where your shell prompt is drawn.
- `OSC 133 ; D ; <exit>` — **command finished**, carrying the previous command's exit status.

The optional `B` (command-input start) and `C` (output start) delimiters are intentionally not
emitted: they aren't needed for prompt navigation or the status gutter, and leaving them out
keeps the shell hooks minimal and robust. Programs that emit `B`/`C` themselves are parsed and
ignored without harm.
