# Harness keybindings

Harness keybindings are data. User overrides live in `~/Library/Application Support/Harness/keybindings.json`; removing an override restores the default binding.

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
| `l` | `select-pane -l` (last / most-recently-active pane) |
| `Left` / `Right` / `Up` / `Down` | `select-pane -L` / `-R` / `-U` / `-D` |
| `S-Left` / `S-Right` / `S-Up` / `S-Down` | `resize-pane -L 5` / `-R 5` / `-U 3` / `-D 3` (repeatable — hold under the prefix) |
| `q` | `display-panes` (overlay numbers; press a digit to jump) |
| `m` / `M` | mark / unmark the active pane (`join-pane` source) |
| `j` | `join-pane` (join the marked pane into the active one) |
| `S` | toggle `synchronize-panes` for the tab |
| `n` / `p` | `next-window` / `previous-window` |
| `,` | `rename-window` (interactive) |
| `0`–`9` | `select-workspace <n>` |
| `[` | `copy-mode` |
| `d` | `detach-client` |
| `?` | `show-cheatsheet` |
| `r` | `source-config` (re-import terminal config) |
| `:` | open the command prompt |

## Copy-mode key table

Copy mode is fully rebindable via `bind-key -T copy-mode <spec> <command>`. Defaults follow `mode-keys vi`.

| Key | Action |
|---|---|
| `h` / `l` | Cursor left / right |
| `j` / `k` | Cursor down / up |
| `0` / `$` | Line start / end |
| `g` / `G` | Top / bottom |
| `[` / `]` | Jump to previous / next OSC 133 prompt mark (requires shell integration) |
| `w` / `b` | Next / previous word |
| `PageUp` / `PageDown` | Page up / down |
| `C-u` / `C-d` | Half page up / down |
| `v` / `V` / `C-v` | Char / line / rectangle (block) selection |
| `/` / `?` | Search forward / backward |
| `n` / `N` | Next / previous match |
| `y` / `Enter` | Yank selection → clipboard + daemon paste buffer; exit |
| `p` | Paste most recent buffer into the surface; exit |
| `q` / `Escape` | Exit copy mode |

Copy-mode is rebindable: `bind-key -T copy-mode <key> <command>` where `<command>` is `copy-mode -X <action>` (e.g. `copy-pipe "pbcopy"`).

## Global menu shortcuts

These are fixed `NSMenuItem` bindings defined in `MainMenuBuilder` — not prefix-table entries and not rebindable via `keybindings.json`.

| Action | Shortcut |
|--------|----------|
| New tab | `⌘T` |
| Close tab | `⌘W` |
| Split horizontal / vertical | `⌘D` / `⌘⇧D` |
| Command palette | `⌘K` |
| Command prompt | `⌘;` |
| Toggle sidebar | `⌘\` |
| Jump to notification | `⌘⇧U` |
| Settings | `⌘,` |
| Enter Full Screen (native, macOS Space transition) | `⌃⌘F` |
| Toggle Fast Full Screen (non-native, instant fill, no Space animation) | `⌃⌘⇧F` |

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
- Harness writes the file atomically whenever a binding changes.
