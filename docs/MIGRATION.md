# Migrating to Harness

Harness has tested migration paths from **Ghostty** (terminal config) and **tmux**
(commands, keybindings, and config). Both rest on first-party code — no plug-ins.

## From Ghostty

Harness reads an existing Ghostty config so your terminal looks the same on day one.

**What's imported** (`TerminalConfigImporter`, covered by `TerminalConfigImporterTests`):
colors (background/foreground/cursor/selection/bold/cursor-text), the 16-color ANSI palette,
font **face**, `background-opacity`, `background-blur`, window padding, cursor style, cursor
blink, copy-on-select, and the default shell.

**What's not imported:** the font **size** is Harness-owned (default 16) — a terminal's size
preference doesn't carry over, only the face does.

**Sources tried** (first match wins):

```
~/.config/ghostty/config
~/.config/ghostty/config.ghostty
~/Library/Application Support/com.mitchellh.ghostty/config
~/Library/Application Support/com.mitchellh.ghostty/config.ghostty
```

Import happens automatically on first run and is re-applied when the source config's
fingerprint changes. Re-import manually any time:

- **Settings → Appearance → Reset to defaults** (re-seeds from the imported config), or
- the `source-config` command (prefix `r` in Multiplexer mode).

Comment lines start with `#`; `#` is **not** stripped from values (so hex colors survive).

## From tmux

Switch to **Multiplexer** mode (Settings → Appearance → Experience). Your muscle
memory works immediately:

- **Prefix key** `Ctrl-A` (change in Settings → Keys, or blank it to disable).
- **Splits / panes** — `prefix %` / `prefix "`, `prefix z` zoom, `prefix x` kill,
  `prefix hjkl`/arrows to move, `prefix o`/`;` cycle, `prefix Space` cycle layouts.
- **Copy mode**, **paste buffers**, **`-t session:window.pane` targets**, **`base-index` /
  `pane-base-index`**, **command prompt** (`prefix :`), **attach/detach**.
- **Detach / reattach** — `harness-cli attach` (one pane) or `harness-cli attach-window` (the
  full split layout, even over ssh); control mode via `harness-cli -CC`.

See the [multiplexer guide](TMUX_GUIDE.md) for the full command and shortcut tour.

### Bringing your `.tmux.conf` over

Two mechanisms, split by what the line *is* (verified by `TmuxMigrationTests`):

**Commands and bindings** run through the same parser as the command prompt. Put your `bind`
lines (and any one-shot commands) in a file and `source-file` it — `#` comments are skipped:

```tmux
# ~/.harness.conf  — commands + bindings only
bind | split-window -h
bind - split-window -v
bind -r H resize-pane -L 2
```

```
:source-file ~/.harness.conf      # from the command prompt (prefix :)
```

Persistent key bindings also live in `keybindings.json` (merged over the defaults); set them
with `harness-cli bind-key` / `unbind-key`, or edit the file directly.

**Options** (`status-left`, `base-index`, mouse, …) are *not* commands — set them with
`harness-cli set-option` (`setw` for window scope), which is the same store the Settings ▸
Advanced page edits:

```bash
harness-cli set-option -g status-left  " #{session_name} "
harness-cli set-option -g status-right " #{cwd_basename} #{time:%H:%M} "
harness-cli set-option -g base-index 1
```

### Deliberate divergences

A few tmux concepts are intentionally *not* reproduced because they conflict with Harness's
value-typed, session-owned-tabs, always-visible-sessions model — grouped sessions and some
session-lifecycle options. These are design choices, not gaps.
