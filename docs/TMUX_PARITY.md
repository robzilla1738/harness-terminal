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
| `resize-pane` (+ repeatable) | `resize-pane -L/-R/-U/-D`, repeatable bindings | ✅ |
| `zoom` (`resize-pane -Z`) | `zoom-pane` / prefix `z` | ✅ |
| `select-layout` + named layouts | even-h/v, main-h/v, tiled; next/previous-layout | ✅ |
| `respawn-pane` | `respawn-pane [-k]` (generation-guarded restart) | ✅ |
| `display-panes` | prefix `q` numbered overlay | ✅ (GUI) / 🛣️ (compositor) |
| `last-window` / `last-pane` | last-pane (`select-pane -l`) done; last-window | 🟡 |
| `link-window` / `unlink-window` / grouped sessions | — | 🛣️ |

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
| mouse in the attach client (SGR) | — (GUI mouse is native via libghostty) | 🛣️ |
| control mode (`-CC`) | — | 🛣️ |

## Copy mode & buffers

| tmux | Harness | Status |
|------|---------|--------|
| copy-mode (vi motions, search, yank) | `CopyModeViewController` — `hjkl`/word/line/`g`/`G`, `/ ? n N`, yank, paste | ✅ (GUI) |
| multiple paste buffers | `PasteBufferStore` (`set/show/list/delete/paste-buffer`) | ✅ |
| rectangle selection | — | 🛣️ |
| rebindable copy-mode key table | native handler today; `keybindings.json` copy-mode table is discoverability-only | 🟡 |
| copy-mode in the attach client | — | 🛣️ |

## Options, hooks, status, environment

| tmux | Harness | Status |
|------|---------|--------|
| scoped options (server/session/window/pane) | `OptionStore` (pane→tab→session→workspace→global inheritance) | ✅ |
| `set-option` / `show-options` | same verbs (`setw` = window/tab) | ✅ |
| `status-left`/`status-right` + format strings | `FormatString`; GUI status line **and** compositor status line | ✅ |
| hooks (`set-hook` / `bind-hook`) | `HookRegistry` + `bind-hook`; fires at real mutation sites via `DaemonCommandExecutor` | ✅ |
| `allow-rename` / `automatic-rename` | OSC title gated; manual `rename-tab` makes the name sticky | ✅ |
| `set-environment` / `show-environment` | `EnvironmentStore` (global + per-session), injected on spawn/respawn | ✅ |
| `$TMUX` nesting guard | `$HARNESS` / `$HARNESS_SOCK` injected; `attach-window` warns on nesting | ✅ |
| agent `install-hooks` (Codex/Claude/Cursor/…) | `harness-cli install-hooks <agent>` | ✅ (Harness extension) |
| `remain-on-exit` | Harness keeps the dead leaf; `respawn-pane` revives (safe default) | 🟡 |
| `base-index` / `pane-base-index` | — (needs `-t session:window.pane` target parsing) | 🛣️ |
| `monitor-activity` / `-silence` / `-bell` | — | 🛣️ |
| `destroy-unattached` / `detach-on-destroy` | — | 🛣️ |
| `repeat-time` / `escape-time` | repeatable bindings exist; tunable timing | 🛣️ |

## Commands & keys

| tmux | Harness | Status |
|------|---------|--------|
| prefix keymap + `bind-key`/`unbind-key` | `PrefixKeymap`, `KeyTable`, `keybindings.json` (merged defaults + overrides) | ✅ |
| command prompt (`:`) | `Cmd+;` / prefix `:` (`CommandPromptController`) | ✅ |
| one verb vocabulary across front-ends | `Command` + shared `CommandIPCTranslator` (GUI, compositor, hooks) | ✅ |
| `if-shell` / `run-shell` | same verbs (server-side for hooks) | ✅ |
| `display-message` (+ format tokens) | same verb; GUI toast / compositor status flash | ✅ |
| `command-prompt %% / %1…` arg expansion | — | 🛣️ |
| `confirm-before` / `command-alias` | — | 🛣️ |
| `choose-tree` / `choose-session` / `choose-buffer` | command palette (`Cmd+K`) covers themes/actions; tree pickers | 🛣️ |
| `capture-pane -S/-E -p` (ranges to stdout) | `capture-pane` (full/scrollback) | 🟡 |
| `pipe-pane` / `wait-for` / `source-file` | — | 🛣️ |
| tmux `-t session:window.pane` target syntax | directional + active-target resolution done; index/`!`/`~` parsing | 🛣️ |

## Server admin & integration

| tmux | Harness | Status |
|------|---------|--------|
| `lock-server` / `lock-session` + `clock-mode` | — | 🛣️ |
| `display-popup` / `display-menu` | command palette is the menu surface; floating popup terminal | 🛣️ |
| control mode (`-CC`) protocol | — | 🛣️ |

---

## Roadmap rationale

The 🛣️ items are intentionally **not** shipped half-wired (that would be the tech
debt this project forbids). Each needs a self-contained subsystem:

- **Control mode (`-CC`)** — a control-protocol front-end + per-client notification
  stream; large and isolated.
- **link-window / grouped sessions** — a shared-`Tab`-by-link-set model and a second
  additive schema bump with careful kill/GC semantics.
- **Compositor copy-mode + SGR mouse** — a scrollback overlay and mouse demux in
  `WindowAttachClient`; the GUI already has native copy-mode and mouse.
- **`base-index` / target syntax / `command-prompt %%` / `choose-*`** — gated on the
  `-t session:window.pane` target parser, which several of them share.
- **`monitor-*` / `destroy-unattached` / `pane-border-status`** — option-driven
  behaviors that hang off new daemon lifecycle events.

The foundation they build on — daemon authority, the shared translator, scoped
options, hooks, server-side active pane, snapshot push, the compositor — is in
place, so each is additive rather than a rewrite.
