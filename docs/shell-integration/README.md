# Shell integration (OSC 133 semantic prompts)

Harness understands the **OSC 133** shell-integration protocol. When your shell emits these
marks, Harness records where each prompt begins and whether the command launched from it
succeeded — powering:

- **Jump-to-prompt** navigation (previous/next prompt) in the terminal and copy mode.
- A **prompt gutter** with a success/failure indicator (green for exit 0, red otherwise).

The marks are purely informational — Harness never writes anything back to your shell, and a
shell without integration behaves exactly as before.

## Install

One command — it drops the script under the Harness home and wires a guarded `source` line into
your shell's rc (idempotent, and your rc is backed up first):

```bash
harness-cli install-shell-integration           # auto-detects $SHELL
harness-cli install-shell-integration zsh        # or name one: bash | zsh | fish
harness-cli install-shell-integration all         # all three
```

Then restart your shell (or open a new Harness pane). Each snippet is a no-op outside a Harness
terminal (it checks `$HARNESS`, which the daemon exports into every pane), so it's safe to keep
in your rc everywhere.

**Manual install** — the script is written to
`~/Library/Application Support/Harness/shell-integration/harness.<shell>`; add the matching line
yourself instead:

| Shell | rc file | line to add |
|-------|---------|-------------|
| bash | `~/.bashrc` | `source "<…>/shell-integration/harness.bash"` |
| zsh | `~/.zshrc` | `source "<…>/shell-integration/harness.zsh"` |
| fish | `~/.config/fish/config.fish` | `source "<…>/shell-integration/harness.fish"` |

The copies in `docs/shell-integration/` mirror the runtime scripts (`HarnessCore.ShellIntegration`
is the source of truth).

## What gets emitted

Each snippet emits the two marks Harness consumes:

- `OSC 133 ; A` — **prompt start**, on the line where your shell prompt is drawn.
- `OSC 133 ; D ; <exit>` — **command finished**, carrying the previous command's exit status.

The optional `B` (command-input start) and `C` (output start) delimiters are intentionally not
emitted: they aren't needed for prompt navigation or the status gutter, and leaving them out
keeps the shell hooks minimal and robust. Programs that emit `B`/`C` themselves are parsed and
ignored without harm.
