# Harness keybindings

Every binding is data. The defaults live in `KeyTableSet.defaults` in `HarnessCore/Keybindings/KeyTable.swift`; user overrides go in `~/Library/Application Support/Harness/keybindings.json`. On load Harness merges defaults under user changes, so removing an entry from your file falls back to the default rather than disabling the action.

## Key spec syntax

A `KeySpec` is `[modifier-]…<key>`:

- Modifier prefixes (case-insensitive): `C-` (control), `M-` (option / alt / meta), `S-` (shift, only meaningful on non-printable keys), `Cmd-` (command).
- Base keys are the literal character (`a`, `[`, `?`) or one of the named keys: `Up`, `Down`, `Left`, `Right`, `Tab`, `Enter`, `Backspace`, `Escape`, `Home`, `End`, `PageUp`, `PageDown`, `F1` … `F12`.
- Examples: `c`, `C-a`, `M-1`, `S-Tab`, `C-M-x`, `Cmd-,`.

## Default `prefix` table

Trigger: the prefix key (default `ctrl-a`, configurable via `settings.prefixKey`). After the prefix fires, the next keystroke resolves against this table.

| Key | Command |
|---|---|
| `c` | `new-window` |
| `%` | `split-window -h` (side-by-side) |
| `"` | `split-window -v` (top/bottom) |
| `x` | `kill-pane` |
| `z` | `zoom-pane` |
| `&` | `kill-window` |
| `o` / `;` | `select-pane next` / `previous` |
| `Left` / `Right` / `Up` / `Down` | `select-pane -L` / `-R` / `-U` / `-D` |
| `S-Left` / `S-Right` / `S-Up` / `S-Down` | `resize-pane -L 5` / `-R 5` / `-U 3` / `-D 3` |
| `n` / `p` | `next-window` / `previous-window` |
| `,` | `rename-window` (interactive) |
| `0`–`9` | `select-workspace <n>` |
| `[` | `copy-mode` |
| `d` | `detach-client` |
| `?` | `show-cheatsheet` |
| `r` | `source-config` (re-import Ghostty) |
| `:` | open the command prompt |

## Copy-mode key table

`CopyModeViewController` interprets these natively today; the entries in `KeyTableSet.defaults.copy-mode` are advisory and let `list-keys -T copy-mode` show what's bound. A future overlay rewrite will rebind through `bind-key -T copy-mode <spec> <command>`.

| Key | Action |
|---|---|
| `h` / `l` | Cursor left / right |
| `j` / `k` | Cursor down / up |
| `0` / `$` | Line start / end |
| `g` / `G` | Top / bottom |
| `w` / `b` | Next / previous word |
| `v` / `V` | Char / line selection |
| `/` / `?` | Search forward / backward |
| `n` / `N` | Next / previous match |
| `y` / `Enter` | Yank selection → clipboard + daemon paste buffer; exit |
| `p` | Paste most recent buffer into the surface; exit |
| `q` / `Escape` | Exit copy mode |

## Command prompt

- Open: `prefix :` or `Cmd+;`.
- Accepts any command (e.g. `bind-key -T prefix S split-window -v ; reload-keybindings`).
- History: `↑` / `↓`.
- Escape closes without executing.

## Customizing

```bash
# Bind C-x q to detach
harness-cli bind-key C-x q detach-client

# Move "kill pane" off `x` to `C-x x`
harness-cli unbind-key x
harness-cli bind-key C-x x kill-pane

# Multi-step: split + immediately enter copy mode
harness-cli bind-key C-x s "split-window -h ; copy-mode"

# Apply immediately in the running app
harness-cli display-message "reload"  # (the app polls keybindings.json on `reload-keybindings`)
```

In the app, the `:` prompt accepts the same syntax:

```
:bind-key -T prefix S new-session
:reload-keybindings
```

## Persistence

- File: `~/Library/Application Support/Harness/keybindings.json`
- Format: JSON; `tables` is an array of `{id, bindings: [{spec, command, note}]}` entries
- Merge: on load, defaults fill in any missing slots; deleting a stored binding restores the default
- Atomic writes on every change via `KeybindingsStore.save`
