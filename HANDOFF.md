# HANDOFF — tmux-parity work (Phases 1–2)

**Read this first.** This document hands off in-progress tmux-parity work to a
Claude session running **on a Mac with a working Swift/Xcode toolchain**.

---

## ⚠️ Critical: this code has NOT been compiled

The Phases 1–2 work below was written in a **Linux cloud container with no Swift
toolchain** — it could not be built or tested there. It was written carefully
against existing patterns, and every exhaustive `switch` over `Command` /
`IPCRequest` was updated, **but it is unverified.**

**Your first job: build it and make the tests pass.**

```bash
cd <repo>
xcodegen generate          # only needed if project.yml / file set changed
swift build                # fast: surfaces compile errors
swift test                 # HarnessCore / Engine / Kit / Renderer suites
# Full app build:
xcodebuild -project Harness.xcodeproj -scheme Harness \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build test
```

Fix any compile errors first (see **Likely error hotspots** below), then run the
new tests, then do the per-feature smoke tests. Only after green should you
continue the roadmap.

---

## What this is

Harness is a native macOS terminal multiplexer (own GPU renderer, daemon-owned
session authority, `harness-cli` + `attach-window` compositor + control mode).
The goal is a 1:1 capability superset of tmux. Status is tracked in
[`docs/TMUX_PARITY.md`](docs/TMUX_PARITY.md). The architecture handbook is
[`claude.md`](claude.md) (identical to `agents.md`) — **read it before
architectural changes.**

The remaining roadmap (6 workstreams) is at the end of this file. The user chose
to do **Phase 1 (targets/options) first**, then **Phase 2 (copy-mode + clipboard)
with a full in-pane overlay rewrite**. Phase 1 is complete; Phase 2 is partially
complete (see below).

---

## Phase 1 — Targets + options foundation ✅ (code complete, unverified)

Universal tmux `-t session:window.pane` targeting plus `base-index`,
`move-pane`, `renumber-windows`.

| File | What changed |
|------|--------------|
| `Packages/HarnessCore/Sources/HarnessCore/Commands/TargetSpec.swift` | **New.** `TargetSpec` parses the tmux `-t` grammar (index / name / `$`/`@`/`%` id / `!`/`+`/`-`/`^`/`$` / pane `{top,bottom,left,right}`). `CommandTarget.resolving(...)` resolves it against the snapshot (reuses `PaneRectSolver` for directional pane markers), honoring `base-index`/`pane-base-index`. `Command.targetKind` disambiguates lone tokens. |
| `Commands/Command.swift` | Added `case targeted(TargetSpec, Command)`, `case movePane(direction:source:)`, `case renumberWindows`. Updated `shortDescription`. |
| `Commands/CommandParser.swift` | `parseStatement` strips a `-t <spec>` pair for an **allowlist** of leaf verbs (`universalTargetCommands`) and wraps in `.targeted`. `select-window` accepts session-qualified targets. Added `move-pane` / `renumber-windows` parsing + aliases. |
| `Commands/CommandIPCTranslator.swift` | `translate` gained `baseIndex`/`paneBaseIndex` params; handles `.targeted` (resolve → recurse; select verbs become absolute focus), `.movePane` (→ existing `joinPane` IPC), `.renumberWindows`. `selectWindow` applies base-index offset. |
| `Options/OptionStore.swift` | New defaults: `base-index` (0), `pane-base-index` (0), `renumber-windows` (off). |
| `Session/SessionEditor.swift` | New `renumberWindows(sessionID:)`. |
| `IPC/IPCMessage.swift` | New `case renumberWindows(sessionID:)`. |
| `Packages/HarnessDaemon/.../SurfaceRegistry.swift` | Handles `.renumberWindows`; auto-renumbers on `closeTab` when the option is on. |
| `Packages/HarnessDaemon/.../DaemonCommandExecutor.swift` | Threads base-index into `translate`. |
| `Apps/Harness/.../MainExecutor.swift` | `.targeted`/`.movePane`/`.renumberWindows` route through a shared `runViaTranslator` (single resolution source). Reads base-index via `HarnessOptions`. |
| `Tools/harness/.../ControlModeClient.swift`, `WindowAttachClient.swift` | Thread base-index into `translate`. |
| `Tools/harness/.../HarnessCLI.swift` | `move-pane`, `renumber-windows` subcommands. |
| Tests | `TargetSpecTests` (new), additions to `CommandParserTests` / `CommandIPCTranslatorTests`. |

## Phase 2 — copy-mode + clipboard 🟡 (partial; unverified)

| File | What changed |
|------|--------------|
| `Packages/HarnessTerminalEngine/.../Emulator/TerminalEmulator.swift` | **OSC 52** (`set-clipboard`): decodes base64 → `onSetClipboard` callback. |
| `Packages/HarnessTerminalEngine/.../HarnessGridTerminal.swift` | Forwards `onSetClipboard` (for the Phase-3 compositor). |
| `Packages/HarnessTerminalKit/.../HarnessTerminalSurfaceView.swift` | OSC 52 → writes pasteboard (gated by `allowProgramClipboardAccess`) + mirrors to daemon buffer via existing `onCopy`. |
| `Packages/HarnessTerminalKit/.../TerminalHostView.swift` | Exposes `allowProgramClipboardAccess`. |
| `Apps/Harness/.../SessionCoordinator.swift` | Sets `allowProgramClipboardAccess` from the `set-clipboard` option. |
| `Commands/CopyModeAction.swift` | **New.** First-class copy-mode command set (tmux `copy-mode -X`). |
| `Commands/Command.swift` | `case copyModeCommand(CopyModeAction)`. |
| `Keybindings/KeyTable.swift` | The `copy-mode` table now binds **real, rebindable** `copy-mode -X` commands (was `display-message` placeholders). `bind-key -T copy-mode` now works. vi defaults. |
| `Commands/CommandParser.swift` | Parses `copy-mode -X <action>` and `send-keys -X <action>`. |
| `Apps/Harness/.../CopyModeViewController.swift` | Key handling is now **data-driven** (resolves keystroke → copy-mode table → action). Added **rectangle (block) selection**, **copy-pipe**, page/half-page motions, copy-without-cancel. |
| `IPC/IPCMessage.swift` + daemon + CLI | `pasteBuffer` gained a `bracketed` flag (`paste-buffer -p`); `save-buffer`/`load-buffer` CLI (file I/O over existing IPC). |
| Tests | `ClipboardOSCTests` (new), copy-mode parser/key-table tests. |

### Phase 2 — what is NOT done (your next work, needs the compiler)

1. **Full in-pane Metal overlay.** Copy-mode still renders in a separate
   `NSWindow` (`CopyModeViewController`). The user wants it replaced by an
   in-pane overlay drawn by `HarnessTerminalRenderer` / `HarnessTerminalSurfaceView`
   (selection highlight, cursor, search hits, mode indicator), driven by the
   now-rebindable copy-mode `KeyTable`. All the logic it needs (action vocabulary,
   rectangle model, copy-pipe) is in place — this is the rendering integration,
   which is why it was deferred to an environment with a compiler.
2. **`mode-keys emacs`** — only `vi` defaults ship. Add an emacs copy-mode default
   table and select per the `mode-keys` option.
3. Consider extracting an **engine-level copy-mode model** (over scrollback +
   `TerminalGridSnapshot`) so the GUI overlay and the Phase-3 compositor share one
   implementation instead of the current capture-text approach.

---

## Likely error hotspots (check these first when building)

- **Exhaustive switches over `Command`** — three are exhaustive (no `default`):
  `Command.shortDescription`, `CommandIPCTranslator.translate`,
  `MainExecutor.dispatch`. All were updated for `targeted`/`movePane`/
  `renumberWindows`/`copyModeCommand`; confirm none is missing.
- **`SurfaceRegistry.handle`** is exhaustive over `IPCRequest`; the
  `renumberWindows` arm and the new `pasteBuffer(...bracketed:)` signature were
  updated. `IPCCodecTests` constructs `pasteBuffer(..., bracketed:)`.
- **`CopyModeViewController`** is the largest hand-edited AppKit file. Verify the
  new `perform(_:)`, `keySpec(from:)`, rectangle helpers (`lineStartOffsets`,
  `rowCol`, `blockSelectedText`, `applyBlockHighlight`), and `copyPipe`. The
  NSTextView block-selection highlight (`selectedRanges`) is the least-certain bit.
- **`HarnessOptions.shared`** (app option store, defined in `StatusLineView.swift`)
  is used by `SessionCoordinator` and `MainExecutor`.
- `TargetSpec.parseWindowToken` / `parsePaneToken` are referenced via
  `flatMap(...)` in `CommandTarget.resolving` — confirm access level resolves.

---

## Per-feature smoke tests (after build is green)

```bash
# Phase 1 — targets/options
harness-cli set-option -g base-index 1
harness-cli select-window -t mysession:2          # selects window 2 in mysession
# in the GUI ":" prompt or a binding:
:kill-pane -t :1
:move-pane -s :1.0
:renumber-windows
harness-cli send-keys -t mysession:1.0 "echo hi" Enter   # value not leaked as a key

# Phase 2 — clipboard / buffers
printf '\e]52;c;%s\a' "$(printf 'clip via OSC52' | base64)"   # sets the system clipboard
harness-cli load-buffer /tmp/x.txt ; harness-cli save-buffer /tmp/y.txt
harness-cli paste-buffer --surface "$HARNESS_SURFACE" -p       # bracketed

# Phase 2 — copy mode (in the GUI)
#   prefix [ to enter; C-v toggles rectangle; y yanks; rebind test:
:bind-key -T copy-mode Y copy-mode -X copy-pipe "pbcopy"
```

---

## Architecture invariants (do not violate — from claude.md)

1. **Daemon owns session truth.** Only `SurfaceRegistry` writes `layout.json`;
   the app/CLI are clients. Add layout ops via IPC.
2. **One command vocabulary.** New verbs flow `Command` → `CommandParser` →
   `CommandIPCTranslator` → `IPCRequest` → `SurfaceRegistry`/`SessionEditor`, and
   only then get GUI/CLI/compositor affordances. The translator is the single
   resolution point shared by GUI, CLI, compositor, control mode, and hooks —
   never special-case one front-end.
2b. Targets resolve **once**, centrally, via `CommandTarget.resolving`. Don't
    thread `-t` through individual enum cases.
3. Options are data in `OptionStore` with `pane→tab→session→workspace→global`
   inheritance; behavior reads them, never hardcodes.
4. Keep diffs minimal; comments only for non-obvious invariants.
5. `claude.md` and `agents.md` are identical — edit both together.
6. After each feature, update `docs/TMUX_PARITY.md` / `docs/COMMANDS.md` /
   `docs/KEYBINDINGS.md` and the handbook.

---

## Remaining roadmap (after Phase 2 finishes)

Ordered as the user chose. Each is additive — daemon authority, the shared
translator, scoped options, hooks, server-side active pane, snapshot push, the
compositor, and control mode are all already in place.

- **Phase 2 remainder** — in-pane Metal copy-mode overlay (see above); `mode-keys
  emacs`.
- **Phase 3 — Compositor (ssh) parity** — port copy-mode (scrollback overlay via
  `HarnessGridTerminal.readGrid(scrollbackOffset:)`) and **SGR mouse demux** into
  `WindowAttachClient` (parse `CSI < b;x;y M/m` on stdin, map to pane via
  `PaneRect`s, forward re-based via `InputEncoder.encodeMouse`); `display-panes`
  and `synchronize-panes` in the compositor. OSC 52 from a pane → client clipboard
  (callback already forwarded on `HarnessGridTerminal`).
- **Phase 4 — Status styling + formats** — `#[fg=…,bg=…,attrs]` style spans in
  `FormatString`; operators (`#{==:}`, `#{m:}`, `#{s/re/rep/:}`, `#{e|…}`);
  multi-line status (`status 2..5`); `pane-border-status`/`-format`;
  `window-style`/`pane-style`.
- **Phase 5 — Monitoring + lifecycle** — `monitor-activity`/`-silence`/`-bell`
  (+ `window_flags` `#`/`~`/`!`, visual alerts) via daemon output watching + new
  `HookEvent`s; `remain-on-exit` (dead-pane state); `destroy-unattached` /
  `detach-on-destroy` / `exit-empty`; `repeat-time` / `escape-time` /
  `aggressive-resize` / `status-keys`.
- **Phase 6 — Keys + misc** — root key table (`bind -n`; the `.root`/`.command`
  table IDs exist but are intentionally not yet seeded/consulted — see
  `KeyTable.swift`); custom key tables + `switch-client -T`; `wait-for` (named
  semaphores); `send-keys -H/-l/-R`; `capture-pane -e/-J`; `refresh-client`.

---

## Git state at handoff

All Phase 1–2 work is on `main` (fast-forwarded from `5063c74`) and on branch
`claude/terminal-tmux-parity-mjQbj` — both at the same commit. Working tree clean.
The 11 commits are prefixed `Targets:`, `Copy/clipboard:`, `Buffers:`,
`Copy mode:`, `Docs:`.
