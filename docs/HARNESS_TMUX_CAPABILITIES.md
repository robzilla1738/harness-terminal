# Harness tmux-style capabilities

This guide is the printable setup and usage path for Harness's tmux-style features:
sessions, tabs, panes, copy mode, paste buffers, attach from another terminal, key
bindings, shell integration, and agent notifications.

Harness is not tmux and does not wrap tmux. The terminal engine, daemon, session
model, compositor, and CLI are first-party Harness components. The naming is
familiar where it helps: a Harness tab is the same idea as a tmux window, and a
Harness pane is a split terminal.

## 1. Five-minute setup

Use this path for a fresh install.

1. Install Harness.

   Download the DMG, drag `Harness.app` to Applications, and launch it once.
   Harness starts the background daemon automatically.

2. Pick the Harness controls experience.

   Open **Settings > Terminal > Experience** and choose **Full Terminal** or
   **Agent Workspace**.

   New installs can start in **Plain Terminal**, which intentionally hides the
   prefix layer and status line. Plain mode is a normal terminal. Full Terminal
   turns on the prefix key, status line, copy mode, paste buffers, panes, and
   command prompt.

3. Install the CLI.

   From the app bundle:

   ```bash
   /Applications/Harness.app/Contents/MacOS/harness-cli install
   ```

   If you built from source:

   ```bash
   .build/release/harness-cli install
   ```

   Add the printed bin path to your shell profile if needed:

   ```bash
   export PATH="$HOME/Library/Application Support/Harness/bin:$PATH"
   ```

4. Verify the daemon and CLI.

   ```bash
   harness-cli ping
   harness-cli list-sessions
   harness-cli list-windows
   ```

   A healthy install prints `pong` and shows your current sessions/tabs.

5. Install shell integration.

   ```bash
   harness-cli install-shell-integration
   ```

   Open a new Harness pane after installing. This enables prompt marks, copy-mode
   prompt jumps, and the command success/failure gutter.

6. Optional: install agent hooks.

   ```bash
   harness-cli install-hooks claude-code
   harness-cli install-hooks codex
   ```

   Use the agent you run: `claude-code`, `codex`, `cursor`, `pi`, `hermes`, or
   `openclaw`. Harness also detects several agents without hooks.

## 2. Mental model

| Harness term | tmux-style idea | What it means |
| --- | --- | --- |
| Workspace | Top-level project group | A named group of sessions. |
| Session | Session | A sidebar row with its own tabs. |
| Tab | Window | One terminal tab with a split tree. |
| Pane | Pane | One PTY-backed terminal inside a tab. |
| Surface | PTY identity | The daemon-owned terminal behind a pane. |

The daemon owns session state and every PTY. The app and `harness-cli` are
clients. That is why shells keep running after the app quits, why another Harness
window can reattach, and why `harness-cli attach-window` can render a full split
layout in a plain terminal.

## 3. Prefix key

Default prefix: **Ctrl-A**.

When this guide says `prefix %`, press `Ctrl-A`, release it, then press `%`.

| Key | Action |
| --- | --- |
| `prefix ?` | Show the live cheatsheet for your current bindings. |
| `prefix :` | Open the command prompt. |
| `prefix d` | Detach the current client. |
| `prefix [` | Enter copy mode. |

Change the prefix in **Settings > Keys**. If the prefix does nothing, check that
the app is in **Full Terminal** or **Agent Workspace**, or that
Harness controls are set to On.

## 4. Panes and layouts

| Shortcut | What it does |
| --- | --- |
| `prefix %` | Split side-by-side, new pane on the right. |
| `prefix "` | Split top/bottom, new pane below. |
| `prefix Left/Right/Up/Down` | Move focus to the neighboring pane. |
| `prefix o` | Cycle to the next pane. |
| `prefix ;` | Cycle to the previous pane. |
| `prefix l` | Jump to the last active pane. |
| `prefix z` | Zoom or unzoom the active pane. |
| `prefix x` | Kill the active pane. |
| `prefix Shift-Left/Right/Up/Down` | Resize the pane. Hold under prefix to repeat. |
| `prefix q` | Show pane numbers, then press a number to jump. |
| `prefix Space` | Cycle layout presets. |
| `prefix S` | Toggle synchronized input to every pane in the tab. |

macOS shortcuts also work:

| Shortcut | Action |
| --- | --- |
| `Cmd-D` | Split side-by-side. |
| `Cmd-Shift-D` | Split top/bottom. |
| `Cmd-W` | Close the active tab. |

Layout commands:

```text
:select-layout tiled
:select-layout even-horizontal
:select-layout even-vertical
:select-layout main-horizontal
:select-layout main-vertical
```

From the shell:

```bash
harness-cli new-split --tab <tab-uuid> --direction horizontal
harness-cli resize-pane --pane <pane-uuid> --dir L --amount 5
harness-cli zoom-pane --pane <pane-uuid>
```

## 5. Tabs, sessions, and workspaces

Harness tabs are tmux-style windows. Sessions live in the sidebar and remain
visible instead of being hidden behind an attach prompt.

| Shortcut | What it does |
| --- | --- |
| `prefix c` | New tab. |
| `prefix n` | Next tab. |
| `prefix p` | Previous tab. |
| `prefix ,` | Rename current tab. |
| `Cmd-T` | New tab. |
| `Cmd-1` through `Cmd-9` | Jump to tab 1 through 9. |
| `Cmd-Shift-[` / `Cmd-Shift-]` | Previous / next tab. |
| `Cmd-Shift-N` | New workspace. |

Useful CLI commands:

```bash
harness-cli new-workspace --name api
harness-cli new-session --workspace Default --cwd ~/Code/project
harness-cli new-tab --workspace Default --cwd ~/Code/project
harness-cli rename-session --session <uuid> --name backend
harness-cli list-sessions
harness-cli list-windows
harness-cli list-panes
```

Persistence:

- Full and Agent modes are designed for persistent work.
- A session survives a clean quit when global keep-on-quit is on or the session is
  pinned.
- Pin or unpin a session from the sidebar context menu, or use:

```bash
harness-cli promote-session --session <uuid>
harness-cli demote-session --session <uuid>
```

## 6. Copy mode, search, and paste buffers

Enter copy mode with `prefix [`.

| Key | Action |
| --- | --- |
| `h` / `j` / `k` / `l` | Move left/down/up/right. |
| `0` / `$` | Start / end of line. |
| `w` / `b` | Next / previous word. |
| `g` / `G` | Top / bottom of history. |
| `PageUp` / `PageDown` | Page through history. |
| `C-u` / `C-d` | Half-page up / down. |
| `[` / `]` | Previous / next shell prompt. Requires shell integration. |
| `v` | Start character selection. |
| `V` | Start line selection. |
| `C-v` | Start rectangle selection. |
| `/` then text | Search forward. |
| `?` then text | Search backward. |
| `n` / `N` | Next / previous search result. |
| `y` or `Enter` | Yank to clipboard and paste buffer, then exit. |
| `p` | Paste latest buffer into the pane. |
| `q` or `Escape` | Exit copy mode. |

Paste buffer commands:

```bash
harness-cli set-buffer --data "deploy staging"
harness-cli list-buffers
harness-cli show-buffer
harness-cli paste-buffer --surface "$HARNESS_SURFACE" --bracketed
harness-cli save-buffer notes.txt
harness-cli load-buffer notes.txt
```

## 7. Attach from another terminal or over SSH

Install the CLI on the machine that is running Harness, then use:

```bash
harness-cli attach-window
harness-cli attach-window --session work
harness-cli attach-window --tab <tab-uuid>
```

`attach-window` renders the whole tab: splits, borders, status line, active pane,
copy mode, and mouse support. It works in a plain terminal because the Harness
client composites the daemon-owned pane grids.

Inside `attach-window`:

| Key | Action |
| --- | --- |
| `prefix %` / `prefix "` | Split. |
| `prefix h/j/k/l` | Select pane. |
| `prefix o` / `prefix ;` | Cycle pane. |
| `prefix z` | Zoom. |
| `prefix x` | Kill pane. |
| `prefix c` | New tab. |
| `prefix n` / `prefix p` | Next / previous tab. |
| `prefix d` | Detach the attached client. |
| `prefix [` | Copy mode. |

Detach keys default to `Ctrl-A d`. Override them:

```bash
harness-cli attach-window --detach-keys "C-b d"
```

Single-pane attach is also available:

```bash
harness-cli attach --surface <surface-uuid>
```

## 8. Command prompt and scripting

Open the prompt with `prefix :` or `Cmd-;`. It accepts the same command grammar as
key bindings and hooks:

```text
:split-window -h
:split-window -v
:select-layout tiled
:display-message "#{session_name}:#{window_index}.#{pane_index}"
:bind-key C-x x kill-pane
:bind-key -T copy-mode y copy-mode -X copy-selection-and-cancel
```

From a shell:

```bash
harness-cli send-keys --surface "$HARNESS_SURFACE" --keys "git status Enter"
harness-cli capture-pane --surface "$HARNESS_SURFACE"
harness-cli pipe-pane --surface "$HARNESS_SURFACE" "tee pane.log"
harness-cli display-message '#{cwd_basename}'
harness-cli wait-for -S build-ready
```

## 9. Key binding customization

Bindings persist in:

```text
~/Library/Application Support/Harness/keybindings.json
```

Examples:

```bash
# Bind Ctrl-X q to detach.
harness-cli bind-key C-x q detach-client

# Move kill-pane off x and onto Ctrl-X x.
harness-cli unbind-key x
harness-cli bind-key C-x x kill-pane

# Bind a multi-command workflow.
harness-cli bind-key C-x s "split-window -h ; copy-mode"

# Copy-mode binding.
harness-cli bind-key -T copy-mode Y "copy-mode -X copy-selection-and-cancel"

# List current bindings.
harness-cli list-keys
harness-cli list-keys -T copy-mode
```

Key syntax:

| Form | Meaning |
| --- | --- |
| `C-a` | Control-A. |
| `M-x` | Option/Alt/Meta-X. |
| `S-Left` | Shift-Left. |
| `Cmd-,` | Command-comma. |
| `PageUp`, `Enter`, `Escape`, `F1` | Named keys. |

## 10. Status line, mouse, and options

Harness supports tmux-style options through `set-option` and `show-options`.

```bash
harness-cli show-options -g
harness-cli set-option -g status on
harness-cli set-option -g mouse on
harness-cli set-option -g mode-keys vi
harness-cli set-option -g history-limit 20000
harness-cli set-option -g base-index 1
harness-cli set-option -g pane-base-index 1
```

Common options:

| Option | Default | What it controls |
| --- | --- | --- |
| `status` | `on` | Bottom status line. |
| `status-left` / `status-right` | built in | Status content. |
| `mouse` | `on` | Mouse reporting and pane-click selection. |
| `mode-keys` | `vi` | Copy-mode key style. |
| `set-clipboard` | `on` | Yank to macOS pasteboard. |
| `history-limit` | `10000` | Scrollback cap. |
| `base-index` | `0` | First tab index. |
| `pane-base-index` | `0` | First pane index. |

## 11. Shell integration

Shell integration adds OSC 133 prompt marks. It is optional, but it makes the
tmux-style workflow much better.

Install:

```bash
harness-cli install-shell-integration
harness-cli install-shell-integration all
```

What it enables:

- Prompt gutter: green for exit 0, red for non-zero.
- Copy-mode prompt jumps with `[` and `]`.
- Prompt-aware status and navigation.

The installed snippet is guarded by `$HARNESS`, so it is inert outside a Harness
pane. It supports bash, zsh, and fish.

## 12. Agent notifications

Harness watches coding agents in panes and can surface approval or completion
states through desktop notifications, the sidebar bell, pane rings, and
`Cmd-Shift-U`.

Install hooks where the agent supports hooks:

```bash
harness-cli install-hooks claude-code
harness-cli install-hooks codex
harness-cli install-hooks cursor
harness-cli install-hooks pi
harness-cli install-hooks hermes
harness-cli install-hooks openclaw
```

Smoke test from inside a Harness pane:

```bash
harness-cli notify --surface "$HARNESS_SURFACE" --title Agent --body "Needs approval"
```

Then press `Cmd-Shift-U` to jump to the waiting tab.

If macOS banners do not appear, open **System Settings > Notifications > Harness**
and allow notifications. The in-app waiting state still works even when macOS
banners are denied.

## 13. Out-of-box troubleshooting

| Symptom | Fix |
| --- | --- |
| `harness-cli: command not found` | Run `harness-cli install`, then add `$HOME/Library/Application Support/Harness/bin` to PATH. |
| `harness-cli ping` does not print `pong` | Launch Harness once, or run the bundled CLI from `/Applications/Harness.app/Contents/MacOS/harness-cli`. |
| Prefix does nothing | Choose Full Terminal or Agent Workspace in Settings > Terminal > Experience. |
| Prompt jumps do nothing | Run `harness-cli install-shell-integration`, then open a new pane. |
| Agent hook does not notify | Run `harness-cli install-hooks <agent>`, start the agent in a new Harness pane, and verify `$HARNESS_SURFACE` is set. |
| Desktop banners do not show | Allow Harness in macOS notification settings. |
| Attach over SSH cannot find sessions | SSH into the same macOS user account that owns the Harness daemon and run `harness-cli ping`. |

## 14. One-page cheat sheet

```text
Setup
  1. Settings > Terminal > Experience > Full Terminal or Agent Workspace
  2. harness-cli install
  3. harness-cli ping
  4. harness-cli install-shell-integration
  5. harness-cli install-hooks <agent>      optional

Prefix
  Ctrl-A is the default prefix. prefix ? opens the live cheatsheet.

Panes
  prefix %      split side-by-side
  prefix "      split top/bottom
  prefix arrows focus pane
  prefix o/;    next / previous pane
  prefix l      last pane
  prefix z      zoom
  prefix x      kill pane
  prefix q      pane numbers
  prefix Space  next layout
  prefix S      synchronize panes

Tabs
  prefix c      new tab
  prefix n/p    next / previous tab
  prefix ,      rename tab
  Cmd-T         new tab
  Cmd-1..9      jump to tab

Copy mode
  prefix [      enter
  hjkl          move
  v / V / C-v   select char / line / rectangle
  / or ?        search
  n / N         next / previous match
  [ / ]         previous / next prompt
  y or Enter    copy selection and exit
  p             paste latest buffer
  q or Esc      exit

Attach
  harness-cli attach-window
  harness-cli attach-window --session work
  prefix d      detach

Command
  prefix :      command prompt
  Cmd-;         command prompt
  Cmd-K         command palette
```
