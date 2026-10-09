# Harness keybindings

Harness keybindings are data. User overrides live in `~/Library/Application Support/Harness/keybindings.json`; removing an override restores the default binding.

## Key spec syntax

A `KeySpec` is `[modifier-]…<key>`:

- Modifier prefixes (case-insensitive): `C-` (control), `M-` (option / alt / meta), `S-` (shift, only meaningful on non-printable keys), `Cmd-` (command).
- Base keys are the literal character (`a`, `[`, `?`) or one of the named keys: `Up`, `Down`, `Left`, `Right`, `Tab`, `Enter`, `Backspace`, `Escape`, `Home`, `End`, `PageUp`, `PageDown`, `F1` … `F12`.
- Examples: `c`, `C-a`, `M-1`, `S-Tab`, `C-M-x`, `Cmd-,`.

## Option key (⌥) behavior

By default the Option key **types characters** — whatever your macOS keyboard layout
produces (`@`, `|`, `é`, dead keys like ⌥e e → é), matching Terminal.app, iTerm2, Ghostty,
and kitty. If you rely on Option as Meta for readline/emacs (`alt-b`, `alt-f` → `ESC b`,
`ESC f`), switch it in **Settings ▸ Keys ▸ Option key**: *Meta* (Esc+key), or *Left Meta* / *Right
Meta* to keep one Option key for Meta and the other for typing characters (the Ghostty
`macos-option-as-alt` shape; an imported Ghostty config carries the setting over).

Regardless of mode: ⌥←/⌥→ word motion and ⌥⌫ word delete keep their Esc encodings (macOS
terminal convention), Ctrl+Option combos always take the escape-code path, and `M-…`
entries in the key tables above are unaffected — table bindings match the physical
modifiers, not the typed character.

## Default `prefix` table

Trigger: the prefix key (default `ctrl-a`, configurable via `settings.prefixKey`). After the prefix fires, the next keystroke resolves against this table.

| Key | Command |
|---|---|
| `c` | `new-window` |
| `%` | `split-window -h` (side-by-side) |
| `"` | `split-window -v` (top/bottom) |
| `x` | `kill-pane` |
| `z` | `zoom-pane` |
| `Space` | `next-layout` (cycle the tab's layouts) |
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
| `(` / `)` | `previous-session` / `next-session` |
| `,` | `rename-window` (interactive) |
| `0`–`9` | `select-workspace <n>` |
| `[` | `copy-mode` |
| `d` | `detach-client` |
| `?` | `show-cheatsheet` |
| `r` | `source-config` (re-import terminal config) |
| `:` | open the command prompt |

> **Repeatable bindings (`bind -r`):** a binding created with `bind-key -r` keeps the prefix
> armed after it fires, so the key repeats without re-pressing the prefix (the resize bindings
> above ship this way). The window is the `repeat-time` option (ms, default `500`):
> `:set-option -g repeat-time 750`. Bind your own from the `:` prompt or `keybindings.json`,
> e.g. `:bind-key -r -T prefix C-j resize-pane -D 5`.

## Copy-mode key table

Copy mode is fully rebindable via `bind-key -T copy-mode <spec> <command>`. Defaults follow `mode-keys vi`.

| Key | Action |
|---|---|
| `h` / `l` | Cursor left / right |
| `j` / `k` | Cursor down / up (the arrow keys work too) |
| `0` / `$` | Line start / end |
| `g` / `G` | Top / bottom |
| `[` / `]` | Jump to previous / next OSC 133 prompt mark (requires shell integration) |
| `w` / `b` / `e` | Next word / previous word / end of next word (split on `word-separators`) |
| `W` / `B` / `E` | The same, whitespace-delimited |
| `^` | Back to indentation |
| `H` / `M` / `L` | Top / middle / bottom of the window |
| `f` / `F` / `t` / `T` | Jump to (or before) the next typed character, forward / backward; `;` / `,` repeat / reverse |
| `PageUp` / `PageDown` | Page up / down |
| `C-u` / `C-d` | Half page up / down |
| `v` / `V` / `C-v` | Char / line / rectangle (block) selection |
| `o` | Other end of the selection |
| `/` / `?` | Search forward / backward |
| `n` / `N` | Next / previous match |
| `y` / `Enter` | Yank selection → clipboard + daemon paste buffer; exit |
| `p` | Paste most recent buffer into the surface; exit |
| `q` / `Escape` | Exit copy mode |

With `set-option mode-keys emacs`, copy mode uses an emacs table instead (`C-b`/`C-f`/`C-n`/`C-p`, `C-a`/`C-e`, `M-f`/`M-b`, `M-<`/`M->`, `C-Space` to select, `M-w` to copy), equally rebindable.

Copy-mode is rebindable: `bind-key -T copy-mode <key> <command>` (or `-T copy-mode-vi`, an alias) where `<command>` is `copy-mode -X <action>` (e.g. `copy-pipe "pbcopy"`).

## Global menu shortcuts

These are `NSMenuItem` bindings defined in `MainMenuBuilder`, not prefix-table entries. Every menu command is also in the command palette (⌘K), where right-click ▸ Change Shortcut… gives it a shortcut of your own. Help ▸ Keyboard Shortcuts (`⌘/`) lists every key from every source, searchable.

| Action | Shortcut |
|--------|----------|
| New window (a new session in it) | `⌘N` |
| New session | `⇧⌘N` |
| New tab | `⌘T` |
| Reopen closed tab | `⇧⌘T` |
| Close the focused pane (the tab when it's the only pane); asks only when a program other than the shell is running | `⌘W` |
| Close the whole tab | `⌥⌘W` |
| Close the session | `⇧⌘W` |
| Switch to tab 1–9 | `⌘1` … `⌘9` |
| Previous / next tab | `⇧⌘[` / `⇧⌘]` |
| Select pane left / right / above / below | `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` |
| Previous / next pane | `⌘[` / `⌘]` |
| Zoom pane | `⇧⌘↩` |
| Equalize splits | `⌃⌘=` |
| Find / next / previous | `⌘F` / `⌘G` / `⇧⌘G` |
| Keyboard Shortcuts (everything, searchable) | `⌘/` |
| Split horizontal / vertical | `⌘D` / `⌘⇧D` |
| Command palette | `⌘K` |
| Command prompt | `⌘;` |
| Previous prompt (OSC 133) | `⌘↑` |
| Next prompt (OSC 133) | `⌘↓` |
| Select last command output (OSC 133) | `⌘⇧A` |
| Toggle sidebar (title-bar tabs ↔ sidebar mode) | `⌘\` |
| Switch session (the sessions popover) | `⌃⌘S` |
| Workspace Overview (live tile grid) | `⌘⇧O` |
| Jump to notification | `⌘⇧U` |
| Tab peek | `⌃⌘P` |
| Give a palette action its own shortcut | right-click it in the palette ▸ Change Shortcut… |
| Insert Path (cursor popup: fuzzy search, ↩ insert, →/Tab open folder, ← parent, Esc dismiss) | `⌥⌘I` |
| Go to Directory (folder browser on the pane's daemon: ↩ cd, ⌘↩ new tab, ⌥↩ insert path, → open, ← up) | `⌥⌘G` |
| Increase / decrease / reset font size | `⌘+` (or `⌘=`) / `⌘-` / `⌘0` |
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
# Prefix then d detaches (keys are bound in the prefix table by default)
harness-cli bind-key d detach-client

# Move "kill pane" off `x` to `X`
harness-cli unbind-key x
harness-cli bind-key X kill-pane

# Multi-step: split + immediately enter copy mode
harness-cli bind-key s "split-window -h ; copy-mode"

# A key without the prefix: the root table
harness-cli bind-key -T root M-Left select-pane -L
```

The running app picks up keybindings.json changes on its own.

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
