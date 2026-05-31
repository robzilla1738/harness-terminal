# Harness CLI — PR Review, Verify & Merge Runbook

> **Purpose.** A step-by-step runbook for an IDE coding agent (or a human) to go
> through every open pull request on `robzilla1738/harness-cli`, **verify each one
> actually builds and passes its tests on a real machine**, resolve conflicts in
> the right order, and merge them into `main` cleanly.
>
> Feed this file to your local IDE assistant and work top-to-bottom.

---

## 0. Read this first — critical context

- **This is a native macOS app.** It uses AppKit, Metal, CoreText, QuartzCore,
  UserNotifications and Sparkle. The GUI/renderer targets (`HarnessApp`,
  `HarnessTerminalKit`, `HarnessTerminalRenderer`) **only build on macOS**.
- **Every open PR was authored in a Linux container with no Swift toolchain.**
  That means the code was *verified by close reading, not compiled*. **CI / your
  local `swift build` + `swift test` on a Mac is the first real compile.** Treat
  green CI (or a clean local macOS build+test) as a hard gate before merging
  anything. Do **not** trust the "looks correct" notes in the PR bodies as proof.
- **Pure-Swift targets** (`HarnessCore`, `HarnessTerminalEngine`, `HarnessCopyMode`,
  `HarnessTheme`) build and test on Linux too, so some suites can be checked
  off-Mac — but the authoritative run is on macOS.
- **Known pre-existing test exceptions on Linux** (these pass on the macOS CI
  runner — do not treat as regressions): `testImageDecoderDecodesPNG`,
  `testITerm2InlineImagePlaces` (need ImageIO), and `testURLAutoDetection` (needs
  `NSDataDetector`).
- **Some daemon tests are gated** behind a live-daemon flag
  (`skipUnlessLiveDaemonTests()`); `SurfaceRegistryTests` runs without a socket,
  `DaemonRoundTripTests` needs the gate enabled.

---

## 1. Prerequisites (do once)

```sh
# On macOS with Xcode (latest stable) installed:
git clone https://github.com/robzilla1738/harness-cli.git
cd harness-cli
xcodebuild -version        # confirm Xcode/Swift toolchain present
swift --version            # Swift 6.x expected

# Baseline: main must be green before you start merging onto it.
git checkout main && git pull
swift build
swift test
```

If `main` is not green to begin with, fix that first — otherwise you can't tell
which PR broke what.

---

## 2. The per-PR loop (apply to every PR below)

For each PR, in the recommended order from §3:

```sh
# 1. Get the branch.
git fetch origin
git checkout <branch>           # branch names are listed per-PR below
git rebase origin/main          # bring it up to date; resolve conflicts (see §3 hotspots)

# 2. Build + test on macOS (the real gate).
swift build
swift test                      # full suite
swift test --filter <PRsuite>   # plus the PR-specific suites listed per-PR

# 3. Manual smoke (per-PR "Manual check" section), if applicable.

# 4. Only if build + tests + smoke pass: merge to main.
#    Option A — local fast merge:
git checkout main
git merge --no-ff <branch> -m "Merge #<n>: <title>"
swift build && swift test       # re-verify main after the merge
git push origin main

#    Option B — merge button on GitHub (after rebase/push of the branch),
#    then pull main locally and re-run swift build && swift test.
```

**Rules**
- Never merge a PR whose `swift build` or `swift test` fails on macOS.
- After **each** merge, re-run `swift build && swift test` on `main` before
  starting the next PR. Merges interact (see §3); a clean PR can still break main.
- If a rebase conflict is non-trivial, resolve it favoring **both** behaviors and
  re-run that PR's specific test suite to confirm the merge didn't drop logic.

---

## 3. Recommended merge order & conflict hotspots

Two PRs are independent of the renderer/engine cluster and safe to land first.
The remaining six all touch a small set of hot files and **will conflict with
each other** — order matters, and each later one must be rebased on the updated
`main`.

### Merge order

| Step | PR | Branch | Why this slot |
|------|----|--------|---------------|
| 1 | **#2** Notifications fix | `claude/notification-system-reliability-UNz92` | Independent (HarnessCore/CLI/onboarding); fixes a real user-facing bug. |
| 2 | **#9** Agent listing | `claude/harness-cli-agents-display-iZ3m0` | Independent (HarnessCore/daemon/CLI/app). Minor overlap with #2 only in onboarding/completions — rebase if needed. |
| 3 | **#6** Ring-buffer scrollback | `claude/ring-buffer-scrollback-cL2M2` | Foundational `TerminalScreen` storage swap; land before the other engine PRs that edit `TerminalScreen`. |
| 4 | **#7** ASCII fast path | `claude/ascii-fast-path-pp7Qk` | Edits `TerminalScreen`/`VTParser`/`TerminalEmulator`. Rebase on #6. |
| 5 | **#5** Dirty-row tracking | `claude/dirty-row-tracking-ic1ll` | Edits `TerminalScreen`/`TerminalEmulator`/`FrameBuilder`/`HarnessTerminalSurfaceView`. Rebase on #6+#7. |
| 6 | **#4** Skip background quads | `claude/skip-default-bg-quads-ic1ll` | Edits `FrameBuilder`/`RenderCell`/`TerminalMetalRenderer`. Rebase on #5 (FrameBuilder). |
| 7 | **#3** Pooled Metal buffers | `claude/terminal-buffer-pooling-ic1ll` | Edits `TerminalMetalRenderer`. Rebase on #4. |
| 8 | **#8** Render scheduler | `claude/render-scheduler-rJ4Xc` | Edits `HarnessTerminalSurfaceView`. Rebase on #5 (which also touches `renderNow`). |

### Conflict hotspot map (files touched by more than one PR)

| File | PRs that touch it | Note |
|------|-------------------|------|
| `Packages/HarnessTerminalEngine/.../TerminalScreen.swift` | #5, #6, #7 | Biggest collision. #6 swaps the history container; #7 adds `printASCIIRun`; #5 adds damage marking on every mutation. Land #6 → #7 → #5 and re-verify engine tests after each. |
| `Packages/HarnessTerminalEngine/.../TerminalEmulator.swift` | #5, #7 | #7 adds `parserPrintRun`/`feedScalarwise`; #5 adds `consumeDamage()`. |
| `Packages/HarnessTerminalRenderer/.../FrameBuilder.swift` | #4, #5 | #5 adds incremental rebuild (`reusing:`/`damage:`); #4 adds `drawBackground` per cell. |
| `Packages/HarnessTerminalRenderer/.../TerminalMetalRenderer.swift` | #3, #4 | #3 pools instance buffers; #4 gates the background instance on `drawBackground`. |
| `Packages/HarnessTerminalKit/.../HarnessTerminalSurfaceView.swift` | #5, #8 | #5 rewires `renderNow` to consume damage; #8 rewires `scheduleRender`/adds the display link. Resolve so the display-link tick still calls the damage-aware `renderNow`. |
| `RenderCell` type (in HarnessTerminalRenderer) | #4 (writes), #5 (reads) | #4 adds the `drawBackground` field. |

> Tip: after resolving a `TerminalScreen`/`FrameBuilder` conflict, run that PR's
> specific suite (e.g. `--filter FrameBuilderTests`) **and** the broad
> `HarnessTerminalEngineTests` to catch dropped logic.

---

## 4. Per-PR dossiers

All PRs branch from `main@f3bed37`. For each: confirm CI is green on GitHub (or
build+test locally) **before** merging.

### PR #2 — Fix Claude Code notifications: read hook message from stdin
- **Branch:** `claude/notification-system-reliability-UNz92`
- **What/why:** The Claude Code `Notification` hook read `$HARNESS_NOTIFY_MESSAGE`
  (never set) so every banner fired blank. Reads the message from the hook's
  **stdin JSON** instead, via a new `harness-cli notify --from-hook`. Also makes
  `install` self-healing (idempotent re-install, no duplicate hooks) and adds
  first-run agent detection/offer.
- **Key files:** `HarnessCore` `HookNotificationParser`, `AgentHookInstaller`,
  CLI `notify`, `HarnessOnboarding` Setup step, `docs/agent-hooks/*`.
- **Verify:**
  ```sh
  swift build
  swift test --filter HookNotificationParserTests
  swift test --filter AgentHookInstallerTests
  swift test --filter JSONMergeTests
  ```
- **Manual check:** `harness-cli install-hooks claude-code`, trigger a Claude Code
  notification, confirm the banner body is non-empty; re-run `install-hooks` and
  confirm the hooks file has exactly one Harness entry (no duplicate). See the
  PR's `HANDOFF.md`.
- **Acceptance:** notification body non-empty; re-install idempotent; user/non-Harness
  config keys preserved; build+tests green.

### PR #9 — Agent listing: daemon request, CLI (text + JSON), Agent Inbox
- **Branch:** `claude/harness-cli-agents-display-iZ3m0`
- **What/why:** Adds `harness-cli list-agents [--waiting] [--json]`, a new
  `.listAgents` daemon request/response, an `AgentSessionSummary` model, a
  formatter, and a minimal GUI Agent Inbox. Reads existing agent state
  (`Tab.agent`, `Tab.status == .waiting`) — no new detection.
- **Key files:** `HarnessCore` `Agents/AgentSessionSummary.swift`,
  `Format/AgentListFormatter.swift`, `Session/SessionEditor.swift`,
  `IPC/IPCMessage.swift`; `HarnessDaemon/SurfaceRegistry.swift`;
  CLI `HarnessCLI.swift`; `HarnessApp` `AgentInboxPanelView.swift`,
  `SessionCoordinator.swift`, `HarnessSidebarPanelViewController.swift`;
  fish-completion sources.
- **Verify:**
  ```sh
  swift build
  swift test --filter HarnessCoreTests      # AgentSessionSummary + AgentListFormatter
  swift test --filter HarnessDaemonTests     # SurfaceRegistryTests (non-gated)
  ```
- **Manual check:** with the daemon running and an agent in a pane:
  `harness-cli list-agents`, `harness-cli list-agents --waiting`,
  `harness-cli list-agents --json | jq .`. In the app, open the Agent Inbox from
  the sidebar footer; confirm rows + jump-to-tab, and that the notification bell
  still works.
- **Acceptance:** list works; `--waiting` filters; `--json` is valid; existing
  notifications unchanged; build+tests green.

### PR #6 — Ring-buffer scrollback (drop array front-shifting)
- **Branch:** `claude/ring-buffer-scrollback-cL2M2`
- **What/why:** Replaces the `[HistoryLine]` scrollback with a growable-deque
  `HistoryRingBuffer`, so trimming the oldest line is a head-index advance instead
  of an O(n) shift. No behavior change.
- **Key files:** `HarnessTerminalEngine` new `HistoryRingBuffer.swift`,
  `TerminalScreen.swift` (storage type + reflow assignment only).
- **Verify (Linux-OK, but confirm on macOS):**
  ```sh
  swift build
  swift test --filter HistoryRingBufferTests
  swift test --filter ScrollbackTests
  swift test --filter ImageProtocolTests
  swift test --filter HarnessTerminalEngineTests
  ```
- **Acceptance:** all engine tests green; scrollback/capture/reflow/image eviction
  behavior identical to before.

### PR #7 — Fast path for contiguous printable-ASCII output
- **Branch:** `claude/ascii-fast-path-pp7Qk`  → **rebase on #6**
- **What/why:** Batches a contiguous ground-state ASCII run into one
  `parserPrintRun` handled by a per-row `printASCIIRun`, byte-for-byte equivalent
  to scalar printing. ~1.1–1.6× faster on ASCII-heavy output.
- **Key files:** `HarnessTerminalEngine` `VTParser.swift`,
  `TerminalEmulator.swift`, `TerminalScreen.swift`; `Tests/HarnessBenchmarks`.
- **Verify:**
  ```sh
  swift build
  swift test --filter AsciiFastPathTests          # run-vs-scalar snapshot equality
  swift test --filter HarnessTerminalEngineTests
  HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks   # optional perf
  ```
- **Acceptance:** snapshot-equality tests pass (no behavior change); engine suite
  green; benchmarks run.

### PR #5 — Dirty-row tracking + incremental frame rebuild
- **Branch:** `claude/dirty-row-tracking-ic1ll`  → **rebase on #6, #7**
- **What/why:** `TerminalScreen` marks changed rows; `consumeDamage()` returns a
  `TerminalDamage`; `FrameBuilder.build` can reuse the previous frame and rebuild
  only dirty rows on the plain live path. Clean rows are byte-identical.
- **Key files:** `HarnessTerminalEngine` `TerminalScreen.swift`,
  `TerminalEmulator.swift`; `HarnessTerminalRenderer` `FrameBuilder.swift`;
  `HarnessTerminalKit` `HarnessTerminalSurfaceView.swift` (`renderNow`).
- **Verify:**
  ```sh
  swift build
  swift test --filter DamageTrackingTests   # GPU-free
  swift test --filter FrameBuilderTests      # incremental == full rebuild
  swift test                                 # full suite on macOS
  ```
- **Manual check:** type/scroll/resize/select/copy-mode in the app — no visual
  glitches; selection/scrollback/IME force a full rebuild correctly.
- **Acceptance:** incremental builds byte-identical to full; no visual change;
  build+tests green on macOS.

### PR #4 — Skip background quads for default-canvas cells
- **Branch:** `claude/skip-default-bg-quads-ic1ll`  → **rebase on #5**
- **What/why:** Adds `drawBackground: Bool` to `RenderCell`; the Metal renderer
  emits a background instance only when set. Pixel-identical (the clear color *is*
  the default canvas background).
- **Key files:** `HarnessTerminalRenderer` `FrameBuilder.swift`, `RenderCell`,
  `TerminalMetalRenderer.swift`.
- **Verify:**
  ```sh
  swift build
  swift test --filter FrameBuilderTests
  swift test --filter FrameBuilderCopyModeTests
  swift test --filter MetalRendererTests     # self-skips without a GPU
  swift test
  ```
- **Manual check:** normal text, colored backgrounds, selection, search
  highlights, cursor, and the copy-mode status band all render unchanged.
- **Acceptance:** golden/frame tests green; no visual change; build+tests green.

### PR #3 — Reuse pooled Metal instance buffers
- **Branch:** `claude/terminal-buffer-pooling-ic1ll`  → **rebase on #4**
- **What/why:** Replaces per-frame `makeBuffer(bytes:)` with a triple-buffered
  pool of growable shared Metal buffers + an in-flight semaphore, so steady-state
  rendering is just a `memcpy`. Includes `docs/HANDOFF-terminal-buffer-pooling.md`.
- **Key files:** `HarnessTerminalRenderer` new `DynamicInstanceBuffer.swift`,
  `TerminalMetalRenderer.swift`.
- **Verify (needs a GPU for the golden tests):**
  ```sh
  swift build
  swift test --filter MetalRendererTests     # incl. reuse-without-corruption
  swift test
  ```
- **Manual check:** run the app under heavy output (`cat` a big file, noisy build)
  and watch for any flicker/tearing/corruption across many frames.
- **Acceptance:** golden tests stable; no visual corruption under load;
  build+tests green.

### PR #8 — Display-cadence render scheduler
- **Branch:** `claude/render-scheduler-rJ4Xc`  → **rebase on #5**
- **What/why:** Coalesces rendering to at most one present per display tick via a
  testable `RenderScheduler` + a main-thread `CADisplayLink`, while keeping
  resize/first-paint synchronous and DEC 2026 synchronized output intact.
- **Key files:** `HarnessTerminalKit` new `RenderScheduler.swift`,
  `HarnessTerminalSurfaceView.swift`.
- **Verify:**
  ```sh
  swift build
  swift test --filter RenderSchedulerTests   # 9 cases; logic is GPU-free
  swift test
  ```
- **Manual check:** heavy output doesn't peg CPU/GPU; cursor blink works; resize
  is flicker-free; an idle terminal uses ~no CPU (link re-pauses).
- **Acceptance:** scheduler tests green; behaviors above hold; build+tests green.

---

## 5. After everything is merged

```sh
git checkout main && git pull
swift build
swift test                                   # full suite must be green
HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks   # optional
```

Then do a real end-to-end smoke of the app:
- Launch `Harness.app`, open a few panes, run a heavy-output command.
- Exercise scrollback, resize, selection, copy-mode, images, prompt marks.
- Trigger an agent notification; confirm the bell + `harness-cli list-agents`.
- Confirm no visual regressions vs. pre-merge `main`.

---

## 6. If something fails

- **Build fails after a rebase:** the conflict resolution dropped or duplicated
  logic in a hotspot file (§3). Re-open the PR diff, re-apply the intended change,
  re-run that PR's `--filter` suite.
- **A test fails only on macOS:** that's the real signal these PRs never compiled.
  Read the failure, fix in the PR branch, push, re-verify, then merge.
- **A merged PR breaks main:** `git revert -m 1 <merge-commit>` to back it out,
  fix on the branch, and re-merge. Don't stack more PRs on a red `main`.
- **Pre-existing Linux-only failures** (ImageIO/NSDataDetector tests) are expected
  off-Mac — not a regression.

---

### Quick reference

| PR | Branch | Primary suites to run |
|----|--------|------------------------|
| #2 | `claude/notification-system-reliability-UNz92` | HookNotificationParserTests, AgentHookInstallerTests, JSONMergeTests |
| #9 | `claude/harness-cli-agents-display-iZ3m0` | HarnessCoreTests, HarnessDaemonTests |
| #6 | `claude/ring-buffer-scrollback-cL2M2` | HistoryRingBufferTests, ScrollbackTests, ImageProtocolTests |
| #7 | `claude/ascii-fast-path-pp7Qk` | AsciiFastPathTests, HarnessTerminalEngineTests |
| #5 | `claude/dirty-row-tracking-ic1ll` | DamageTrackingTests, FrameBuilderTests |
| #4 | `claude/skip-default-bg-quads-ic1ll` | FrameBuilderTests, FrameBuilderCopyModeTests, MetalRendererTests |
| #3 | `claude/terminal-buffer-pooling-ic1ll` | MetalRendererTests |
| #8 | `claude/render-scheduler-rJ4Xc` | RenderSchedulerTests |

_All branches base off `main@f3bed37`. Verify CI green on GitHub or build+test on
macOS before merging each one._
