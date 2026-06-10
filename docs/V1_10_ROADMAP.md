# Harness — v1.10 Roadmap: Faster, Smoother, Better

> **Status:** 🟢 Open — PR-25 → PR-37 queued, none started. Generated 2026-06-09 against `main` `c73b10f` (v1.9.0 + the merged-but-unreleased #139). Successor to [docs/AUDIT_ROADMAP.md](AUDIT_ROADMAP.md) (PR-1…21 all shipped in v1.9.0; its deferred P5 tail — PR-22/23/24 — is absorbed here as PR-30/31/32, PR-29, and PR-36).
> Execute in the merge order below, one focused themed PR at a time (impl + tests + green CI, merged on review). Update the per-PR status markers in this file as PRs land.

## Context

Owner brief: make Harness a **true Ghostty competitor/replacement** — fast, smooth, powerful, tech-debt-free — while keeping the ghostty/tmux/cmux parity surface intact. This queue was produced by a full-project pass (3 parallel deep-read audits over engine/renderer, daemon/CLI/app, and the outstanding-work ledgers, followed by hand-verification of every load-bearing claim against current source — line numbers below are current at `c73b10f`).

**Where we stand:** v1.9.0 consumed the entire prior audit roadmap (#115–#138: paste hardening, secure input, VoiceOver, VT cluster, DCS demux, Kitty graphics control, quick terminal, unlimited scrollback, bell, the Ghostty-UX 4-pack…). #139 added UCD width tables, O(1) IPC framing, kqueue child-exit watching, glyph-atlas page LRU, debounced store saves, and enforceable benchmarks (`make bench-record` / `bench-check`, 58 baselines). The engine/renderer is at the industry frontier for resize/typing/redraw after the #42/#43/#50, #80–#82, and #83–#87 series. What is *genuinely left* clusters in five places: one bad app-side polling design (git metadata), idle-efficiency leaks, one O(matches × cells) frame-build path, the sanctioned-but-deferred decomposition/VT-polish/security tail, and the absence of *receipts* (no comparative startup/latency/idle/memory numbers vs Ghostty).

## Ground truth — verified-dead claims (do NOT chase these)

Each of these was re-verified against `c73b10f`. They are fixed, false, or measured-refuted; treat as settled.

- **`set-environment` dangling `-s` global-write (bughunt BH-003): FIXED** — `flagIsDangling` guard at `Tools/harness/Sources/HarnessCLI/HarnessCLI.swift:1449-1455` (and `show-environment` at `:1470-1475`).
- **`RealPty.write()` fd-recycle TOCTOU (bughunt BH-005): FIXED** — write takes a private `dup()` of master under `lifecycleLock` (`Packages/HarnessDaemon/Sources/HarnessDaemon/RealPty.swift:359-390`).
- **"Snapshot deep-copy per keystroke": FALSE** — GUI typing rides the persistent input connection with a coalesced `.sendData` fallback (`TerminalHostView.swift:944-1062`); `requestDaemon` performs no snapshot fetch.
- **"Daemon holds GiBs of scrollback RAM": FALSE** — the in-memory replay ring defaults to 1 MiB and `scrollbackBytes == 0` (unlimited) maps to `ScrollbackFile.unlimitedSafetyCap` (`RealPty.swift:227, :236-244`). The GUI emulator owns unbounded history by design.
- **"Display link fires at 120 Hz when idle": FALSE** — created paused and `isPaused`-managed by pending work (`HarnessTerminalSurfaceView.swift:1321, :1705, :1713`). Do not touch it in PR-26.
- **Shaped-run cache eviction "O(n) shift": FALSE** — already amortized via `shapedRunCacheOrderStart` + threshold compaction (`GlyphRasterizer.swift:362-381`).
- **`.bughunt/` report (2026-06-07): fully consumed** — all 20 findings fixed by #112/#139 or verified-fixed above.
- **Measured-refuted perf ideas (prior series; do not re-propose):** PTY read-ahead/O_NONBLOCK (kernel caps PTY reads ~1 KiB), predictive echo, CoW-snapshot elimination, latency thresholds as CI gates (50–100× above signal), off-main Metal encode work (already sub-0.3 ms), `inLiveResize` gating (deliberately rejected for testability).

## Roadmap — incremental themed PRs

Effort: **S** < ~1 day · **M** a few days · **L** larger.
**Merge order: 25 → 26 → 27 → 29 → 28 → 30 → 31 → 32 → 33 → 36 → 34 → 35 → 37.** Every PR is independently shippable off latest `main`.

### Phase A — user-feelable performance & smoothness

**PR-25 · Event-driven git metadata + GUI snapshot-push subscription** · performance+architecture · M–L
- *Why:* `SessionCoordinator.startMetadataRefresh()` (`Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift:1568-1596`) wakes every 2 s and, for **every tab of the active workspace**, calls `GitMetadataProvider.refresh` → `Packages/HarnessCore/Sources/HarnessCore/Metadata/MetadataProvider.swift:16-34`, which **spawns `/usr/bin/git rev-parse` via `Process` + `waitUntilExit()`** — serial, **no timeout** (a hung git on a network mount wedges the loop forever), no per-repo coalescing (5 tabs in one repo = 5 spawns), no negative cache for non-repos. Line `:1592` then calls `syncFromDaemon(metadataOnly: true)` **unconditionally** — a full snapshot fetch + decode at 0.5 Hz forever, even with zero changes, even while the app is inactive. **Constraint that shapes the fix:** that blind 2 s sync is currently the GUI's *only* discovery of external CLI-driven structure changes (`harness-cli split-pane` against a GUI session) — the GUI never calls `subscribeSnapshot`; only `ControlModeClient.swift:20` and `WindowAttachClient.swift:1460` do. Simply conditionalizing the sync would silently break cmux parity. Meanwhile the daemon already pushes: every mutation fires `onSnapshotCommitted` → `DaemonServer.pushSnapshotRevision` (`SurfaceRegistry.swift:1375-1387`, `DaemonServer.swift:73-86`).
- *Approach:* Three coordinated changes. **(1) In-process branch reads:** new `GitHEADReader` in HarnessCore — resolve `.git` upward from the tab cwd (directory, or a file containing `gitdir:` for worktrees/submodules), parse `HEAD` (`ref: refs/heads/<branch>` → branch; detached → short hash), nil for non-repo. No subprocess, so the no-timeout hazard disappears by construction. Keep the `MetadataProvider` protocol shape. **(2) Watch, don't poll:** new app service `GitBranchMonitor` — one file watcher per **unique resolved repo root** on the resolved `HEAD` path (reuse the `FileWatcher` pattern from config reload-on-save; its atomic-rename re-arm matches git's lockfile+rename update style), per-directory negative cache for non-repos invalidated on cwd-change events and app activate, coalescing so N tabs in one repo cost one watcher + one read. On change: read → if different, `updateTabGitBranch` IPC → daemon commit → push. Branch labels become **instant** instead of ≤2 s late. **(3) Subscribe the GUI to the existing push channel:** after daemon connect (and on every reconnect/endpoint switch), `DaemonClient.subscribeSnapshot`; handler hops to main, guards `revision != lastRevision`, calls the existing `syncFromDaemon()` (its `structureRevision` diffing already decides metadata-vs-remount). Keep a **30 s app-active-only full-sync safety poll**: `DaemonServer` drops subscribers whose write backlog exceeds 32 MiB, and a dropped fd silently stops pushes — the poll is push-loss insurance, not the mechanism. Delete the 2 s loop. Pause watchers + safety poll on `NSApp` resign-active; resume + refresh-all on activate.
- *Files:* `MetadataProvider.swift` (+ new `GitHEADReader.swift`), new `Apps/…/Services/GitBranchMonitor.swift`, `SessionCoordinator.swift`, `DaemonSessionService`/client glue for the subscription.
- *Tests:* `GitHEADReader` units (symref, detached, worktree `gitdir:` file, non-repo, unreadable, mid-rewrite empty read); coordinator test asserting **zero** `updateTabGitBranch` IPC when nothing changed; subscription revision-guard unit; live-daemon test (`HARNESS_LIVE_DAEMON_TESTS=1`): CLI-side `split-pane` reaches the GUI through the subscription with the loop deleted. *Receipts:* before/after `ps`-visible git spawns (10/s → 0 on a 20-tab session) in the PR body.
- *Risk:* medium (sync-cadence change). Mitigations: revision guard, safety poll, live-daemon coverage. **Land first.**

**PR-26 · Idle-efficiency bundle (app + daemon)** · performance · M
- *Why:* Three timers do per-tick work that should be event-gated. **(a)** The cursor-blink `Timer` fires every 0.53 s per pane forever; unfocused panes merely early-out inside the callback (`HarnessTerminalSurfaceView.swift:2371-2386` — `guard self.effectivelyFocused`), so 20 panes = 40 pointless main-runloop wakeups/s. **(b)** The daemon monitor timer fires every 500 ms and — because monitor entries persist per-surface after any output — gets past the `drained.isEmpty` guard and takes the **registry lock + OptionStore reads every tick** even when nothing is armed (`SurfaceRegistry.swift:151-197`); note `monitor-bell` defaults **true** (`:198` region), so gating on option values alone is useless. **(c)** `SurfaceShellTracker` runs `proc_listpids` + per-process `sysctl(KERN_PROCARGS2)` + `proc_pidinfo` every 500 ms even with the app inactive (`SurfaceShellTracker.swift:31-72`; the scan is already off-main and coalesced — keep that).
- *Approach:* **(a)** Stop/start the blink timer on focus + occlusion transitions instead of guarding inside the tick: `restartBlinkTimer` declines to schedule when `!effectivelyFocused || occluded`; drive it from the existing focus-change and `setWindowOccluded` seams (~`:3495`, ~`:1350`); set `cursorBlinkVisible = true` on stop so the unfocused hollow cursor stays steady. **Do not touch the display link** (already `isPaused`-managed). **(b)** Cheap precheck under `monitorLock` only: skip the registry lock + option reads when no `sawOutput`/`sawBell` flag was set this tick AND silence monitoring is disarmed; cache the silence-armed state, updated from the `set-option` path. Same lock seam — the single-lock serialization is a documented invariant, no redesign. **(c)** Pause the tracker timer on `NSApp.didResignActiveNotification`, resume + `bumpScan()` on activate; optionally stretch cadence to 2 s after N unchanged scans, snapping back on surface create/focus.
- *Files:* `HarnessTerminalSurfaceView.swift`, `SurfaceRegistry.swift`, `SurfaceShellTracker.swift`.
- *Tests:* blink-timer-not-scheduled-when-unfocused/occluded (extend the `testCursorBlinkReencodesAtMostTheCursorRow` family via the focus test seam); daemon idle tick takes no registry lock (test-hook counter) + silence-armed transition tests; tracker pause/resume unit. *Receipts:* `powermetrics` before/after (60 s idle, 4 panes: CPU ms/s + wakeups for Harness **and** HarnessDaemon) quoted in the PR body.
- *Risk:* low. **Land before PR-31** (PR-31 relocates the monitor code this touches).

**PR-27 · Search-highlight per-row interval index** · performance · S–M
- *Why:* With the find bar open, `FrameBuilder.appendRow` evaluates `searchHighlights.contains { $0.contains(row:column:) }` **per cell** (`Packages/HarnessTerminalRenderer/Sources/HarnessTerminalRenderer/TerminalFrame.swift:548-563`) — O(matches × cells); hundreds of matches over a 19 K-cell viewport is realistic while scrolling with search active. The #85 cell-overlay pass funnels `applyHighlights` through this same `appendRow`, so one index serves both paths.
- *Approach:* Pre-bucket `[TerminalSelection]` into per-row sorted column intervals once per `build` and once per `applyHighlights` (`TerminalSelection.contains` at `:230-236` decomposes exactly: single row → `[startCol…endCol]`; first row → `[startCol…cols-1]`; last → `[0…endCol]`; middle → full row). `appendRow` consumes its row's interval list. Both paths share the bucketing — preserving `applyHighlights`' **byte-identical-by-construction** property; the per-row overlay fingerprints derive from the same inputs and stay in sync.
- *Files:* `TerminalFrame.swift`.
- *Tests:* differential test — randomized highlight sets, old-logic oracle vs new path, byte-identical `RenderCell` arrays; new benchmark (e.g. `testBuildFrameSearchHighlights160x48`, ~200 hits) with `make bench-record` for the new baseline **in the same PR**; `make bench-check` green on the existing 58.
- *Risk:* low.

### Phase B — proof / receipts

**PR-28 · `Scripts/scorecard.sh` — Harness vs Ghostty comparative scorecard** · tooling+proof · M
- *Why:* The "true Ghostty competitor" claim has no receipts: cold start, input-to-photon, idle power, and long-session memory are unmeasured, and open issue **#27** (Harness lost the ansi_sgr/attributes/unicode drain workloads at the #26-era head-to-head) was never re-run after #31's parse speedups and #139's UCD tables. The infra mostly exists: `StartupMetrics.swift` already records six launch phases behind `HARNESS_STARTUP_METRICS=1` (with a durable `logs/startup.log` sink); `Scripts/benchmarks/terminal_stress_runner.py` is the cross-terminal drain harness; `FrameSignposter` p99 + `Scripts/measure-fluidity.sh` cover frame timing. This PR is orchestration + reporting, not new instrumentation.
- *Approach:* One orchestrator script + `docs/SCORECARD.md` (template + committed sample results). Sections: **cold start** (N=10 launches, parse startup.log phase deltas launchStart→firstDrawablePresented; Ghostty measured wall-clock-to-window; asymmetries documented, e.g. daemon spawn vs single process); **sustained throughput** (terminal_stress_runner.py on both — re-measure the issue-#27 workloads FIRST; only if still behind, file a measurement-first profiling follow-up on the SGR/attr dispatch path — **no speculative engine surgery in this PR**); **input-to-photon** (CGEvent inject + FrameSignposter p99 sampling, modeled on measure-fluidity.sh — comparative number only; a prior 37-agent deep dive killed latency thresholds as CI gates, respect that); **idle power** (`powermetrics` 60 s: CPU ms/s + wakeups; Harness app+daemon summed vs Ghostty — the two-process asymmetry stated, not hidden); **long-session memory** (scripted 1 M-line session, `footprint(1)` after, both). Degrade gracefully to Harness-only mode when Ghostty isn't installed; `--dry-run` self-check.
- *Files:* new `Scripts/scorecard.sh`, new `docs/SCORECARD.md`; no production code.
- *Tests:* script self-check; sample output committed. *Note:* run on owner hardware after Phase A lands so the startup/idle numbers are the new ones.
- *Risk:* none (additive tooling).

### Phase C — tech debt (sanctioned: absorbs AUDIT_ROADMAP PR-22/23)

**PR-29 · VT polish + safety hardening cluster** · ghostty-parity+safety · M–L *(absorbs AUDIT_ROADMAP PR-23, + SGR-pixel 1016)*
- *Why:* The documented tail of small correctness/polish items, plus two safety fixes. Deliberately sequenced **before** the mechanical splits so functional diffs don't ride on top of file moves.
- *Approach:* Batch: richer DA1 (`?62;22c`), DA3 reply, non-private DECRQM (+ unrecognized-mode state-0 conformance test), mode 1048 save/restore cursor, att610 cursor-blink (mode 12), CSI t title-stack push/pop (22/23) + size **reports** (18/14 — resize/move stays a non-goal), underline-pattern continuous phase on absolute grid X, DECSET 1003 any-event motion (report in `mouseMoved` when armed) + **1016 SGR-pixel mouse** riding the same plumbing, SGR blink rendering (fold a blink-phase bit into the row content key so **only blink rows re-encode** — verify with the existing render-encode damage benchmarks), DECSCNM reverse-video (mode 5) swap in `CellColorResolver`, `HistoryRingBuffer`'s release-shipping `precondition` → graceful clamp (keep the debug assert), and a per-connection partial-frame cap in `DaemonServer`.
- *Files:* `TerminalEmulator.swift`, `HarnessTerminalSurfaceView.swift` (motion/pixel reporting, CSI t 14 metrics), `TerminalMetalRenderer.swift`, `CellColorResolver.swift`, `Screen/HistoryRingBuffer.swift`, `DaemonServer.swift`.
- *Tests:* one conformance test per reply/mode; blink-rows-only re-encode assertion; daemon partial-frame cap test; `make bench-check` (the row-content-key change is the only perf-risk surface). Update `TMUX_PARITY.md`/handbook where behavior diverges.
- *Risk:* medium (row-key change). May split engine/renderer halves if review size demands.

**PR-30 · Mechanical decomposition I — TerminalKit + Renderer** · tech-debt · L diff / S semantic *(AUDIT_ROADMAP PR-22a)*
- *Why:* `HarnessTerminalSurfaceView.swift` is 4053 lines mixing 8+ responsibilities; `TerminalMetalRenderer.swift` is 1822. Merge-conflict magnets; the only structural debt in an otherwise healthy stack.
- *Approach:* **Strictly mechanical, zero behavior change.** Split the surface view along existing `MARK` seams into same-class extension files (`+Selection`, `+Find`, `+CopyMode`, `+Input`, `+IME`, `+LinkHover`; `+Accessibility` already exists from #118). Extract `TerminalRenderInstances.swift` from the renderer. No signature changes, no logic edits.
- *Files:* `HarnessTerminalSurfaceView.swift` → 6–7 files; `TerminalMetalRenderer.swift` → +1 file.
- *Tests:* none new; full suite + renderer parity/golden suites **byte-identical**; `make bench-check` unchanged.
- *Risk:* low. **After PR-29** (conflict avoidance).

**PR-31 · Mechanical decomposition II — Daemon + Core** · tech-debt · M–L *(AUDIT_ROADMAP PR-22b)*
- *Why:* `SurfaceRegistry.swift` (1877) is a god object (IPC dispatch + PTY lifecycle + monitoring + hooks + banner); `SessionEditor.swift` (1437 — lives in `Packages/HarnessCore/Sources/HarnessCore/Session/`, the old roadmap's placement note was loose) carries the whole split-tree algebra inline; `HarnessSettings.init(from:)` is 67 hand-written `decodeIfPresent` lines (`HarnessSettings.swift:537+`) — a forward-compat hazard.
- *Approach:* Extract `SurfaceMonitor` + the version-banner one-shot from `SurfaceRegistry` **behind the same lock** (single-lock serialization is a documented correctness invariant — strictly mechanical, no redesign); `SessionEditor` split-tree algebra → `+SplitTree.swift`; replace the hand-written settings decoder with a default-instance-driven decode helper (the uniform `?? fallback.x` pattern makes this near-mechanical).
- *Files:* `SurfaceRegistry.swift` (+2 extracted files), `SessionEditor.swift` (+1), `HarnessSettings.swift`.
- *Tests:* settings round-trip + forward-compat decode test (unknown keys ignored, missing keys → defaults); daemon suite + `HARNESS_LIVE_DAEMON_TESTS=1` run; VersionBanner tests unchanged.
- *Risk:* low-medium (lock-adjacent moves). **After PR-26** (which edits the monitor code being moved).

**PR-32 · Mechanical decomposition III — App + CLI** · tech-debt · L diff / S semantic
- *Why:* `SettingsViewController.swift` (2712), `SessionCoordinator.swift` (1888), `HarnessCLI.swift` (1877) are the remaining god files; every settings/coordination change pays a whole-file comprehension tax.
- *Approach:* Same mechanical rules: extension-file splits along existing seams — settings per-tab section files, coordinator concerns (`+Notifications`, `+AgentActivity`, `+Metadata`, `+FocusSync`…), CLI subcommand handler files. No new types unless a move is literally impossible without one; no behavior change.
- *Files:* the three above → ~12–15 files.
- *Tests:* none new; full suite green; CLI smoke (`harness-cli ping`, `new-tab`, `set-environment` guards).
- *Risk:* low.

**PR-33 · Test de-flake + tracked-doc truth pass** · hygiene · M
- *Why:* ~48 fixed sleeps across `Tests/HarnessDaemonTests` (RoundTrip 21, Contention 11, VersionBanner 7, SurfaceRegistry 6, FormatContext 2, EndpointClient 1) plus 8 `Thread.sleep` shell-start assumptions in `RealPtyLifecycleTests.swift`; CI has flaked on wall-clock seams twice historically. Tracked docs still describe the pre-v1.9 world in places.
- *Approach:* Introduce/reuse an event-driven wait helper (deadline-polling on a condition, not fixed sleeps) and convert the worst offenders; where a test genuinely models elapsed time (silence monitors), use the existing scheduler-seam pattern instead of wall-clock. Doc pass: README + `docs/AGENT-HANDBOOK.md` + `TMUX_PARITY.md` refreshed for v1.9 reality (quick terminal, bell, unlimited scrollback, Kitty control protocol…). Run the daemon suite 3× locally as the flake-confidence gate.
- *Files:* `Tests/HarnessDaemonTests/*`, `RealPtyLifecycleTests.swift`, README/docs.
- *Risk:* low. Anytime; low conflict.

### Phase D — parity long tail + security

**PR-34 · Parity long-tail quick wins** · ghostty-parity · M
- *Why:* Independently small, all verified absent: **F30** DECKPAM/DECKPNM keypad SS3 emission (the `keypadApplication` mode flag is already tracked — `TerminalEmulator.swift:293-294, :817, :1020` — this is encoder-only); **F20** OSC 1337 `CurrentDir=` (→ `onWorkingDirectoryChange`, validated like OSC 7) + `SetUserVar=` (base64 → per-surface user-var dict feeding format tokens); **F37** double-line box drawing (U+2550–256C) procedural; **F38** sextants/octants + Braille (U+1FB00+, U+2800+) procedural — btop-class TUI completeness; **F39** font-features setting (OpenType feature dict via `CTFontDescriptor`); **window-inherit-cwd** — new tab/window inherits the focused pane's cwd (setting, Ghostty-style default **on**; call the default flip out in the CHANGELOG).
- *Files:* engine (OSC 1337, user-var dict), Kit input encoder (SS3), renderer procedural glyph paths (F37/F38 — extend the glyph-atlas/procedural golden tests), `GlyphRasterizer`/font config (F39), `SessionCoordinator` + settings (inherit-cwd).
- *Tests:* per-feature conformance; renderer goldens for every new procedural range; `make bench-check`.
- *Risk:* low. Can split F37/F38 out if the procedural-drawing review gets large.

**PR-35 · Shell-integration auto-inject at spawn** · ux · M · **behavioral risk — ships last in Phase D**
- *Why:* Ghostty's "it just works" advantage: prompt marks / cwd / command-finished without a manual `install-shell-integration` step. Harness already owns the spawn environment (`RealPty` `extraEnvironment`) and ships the snippets (`shell-integration/harness.{bash,zsh,fish}`).
- *Approach:* Inject per shell at spawn: zsh → `ZDOTDIR` shim dir whose `.zshenv` sources the user's original then the snippet; bash → `--rcfile`/`ENV` wrapper; fish → `XDG_DATA_DIRS` vendor_conf.d. **Opt-out setting** (`shell-integration = off`), never injected for non-interactive invocations or explicit command overrides; idempotent when manual integration is already installed (env-guarded snippets). Document loudly.
- *Files:* `RealPty.swift`/`SurfaceRegistry.swift` (spawn env), bundled snippet resources, `HarnessSettings.swift`, docs.
- *Tests:* live-daemon per shell (zsh/bash/fish): OSC 133 marks appear; user rc files still sourced (shim chains correctly); `$SHELL` unchanged; opt-out honored; non-interactive spawn untouched.
- *Risk:* medium-high (touches users' shell startup implicitly) — flagged for owner sign-off at review; positioned last so a revert is clean.

**PR-36 · Security posture review** · security · S–M *(absorbs AUDIT_ROADMAP PR-24)*
- *Why:* Named in the original brief, never executed: no-sandbox + Sparkle + Services posture unaudited; scrollback persists raw PTY output (echoed secrets) with owner-only perms but no per-surface opt-out; IME depth (dead keys, CJK candidate commit timing, wide marked-text width) never systematically audited.
- *Approach:* `docs/SECURITY-POSTURE.md`: entitlements + hardened-runtime/library-validation/notarization audit, no-sandbox rationale, Sparkle update-path review (EdDSA, HTTPS appcast), Services surface; socket posture already verified healthy (0o600 + umask + peer-UID). Add a per-surface **don't-persist-scrollback** option (`OptionStore` key → `ScrollbackFile` gate + file removal on enable; CLI plumb; document the secrets-at-rest decision even where the answer is "won't redact"). Focused IME checklist pass with small fixes — lands cleanly in the `+IME` extension file post-PR-30.
- *Files:* `Harness.entitlements`, signing scripts (audit only), `ScrollbackFile.swift`, `SurfaceRegistry.swift`, `HarnessSettings.swift`, IME extension, new doc.
- *Tests:* scrollback-gate unit + live-daemon test; IME regression tests where automatable.
- *Risk:* low.

### Phase E — bench-gated micro-pass

**PR-37 · Measured micro-pass (strictly bench-gated)** · performance · S–M · **last code PR**
- *Why:* Remaining micro-candidates that are real in code but unproven in effect. The rule: **anything that doesn't move `make bench-check` beyond noise gets dropped**, and the PR body lists what was dropped with numbers.
- *Candidates:* `RenderCell` cluster-`String` allocation per combining-mark cell (`TerminalFrame.swift:91-97` — add a combining-heavy benchmark first if none exists); prompt-gutter dictionary rebuilt per frame (`TerminalFrame.swift:614-626`); **F78** `RenderCell` pool + ligature-scratch reuse (sanctioned by the old roadmap); cross-module-optimization experiment — `Scripts/build-release.sh` currently runs plain `swift build -c release`; try `-Xswiftc -cross-module-optimization` for release artifacts only, keep only if bench-check shows wins with the full suite green (document compile-time cost). *(Shaped-run eviction is NOT here — already amortized, see Ground truth.)*
- *Files:* `TerminalFrame.swift`, `GlyphRasterizer.swift`/renderer pools, `Scripts/build-release.sh`.
- *Tests:* `make bench-check` is the gate; `bench-record` only for deliberate baseline improvements, called out per-entry.
- *Risk:* low.

---

## Deliberate non-goals (carried forward — do NOT build)

Unchanged from [AUDIT_ROADMAP.md § non-goals](AUDIT_ROADMAP.md): OSC 52 clipboard-**read** default-allow (safe-deny stays; if ever added, default-deny `ask` only); DECCOLM 132-col + CSI t window resize/move; SGR framed/encircled; dynamic OSC 4/10/11/12 color **SET** except as the sanctioned per-surface-override-layer design (theme owns the canvas; never corrupt persisted theme state); legacy mouse modes X10/1015/1005/2027/80 (1016 ships in PR-29); Kitty graphics animation + iTerm2 multipart; full tmux status window-list port (native GUI tab bar substitutes); any retries/session-manager/supervisor abstraction; **redesigning `SurfaceRegistry`'s single-lock seam** (decomposition in PR-31 is strictly mechanical).

## Conventions & verification (every PR)

- Branch per PR off latest `main`; squash merge; Bugbot + CI (macOS full suite, Linux headless) green before merge.
- **Every PR body includes a "Before merging — run on a Mac" checklist** — web-sandbox sessions cannot compile Swift/Metal for macOS. Expected failure classes from the #139 precedent: helpers referenced but never written; Swift 6 mutable statics (→ `nonisolated(unsafe)` only with a documented single-threaded contract); Linux corelibs gaps (atomic replace = POSIX `rename(2)`, not `replaceItemAt`); store write-then-reload tests must call `flush()` (saves are debounced 150 ms since #139); engine scrollback math (trailing `\r\n` leaves an empty cursor row: history = fed − (nrow−1); trim is phase-dependent within cap…cap+slack — pin targets at an observed trim).
- Smallest correct diff; `@MainActor` for AppKit; no off-main `NSView` mutation; comments only for non-obvious invariants.
- Tests required per PR; daemon/PTY changes also run `HARNESS_LIVE_DAEMON_TESTS=1 swift test` locally.
- Perf claims need `make bench-check` receipts; `bench-record` only for deliberate baseline changes, called out in the PR body. Idle-efficiency claims need `powermetrics` before/after numbers.
- Engine/renderer refactors must be **byte-identical** (golden/differential suites); `applyHighlights` stays byte-identical-by-construction.
- `CHANGELOG.md` `[Unreleased]` entry per user-visible PR; `TMUX_PARITY.md` updated honestly wherever behavior diverges; `docs/AGENT-HANDBOOK.md` synced for renderer/IPC changes.

## Release — v1.10.0 (owner-triggered when the queue lands)

1. Full suite (macOS) + Linux CI green; `HARNESS_LIVE_DAEMON_TESTS=1` locally; `make bench-check` clean (investigate drift **before** tagging).
2. `make preview` smoke + `Scripts/measure-fluidity.sh`; run `Scripts/scorecard.sh`, commit results to `docs/SCORECARD.md`.
3. CHANGELOG `[Unreleased]` (already carrying #139) rolled to `1.10.0`; `make release-notes` regenerated; Info.plist + `HarnessVersion.swift` bumped together.
4. Standard runbook: dispatch `release.yml` (tag, `deploy_appcast=true`) → verify run `headSha` == pushed tip → approve the `release` environment → signed/notarized DMG + appcast live.
