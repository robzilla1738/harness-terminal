# Handoff — Terminal independence (OSC 133, image persistence, live detach) + CI

**Branch:** `claude/harness-cli-terminal-independence-Q9YPP` · **PR:** [#1](https://github.com/robzilla1738/harness-cli/pull/1) → `main`

This branch was developed in a cloud container **with no Swift toolchain** — nothing here was
compiled or run. It was written carefully against existing patterns and statically self-reviewed,
but **your machine is the first real build.** This document is the to-do list to take it the rest
of the way.

---

## ✅ On-device pass — COMPLETE (2026-05-30)

The branch now builds, tests, and runs on macOS (Swift 6.2.4 / Xcode 26.3). Summary of the pass:

- **Build:** `swift build` clean (all targets incl. the AppKit app).
- **Tests:** `swift test` green — **487** tests, 0 failures (17 live-daemon tests skipped without
  `HARNESS_LIVE_DAEMON_TESTS=1`; all 7 pass *with* it, incl. the per-client detach regression).
  - Fixed two genuine bugs found on first compile: the OSC 133 exit-status tests fed the exit code
    *outside* the OSC terminator (`osc133("D")+";1"` → `\e]133;D\a;1`); corrected to `osc133("D;1")`.
- **§2 deferred on-device work — all done:**
  - **A. Prompt gutter** — `FrameBuilder` resolves a per-row green/red/neutral color from
    `snapshot.marks`; the Metal renderer paints a stripe in the left padding. Covered by
    `FrameBuilder` + a GPU render-readback test, and **verified live** (green/red/neutral stripes
    on `OK`/`FAIL`/`PENDING` lines, none on the unmarked shell prompt).
  - **B. Detach/reattach UX** — View ▸ Detach/Reattach Pane menu items (validated) + a dimmed
    `DetachedPaneOverlay` ("Pane released — click to re-grab"). **Verified live**: detach dims the
    pane + shows the overlay; reattach clears it and resumes output with scrollback intact.
  - **C. Copy-mode `[`/`]`** — confirmed they shadow nothing (free keys; search entry captures them
    as literals first); locked with `KeyTableTests`. Live-view jump left unbound by default.
  - **D. Hardening** — socket `sun_path` 104-byte guard (`HarnessPaths.validatedSocketPath`, used by
    client connect + server bind), EINTR retry on `connect`, RealPty fan-out moved to a dedicated
    serial delivery queue (off the read loop), and a vttest-style golden corpus.
  - **E. Release dry-run** — `make release` (bundle) + `make dmg` succeed. `make sign` is correctly
    gated behind `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD` (not run — needs Apple credentials).

The original to-do list below is kept as historical context.

---

## 0. Do this first — build, test, fix

```bash
swift build      # compiles every target incl. the AppKit HarnessApp
swift test       # all suites
```

Fix any compile errors before touching anything else. **Most-likely failure points**, in order:

1. **`TerminalScreen.swift`** — the OSC 133 `rowMarks` array and image `absRow` re-anchoring touch
   the most delicate code (scroll/reflow). If something's off it'll be here. Optional-chaining
   assignments like `history[h].mark?.exit = exit` and `rowMarks[r]?.exit = exit` are intended.
2. **`HarnessTerminalSurfaceView.swift` / `TerminalHostView.swift`** — the jump-to-prompt and
   detach/reattach methods. Verify `emulator` (a `TerminalEmulator`) exposes `promptRows` /
   `historyCount` (it should — added in this branch), and that the new `TerminalHostView` methods
   can see `private var outputSubscription` / `private func startDaemonOutput()` (same file → fine).
3. **`Command` vocabulary** — three new cases (`reattachSurface`, `jumpToPreviousPrompt`,
   `jumpToNextPrompt`) were threaded through `Command.swift` (enum + `shortDescription`),
   `CommandParser.swift` (switch + `knownVerbs`), `CommandIPCTranslator.swift` (client-local group),
   and `MainExecutor.swift`. If `swift test` fails on `CommandParserTests.testKnownVerbsAreAllParseable`,
   a verb is in one list but not the other.

If `swift test` passes, the engine/daemon features are verified. The GUI behavior (below) still
needs eyes on a running app.

---

## 1. What's implemented (and where)

### CI — `.github/workflows/ci.yml`
macOS runner, latest-stable Xcode, `swift build` + `swift test` on push/PR; non-blocking benchmark
job. **Confirm Actions is enabled on the GitHub repo** — it did not visibly run in the mirror env.

### OSC 133 shell integration
- **Engine:** `TerminalEmulator.handleSemanticPrompt` (parse `A`/`D`), `TerminalScreen` per-row
  `rowMarks: [SemanticMark?]` kept in lockstep with `rowWrapped` at every mutation site and through
  `reflow`. `SemanticMark` (public, `Model/TerminalGridModel.swift`) has `.exit: Int?`.
- **API:** `promptRows: [Int]`, `mark(atBufferLine:)`, snapshot `.marks` — on `TerminalEmulator`
  and `HarnessGridTerminal`.
- **Shell:** `docs/shell-integration/{harness.bash,zsh,fish}` emit `A`+`D`, gated on `$HARNESS`.
- **Copy mode:** `previous-prompt`/`next-prompt` motions; default keys `[`/`]` (vi), `M-[`/`M-]`
  (emacs) in `KeyTable.swift`.
- **Live view:** `jump-previous-prompt`/`jump-next-prompt` commands scroll the viewport
  (`HarnessTerminalSurfaceView.jumpToPreviousPrompt/Next`).
- **Tests:** `SemanticPromptTests`, `CopyModeReducerTests` (prompt-jump cases).

### Inline image persistence
- Images anchor to an absolute `[history ++ viewport]` row (`ImagePlacement.absRow`), persist into
  scrollback, survive `reflow` (re-anchored via `logicalOf`/`logicalFirstOutRow`), and evict with
  their scrollback line (`dropHistoryHead`). Alt screen still drops on resize. `TerminalScreen.swift`.
- **Tests:** `ImageProtocolTests` (persist-across-scroll/reflow + eviction + alt-screen-clears).

### Live detach/reattach (daemon)
- **Bug fixed:** `detachSurface` wiped *every* subscriber on a surface. Now per-client in
  `DaemonServer.handleDetachSurface` (cancels only the calling connection's token + size vote);
  `SurfaceRegistry` arm is a safe no-op; removed `RealPty.detachSubscriber`.
- **Client API:** `DaemonSubscription.detachSurface(_:)`.
- **GUI:** `SessionCoordinator.detachActiveSurface` (now routes through the host —
  `TerminalHostView.detachFromDaemonSurface`, which cancels the subscription) + `reattachActiveSurface`.
- **Tests:** `DaemonRoundTripTests` (multi-client mirroring + regression guard).

---

## 2. Remaining on-device work

### A. Prompt gutter rendering (deliberately deferred — needs the Metal frame path + eyes)
Draw a per-row indicator (green = exit 0, red = non-zero, neutral = prompt with unknown exit) for
rows whose snapshot carries a mark. Integration points:
- Snapshots already carry `marks: [Int: SemanticMark]` (viewport row → mark).
- `HarnessTerminalSurfaceView.renderCopyMode` (~line 1154) and the normal render path build a
  `TerminalFrame` via `frameBuilder.build(...)`. The cleanest approach: add an optional
  `promptMarks` parameter to the frame builder (in the renderer package) and have the Metal/CG
  layer paint a 1-px left margin run per marked row; **or**, for a lower-risk first cut, overlay a
  colored glyph in column 0 of marked rows the way `overlayCopyModeStatus` (~line 1184) already
  mutates `frame.cells` directly.
- Read `snapshot.marks[row]?.exit` to choose the color.
- Verify it tracks scrollback (the offset snapshot carries the right marks already).

### B. Detach/reattach UX affordance
Commands exist (`detach-client`/`reattach-surface`) and are keybindable, but there's no visible
"detached" pane state or menu item. Add:
- A menu item / context action calling `coordinator.detachActiveSurface()` / `reattachActiveSurface()`.
- A visual "released — click to re-grab" overlay on a detached pane (it currently just stops
  updating). Re-grab calls `reattachToDaemonSurface()` which replays scrollback.

### C. Default keybinding sanity
`[` / `]` in vi copy-mode were free, but confirm they don't shadow anything you rely on. Adjust in
`KeyTable.swift` if so. Consider a root-table binding (e.g. prefix `[` already enters copy mode in
tmux) for live-view jump-to-prompt if you want it outside copy mode.

### D. Step 5 — robustness hardening (was on the original plan; not yet done)
- **Unix socket path 104-char guard** — fail clearly if `HARNESS_HOME` makes `sun_path` overflow.
- **`RealPty` subscriber error isolation** — one throwing/slow subscriber shouldn't stall the fan-out.
- **EINTR on `connect`** in `DaemonClient.connectSocket`.
- **vttest-style conformance corpus** for the parser/screen (a few golden-snapshot tests).

### E. Step 6 — release dry-run (Mac only)
`make release` / `dmg` / sign + notarize, then the manual QA gates (multi-pane, detach/reattach,
images, OSC 133 gutter, copy-mode search, ssh attach compositor). Then the launch tier (bundle ID,
Sparkle, website, Homebrew) if you're going there.

---

## 3. Things to scrutinize (highest-risk blind changes)

1. **`rowMarks` sync** — I mirrored it at every `rowWrapped` mutation in `TerminalScreen`
   (scrollUp/Down, insert/deleteLines, eraseInDisplay/Line, resize, reflow, fullReset). If a prompt
   mark ever lands on the wrong row after editing, a site was missed. `SemanticPromptTests` covers
   scroll + reflow; add cases if you find a gap.
2. **Image reflow re-anchoring** — `reflow`'s `logicalOf` / `logicalFirstOutRow` map + the
   `trimmedFront` math. Resize a pane with an image on screen and with one scrolled into history;
   confirm it lands on the right row and evicts correctly past the scrollback cap.
3. **Detach regression** — confirm `detach-client` actually releases the pane now (pre-fix it
   relied on the wipe-all bug; the RPC path would silently no-op). Two app windows on one daemon:
   detach one, confirm the other keeps live output and the PTY survives.

---

## 4. Housekeeping
- A merged stale branch `claude/terminal-tmux-parity-mjQbj` can be deleted.
- Commit history on this branch is one logical step per commit (CI, OSC 133, detach, images,
  copy-mode/docs, GUI) — good for review or squash.

---

## 5. Manual verification recipes

- **OSC 133:** `source docs/shell-integration/harness.zsh` in a Harness pane, run a few commands
  (some failing), then enter copy mode and press `[` / `]` to jump between prompts. Bind
  `jump-previous-prompt` for live-view jumping.
- **Images:** `imgcat`/sixel an image, scroll up (should persist in scrollback), resize the pane
  (should survive on the primary screen).
- **Detach:** open the same session in two Harness windows; `detach-client` in one; confirm the
  other stays live and `reattach-surface` re-grabs.
