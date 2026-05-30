# Harness ↔ tmux capability parity

Harness is a native macOS terminal multiplexer with its own verbs, hierarchy
(workspace → session → tab → pane), and UI — but its **capability** target is a
1:1 superset of tmux. This ledger tracks where each tmux capability stands in
Harness. UI and strings never say "tmux"; the columns map tmux muscle-memory to
the Harness equivalent.

Status legend:

- ✅ **Done** — implemented and wired end-to-end (GUI + CLI/compositor where applicable).
- 🟰 **Harness-equivalent** — the capability exists under Harness's own model/verb.
- 🟡 **Partial** — works in one surface or with a documented limitation.
- 🛣️ **Roadmap** — designed, not yet implemented; tracked below with rationale.

The daemon (`HarnessDaemon`) is the single source of truth: every layout
mutation, the active pane, option-driven behavior, hook firing, and the spawn
environment are server-side. `Harness.app` and `harness-cli` are thin clients.

---

## Sessions, windows, panes

| tmux | Harness | Status |
|------|---------|--------|
| session | session (sidebar row, own tab bar) | 🟰 |
| window | tab | 🟰 |
| pane | pane (`PaneNode` leaf) | 🟰 |
| `new-session` / `new-window` | `new-session` / `new-tab` (`Command.newSession`/`.newWindow`) | ✅ |
| `split-window -h/-v` | `split-window` / prefix `%` `"` (side-by-side / top-bottom) | ✅ |
| `kill-pane` / `kill-window` / `kill-session` | same verbs | ✅ |
| `select-pane` (directional + next/prev/last) | `select-pane -L/-R/-U/-D`, next/prev/last | ✅ |
| **active pane is server-authoritative** | `Tab.activePaneID` / `lastActivePaneID`, `selectPane` IPC | ✅ |
| `swap-pane` / `rotate-window` / `break-pane` / `join-pane` | same verbs (marked pane = `select-pane -m`) | ✅ |
| `move-pane` (explicit `-s` source) | same verb (join-pane with `-s`; same daemon op) | ✅ |
| `renumber-windows` (+ option, auto on close) | `renumber-windows` verb / CLI / `renumber-windows` option | ✅ |
| `resize-pane` (+ repeatable) | `resize-pane -L/-R/-U/-D`, repeatable bindings | ✅ |
| `zoom` (`resize-pane -Z`) | `zoom-pane` / prefix `z` | ✅ |
| `select-layout` + named layouts | even-h/v, main-h/v, tiled; next/previous-layout | ✅ |
| `respawn-pane` | `respawn-pane [-k]` (generation-guarded restart) | ✅ |
| `display-panes` | prefix `q` numbered overlay (GUI + compositor; digit selects) | ✅ |
| `last-window` / `last-pane` | `last-window` (MRU tab) + `select-pane -l` | ✅ |
| `link-window` / `unlink-window` | linked window shares the source's surfaces (live PTYs) across sessions; ref-counted surface GC | ✅ |
| grouped sessions (`new-session -t base`) | — (link-window covers cross-session sharing) | 🛣️ |

## Attach / multi-client

| tmux | Harness | Status |
|------|---------|--------|
| `attach-session` | `harness-cli attach` (single pane) | ✅ |
| client renders a window's full split layout | `harness-cli attach-window` compositor (borders, SGR, status, cursor) | ✅ |
| client follows the session's active window | compositor tracks `sessionID`, re-pins on snapshot push | ✅ |
| prefix verbs in the attach client | real prefix `KeyTable` + `keybindings.json` → `CommandIPCTranslator` | ✅ |
| layout changes pushed (no poll) | `subscribeSnapshot` → `snapshotChanged(revision)` push | ✅ |
| `window-size smallest` (multi-client) | smallest-wins per-surface sizing in `DaemonServer` | ✅ |
| `detach-client` / `list-clients` | same verbs | ✅ |
| mouse in the attach client (SGR) | SGR 1006 demux: parse `CSI < b;x;y M/m`, map to a pane via `PaneRectSolver`, re-base + forward via `InputEncoder.encodeMouse`; click focuses the pane (gated on `mouse`) | ✅ |
| control mode (`-CC`) | `harness-cli -CC` / `control-mode`: `%begin/%end/%output/%layout-change/%exit`, stdin commands bridged to IPC | ✅ |

## Copy mode & buffers

| tmux | Harness | Status |
|------|---------|--------|
| copy-mode (vi motions, search, yank) | **in-pane Metal overlay** over the live scrollback (no separate window) — `hjkl`/word/line/`g`/`G`, page/half-page, `/ ? n N` (all matches highlighted), yank, paste; one shared `CopyModeReducer` (`HarnessCopyMode`) | ✅ (GUI) |
| multiple paste buffers (+ `save`/`load-buffer`, `paste-buffer -p`) | `PasteBufferStore`; file I/O CLI; bracketed paste | ✅ |
| rectangle selection + `copy-pipe` | block mode (`C-v`) + `copy-pipe` (yank → shell command) | ✅ (GUI) |
| rebindable copy-mode key table (+ `mode-keys`) | copy-mode `KeyTable` binds real `copy-mode -X` commands; `bind-key -T copy-mode <key> <cmd>` works; `mode-keys vi` **and** `emacs` default tables, selected by one helper | ✅ |
| `set-clipboard` (OSC 52) | engine decodes OSC 52 → pasteboard + paste buffer, gated by `set-clipboard` | ✅ |
| copy-mode in the attach client | the **same** `CopyModeReducer` over the pane's scrollback, rendered by `GridCompositor` (selection/search highlights, copy-mode cursor, status row); `synchronize-panes` + OSC 52 in the compositor too | ✅ |

## Options, hooks, status, environment

| tmux | Harness | Status |
|------|---------|--------|
| scoped options (server/session/window/pane) | `OptionStore` (pane→tab→session→workspace→global inheritance) | ✅ |
| `set-option` / `show-options` | same verbs (`setw` = window/tab) | ✅ |
| `status-left`/`status-right` + format strings | `FormatString` (pane/session/window/agent/git/time/`window_flags`/…); GUI **and** compositor status lines | ✅ |
| `#[fg=…,bg=…,attrs]` style spans + operators | one `StyledSegment` intermediate (GUI attributed text + compositor SGR); `#{==:}` `#{m:}` (regex) `#{s/re/rep/:}` `#{e\|op\|a\|b}` | ✅ |
| multi-line `status` (`status 2..5`) | extra rows (`status-format-1…4`) above the main line; GUI status bar **and** compositor reserve the same row count via one `statusLineCount` helper | ✅ |
| `window-style` / `window-active-style` / `pane-style` / `pane-active-style` | base fg/bg for default-colored cells (dim inactive panes); GUI (`TerminalHostView`) **and** compositor (`WindowAttachClient`) resolve via one shared `PaneStyle`/`PaneStyleSet`; `*-active-style fg=default` cancels the dim on the active pane | ✅ |
| `pane-border-status` / `pane-border-format` | per-pane label on a row carved from the pane border (top/bottom): ssh compositor (`PaneRectSolver` reserves the row, `GridCompositor` draws it) + GUI (`TerminalHostView` overlay label); shared `pane-border-format` evaluation | ✅ |
| hooks (`set-hook` / `bind-hook`) | `HookRegistry` + `bind-hook`; fires at real mutation sites via `DaemonCommandExecutor` | ✅ |
| `allow-rename` / `automatic-rename` | OSC title gated; manual `rename-tab` makes the name sticky | ✅ |
| `set-environment` / `show-environment` | `EnvironmentStore` (global + per-session), injected on spawn/respawn | ✅ |
| `$TMUX` nesting guard | `$HARNESS` / `$HARNESS_SOCK` injected; `attach-window` warns on nesting | ✅ |
| agent `install-hooks` (Codex/Claude/Cursor/…) | `harness-cli install-hooks <agent>` | ✅ (Harness extension) |
| `remain-on-exit` | option read in the daemon PTY-exit handler: on (default, Harness's safe default) keeps the dead leaf for `respawn-pane`; off closes the pane — or its tab when last — on shell exit | ✅ |
| `base-index` / `pane-base-index` | `base-index` / `pane-base-index` options, applied to `-t` indices, `select-window`, and index display | ✅ |
| `monitor-activity` / `-silence` / `-bell` | daemon per-surface output monitor → tab `activity`/`silence`/`bell` flags (`#`/`~`/`!` in `#{window_flags}`, cleared on view) + `alert-activity`/`-silence`/`-bell` hooks | ✅ |
| `destroy-unattached` / `detach-on-destroy` | — | 🛣️ |
| `repeat-time` | `repeat-time` (ms) option read by `PrefixKeymap` for the post-`bind -r` re-arm window (no hardcoded literal) | ✅ |
| `escape-time` | n/a — Harness's key decoding is byte-driven, not timer-gated, so there is no ESC-disambiguation delay to tune | 🟰 |

## Commands & keys

| tmux | Harness | Status |
|------|---------|--------|
| prefix keymap + `bind-key`/`unbind-key` | `PrefixKeymap`, `KeyTable`, `keybindings.json` (merged defaults + overrides) | ✅ |
| no-prefix bindings (`bind -n` / `-T root`) | seeded, consulted `root` key table; `bind-key -T root <key> <cmd>` runs without the prefix in the GUI **and** the `attach-window` compositor (control bytes + ESC sequences decoded against `.root`, engaged only when root bindings exist) | ✅ |
| `send-keys -l` (literal) / `-H` (hex) | literal text / hex bytes sent raw via `sendData` (`KeyTokenParser.hexBytes`) | ✅ |
| command prompt (`:`) | `Cmd+;` / prefix `:` (`CommandPromptController`) | ✅ |
| one verb vocabulary across front-ends | `Command` + shared `CommandIPCTranslator` (GUI, compositor, hooks) | ✅ |
| `if-shell` / `run-shell` | same verbs (server-side for hooks) | ✅ |
| `display-message` (+ format tokens) | same verb; GUI toast / compositor status flash | ✅ |
| `command-prompt %% / %1…` arg expansion | `command-prompt -p … "<template>"` opens the prompt seeded with the template/placeholders | ✅ |
| `confirm-before` | `confirm-before -p "…" "<cmd>"` → NSAlert, runs on OK | ✅ |
| `command-alias` (short forms) | `neww`/`splitw`/`killp`/`selectp`/`resizep`/… resolve in `CommandParser` | ✅ |
| `choose-tree` / `-session` / `-window` / `-buffer` / `-client` | GUI menu picker (`choose-*`); palette (`Cmd+K`) for themes/actions | ✅ |
| `capture-pane -S/-E -e -p` (line ranges to stdout) | `capture-pane -S <n> -E <n>` (negative = from bottom); `-e` keeps SGR/escapes, default strips to plain text. `-J` (join wrapped lines) needs daemon-side grid emulation (the byte-stream capture can't reconstruct soft-wrap) — 🛣️ | ✅ |
| `pipe-pane` | tee a pane's live output to a shell command (`pipe-pane "<cmd>"`, omit to stop) | ✅ |
| `source-file` | run a file of Harness commands (`source-file <path>`) | ✅ |
| `send-prefix` | send the configured prefix key to the pane | ✅ |
| `wait-for` (named semaphores) | `wait-for [-S\|-L\|-U] <channel>`: `WaitForRegistry` in the daemon; `wait`/`lock` defer the reply at the `DaemonServer` socket layer (never under the registry lock — no deadlock), woken by `signal`/`unlock` | ✅ |
| tmux `-t session:window.pane` target syntax | `TargetSpec` parses index/name/`$`/`@`/`%` id, `!`/`+`/`-`/`^`/`$`, pane `{top,bottom,left,right}`; resolved centrally in `CommandIPCTranslator` for every leaf verb (directional `select-pane` unchanged) | ✅ |

## Server admin & integration

| tmux | Harness | Status |
|------|---------|--------|
| `lock-server` / `lock-session` / `lock-client` | `lock-client` → full-screen lock overlay (Enter to unlock) | ✅ |
| `clock-mode` | `clock-mode` → live full-screen clock overlay | ✅ |
| `display-popup [-E cmd]` | floating panel hosting a real terminal surface (ref-counted cleanup) | ✅ |
| `display-menu` | `display-menu <title> <key> <command> …` → native menu | ✅ |
| control mode (`-CC`) protocol | `harness-cli -CC` (see Attach section) | ✅ |

---

## Remaining roadmap

Nearly all of tmux's capability surface is now implemented across the GUI, the
CLI/compositor, and control mode — including copy-mode + SGR mouse on both surfaces,
monitoring (`monitor-*`), multi-line status, `window-style`/`pane-style`,
`pane-border-status`, `remain-on-exit`/`repeat-time`, the `bind -n` root table on both
surfaces, and `capture-pane -e`. The remaining 🛣️ items are intentionally **not**
shipped half-wired (that would be the tech debt this project forbids):

- **Grouped sessions (`new-session -t base`)** — `link-window` already provides
  cross-session shared windows (the underlying capability); grouped sessions add the
  auto-shared window-list convenience on top.
- **`switch-client -T <table>`** — per-client active key table (client-local state).
- **`capture-pane -J`** — join soft-wrapped lines; needs daemon-side grid emulation
  (the byte-stream scrollback capture can't reconstruct screen wrap).
- **Session-lifecycle options** — `destroy-unattached`/`detach-on-destroy`/`exit-empty`
  depend on a session↔client attachment model Harness's all-sessions-visible GUI +
  launchd-`KeepAlive` daemon don't have; `aggressive-resize` (smallest-wins already
  ships) and `status-keys` (needs the unconsulted `.command` table) are low-value.

Everything they build on — daemon authority, the shared translator, scoped options,
hooks, server-side active pane, snapshot push, the compositor, control mode, linked
windows — is in place, so each is additive rather than a rewrite.
