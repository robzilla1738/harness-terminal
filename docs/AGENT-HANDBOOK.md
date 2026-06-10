# Agent handbook — Harness (extended reference)

Entry point: [../claude.md](../claude.md) (slim agent context). **Not** loaded by default — open when editing the renderer, compositor, daemon IPC, UI chrome, or test matrix.

Update this file together with `claude.md` / `agents.md` when those sections change.

## Table of contents

- [Native terminal renderer](#native-terminal-renderer)
- [Repository map](#repository-map)
- [IPC](#ipc)
- [harness-cli](#harness-cli)
- [Terminal compositor (`attach-window`)](#terminal-compositor-attach-window)
- [Settings](#settings)
- [Agent integration](#agent-integration)
- [UI and key classes](#ui-and-key-classes)
- [Build and test](#build-and-test)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)

---

## Native terminal renderer

Harness renders terminals with its **own** self-contained stack — there is **no
third-party terminal engine dependency** (the entire terminal stack is first-party; the only
external package is Sparkle, GUI auto-update only). `TerminalHostView`
hosts `HarnessTerminalSurfaceView` (a `CAMetalLayer` view) driving `HarnessTerminalEngine`
(VT parser + screen/scrollback), `HarnessTheme` (490-theme catalog + `.harnesstheme`), and
`HarnessTerminalRenderer` (CoreText atlas + Metal). Features: themed translucent canvas with
untouched program output (`applyThemeToTerminalOutput` toggles theme-colored output), balanced
window padding (centered grid) + a live resize HUD, cursor styles + blink (DECSCUSR; `0` / a
bare `CSI SP q` resets to the *user-configured* style — the Ghostty/kitty semantics, not a hard
blinking block — and a hollow box when the window is unfocused; a blink toggle re-encodes ≤1 row,
pinned by test), word/line (double/triple-click)
+ Option-rectangle text selection + copy /
paste (bracketed-paste aware, with paste protection) / copy-on-select / right-click menu —
selection, find highlights, and IME preedit ride damage-driven rendering via the cell-overlay
pass (see invariants below) instead of forcing per-frame full rebuilds, mouse
reporting (SGR 1006), pixel-smooth scrollback (wheel / Shift+PageUp/Down; trackpad scrolls by
sub-line fractions — `scrollFraction` renders as a whole-device-pixel vertex `scrollPx` uniform
over the unchanged row-instance cache, with a display-only peek row appended to scrolled frames
and a grid-box scissor; consumers stay line-based on the integer `scrollOffset`; OUTPUT scrolls
report a whole-viewport `TerminalDamage.scroll` hint so streaming `cat`/build frames shift-copy
the moved band instead of re-resolving the grid), reflow on
resize (drag repaints reuse the renderer row cache under the frozen origin — empty damage when
`lastPresentedResultIsRendererCoherent`, `encodedRows == 0` per sub-cell tick — while mid-drag
PTY output presents live through the scheduler inside explicit `CATransaction`s under real-time
reflow; only the reflow-off escape hatch and the main-confined pipeline keep the legacy
defer-to-the-layout-repaint hold; cell-boundary
crossings build their re-wrap preview ASYNC on the emulator queue — latest-wins preview token,
landed via `presentResizePreview` with generation/token/target stale-drop guards — so a boundary
tick costs main no more than a sub-cell tick, and the renderer salvages content-identical rows
across the column change via per-row `contentKey`s; instance data lives in persistent flat
arrays + a per-row segment table mutated in place per dirty row — the Ghostty `Contents` model —
with span-list incremental GPU uploads), optional WCAG
`minimum-contrast`, a bundled Nerd Font symbol fallback (Powerline/icon glyphs always render),
procedurally-rendered block elements + box-drawing (seamless, font-independent), and IME / dead
keys (`NSTextInputClient`).

The opt-in config import (`TerminalConfigImporter`) reads compatible source-terminal configs so
users moving in keep their colors/font — kept by product decision.

**Before touching the terminal renderer or theme system, read the relevant package entry points under `Packages/` and keep [../claude.md](../claude.md) authority rules in mind:**
`HarnessTerminalEngine`, `HarnessCopyMode`, `HarnessTheme`, `HarnessTerminalRenderer`,
`HarnessTerminalKit`.

**Renderer/engine invariants** (recently hardened — keep these):
- **Block elements** (`U+2580–U+259F`) and **box-drawing** (`U+2500–U+257F`) render
  *procedurally*, not from the font, so they tile seamlessly:
  blocks as exact-fill rects in the background pass (`TerminalMetalRenderer.blockElementRects`),
  box-drawing as cell-sized sprites (`BoxDrawing` → `GlyphRasterizer.rasterizeBox`, drawn at the
  cell origin via `bearingX 0` / `bearingY = ascent`). Doubles, diagonals and mixed-weight
  variants fall back to the font. The glyph emitters skip these codepoints.
- **Bounded work per sequence (hostile-output DoS guards):** `scrollUp`/`scrollDown` clamp the
  iteration count to the scroll-region height (a giant `\e[65535S` past that point only re-blanks
  an already-blank region); **CNL/CPL** (`cursorNextLine`/`cursorPrevLine`) are *cursor moves*
  (clamped `moveCursorRelative` + CR, like CUD/CUU) — they never loop `lineFeed`, matching ECMA-48
  and removing the 65k-scroll spin. Image decoders clamp too: the Sixel `!Pn` repeat is bounded to
  the remaining row width, and `kittyPending` caps the number of concurrently-reassembling image
  ids (per-image bytes were already capped). Keep these clamps — they're the difference between a
  malformed/hostile stream re-blanking a region and one freezing the engine thread.
- **CSI private introducers** `< = > ?` are *all* flagged private in `VTParser` — so `\e[>4;1m`
  (XTMODKEYS, emitted by fish at startup) is never misread as SGR `4;1m` (the old bug: a
  permanently bold + underlined prompt). SGR is never a private sequence.
- **Parser fast paths (byte-identical to the scalar path — non-negotiable):** `VTParser.feedBuffer`
  batches contiguous printable runs so the per-byte state machine is the exception, not the rule. A
  **SIMD16 scan** (`printableASCIIRunEnd`, stop mask `(b &- 0x20) >= 0x5F`, full vectors + scalar tail,
  never reads past the buffer) finds the end of an ASCII run; a **bulk-UTF-8 decoder**
  (`decodePrintableRun` → `parserPrintCodepointRun` → `TerminalScreen.printCodepointRun`) decodes a
  printable ASCII+UTF-8 run into a reused codepoint buffer and writes it in one pass (template once,
  row marked once, per-scalar width / wide-head+spacerTail / pending+autowrap exactly as `print`). Any
  UTF-8 anomaly (invalid lead, short/invalid continuation, overlong, surrogate, out-of-range, or a
  sequence truncated by the buffer end) is **deferred to the per-byte `feed`**, which keeps sole
  ownership of the U+FFFD-replacement, reprocess-fresh, and cross-`feed`-call carry semantics — so the
  bulk path only ever handles clean text. The parser holds its handler **`unowned`** (not `weak`; the
  emulator owns it) to drop the per-emit ARC weak-load. DEC special graphics still replays scalar-wise.
  ALL of this MUST stay byte-for-byte equal to `feedScalarwise` — proven by `AsciiFastPathTests` (incl.
  a SIMD boundary-offset test) + `CodepointRunFastPathTests` (well-formed unicode + every malformed
  class, each at 8 chunk-splits). Runtime kill-switch: `HARNESS_DISABLE_BULK_UTF8=1` reverts to the
  per-byte decode. `IL`/`DL`/`ICH`/`DCH` shift via `memmove` like `scrollUp`/`scrollDown`
  (`TerminalGridCell` is a trivial value type). `FrameBuilder` resolves `RenderColor` channels via a
  256-entry LUT (bit-identical to the `Float(i)/255` divide it replaces).
- **Resize:** `HarnessTerminalSurfaceView.updateGridSize` *rounds* the drawable (no edge seam
  under `.topLeft`) and `layout()` renders synchronously inside a `CATransaction` (no stretch
  flicker). The drawable resizes every frame; the authoritative **grid reflow + PTY `SIGWINCH`**
  fire per path:
  - **Real-time (default, Ghostty parity, `liveResizeReflow` on):** during a window-edge drag
    (`presentsWithTransaction`), `requestLiveResizeCommit` commits the reflow + SIGWINCH at every
    cell boundary so interactive programs redraw live. The reflow target is staged queue-side
    (`SurfaceEmulatorState.pendingResize`) and materialized by the NEXT output/commit build to
    run — builds coalesce latest-wins (the `renderNowOffMain` frame token), and the staging is
    what lets a superseding output build carry the resize forward instead of stranding the grid
    at a pre-vote size when it cancels an in-flight commit build. Mid-drag PTY output presents
    live (each landing flushes its own explicit `CATransaction`, so no layout pass is needed when
    the pointer holds still), the PTY vote coalesces per-fd (`TerminalHostView.resize` epoch) +
    to distinct cell counts (`lastSentPTYSize`), and there is no main-thread generation bump —
    the builder caches are cleared on the queue when the resize applies, so `repaintLastFrame`
    keeps stretching the cached frame between boundaries with no synchronous rebuild.
  - **Animated / escape-hatch (`liveResizeReflow` off, or sidebar slide / tiling):** the reflow +
    SIGWINCH are **coalesced** (`scheduleResizeCommit`, ~60ms debounce, kept in lockstep via
    `commitGridSize`) and the non-mutating `previewViewportReflow` shows a live re-wrap; firing
    the reflow + SIGWINCH every frame of an *animation* storms the shell. `viewDidEndLiveResize`
    flushes the settled commit at release.

  The first sizing commits immediately (no open-flash). `TerminalScreen.resize` *reflows* the
  primary screen — rejoin soft-wrapped rows via a per-row wrap flag, re-wrap to the new width
  (wide chars never split), map the cursor; the alternate screen just clamps (TUIs redraw on
  SIGWINCH). The rewrap is a streaming pass (`rewrapRows`): source rows arrive by reference
  through a closure (history arrays are never gather-copied), logical lines are tracked as row
  extents + effective lengths, and lines without wide glyphs — the overwhelming majority —
  re-wrap as `nc`-sized bulk slice copies (~10ms per width change at the 10k-line scrollback
  cap, 3× the per-cell predecessor; wide-bearing lines keep the per-cell stepping loop, byte-
  identical against the `ReflowGolden/` corpus). The PTY env sets `COLORTERM=truecolor`.
- **Decorations** (underline/strike/overline) are pixel-snapped for crisp 1–2px lines.
- **Glyph baseline** is pixel-snapped at rasterization: `GlyphRasterizer.render` draws each glyph
  with its pen origin (baseline + left edge) on integer device pixels, so every glyph shares the
  exact same baseline row. Drawing at a fractional position while rounding the bearing
  independently (the old path) left a sub-pixel residual per glyph — a wavy / "squiggly" baseline.
  Glyph rasterization uses grayscale antialiasing with CoreGraphics font smoothing disabled; the
  explicit `textRendering`/glyph-gamma setting is the only intentional text-weight control.
- **Nerd Font / Powerline glyphs never tofu:** the app bundles **Symbols Nerd Font Mono** (MIT,
  `Apps/Harness/Resources/Fonts/`) auto-activated via Info.plist `ATSApplicationFontsPath` — NOT a
  SwiftPM `Bundle.module` resource (that footgun crashed the app for the theme catalog; see the
  `Package.swift` note). `GlyphRasterizer` resolves the user font robustly (a family-name
  descriptor retry when `CTFontCreateWithName` silently substitutes a non-Nerd system font) and
  falls back to the bundled symbol font for PUA codepoints (`isNerdFontCodepoint`: `U+E000–F8FF`,
  `U+F0000–FFFFD`); `TerminalMetalRenderer` routes those codepoints out of the ligature shaper to
  the per-cell path (where the fallback applies), since CoreText shaping is what substituted a
  LastResort "missing glyph" box. The fallback ships in three build paths (`package-app.sh`,
  `preview.sh`, `project.yml`).
- **Hollow cursor:** unfocused (`CursorRender.hollow = !focused`) the cursor draws as a 1px box
  outline regardless of style (full alpha — `bgPipeline` has `blending: false`, so a dim-via-alpha
  approach would be a no-op), and a hollow block does not invert its glyph
  (`CursorCacheKey.invertsGlyph` folds in `!hollow`, dirtying the cursor row on a focus change).
- **Cell-overlay pass (selection / find / IME never disable damage-driven rendering):** the live
  view (`scrollOffset == 0`) ALWAYS builds clean — incremental, damage-driven, with
  `lastPlainFrame`/`lastViewportFrame` kept warm — and the overlay rows of a COPY are re-shaded
  per present via `FrameBuilder.applyHighlights` (which re-runs the exact same private
  `appendRow` the baked path uses, so shaded rows are **byte-identical by construction**; IME
  preedit applies after via `applyPreedit` as before). Per-row overlay FINGERPRINTS
  (`HarnessTerminalSurfaceView.overlayRowKeys`, geometry-hashed — no cell walks; stored
  queue-side in `SurfaceEmulatorState.lastOverlayKeys`) diff against the previous build and
  union exactly the changed rows into the render damage: a selection drag re-encodes the rows it
  crossed, a static highlight adds zero per-frame work, clearing dirties exactly the old rows.
  Scrolled views (offset > 0) and copy mode keep the baked full-rebuild path; the legacy
  main-confined pipeline is deliberately unoptimized (still correct — see the damage hint below).
- **Whole-viewport scroll damage hint (`TerminalDamage.scroll` + `scrolledRows`) — purely
  additive:** `rows` stays COMPLETE (the moved band is still listed), so hint-unaware consumers
  (compositor, CLI attach, the main-confined pipeline) redraw exactly what they did before the
  hint existed; only opted-in consumers shift-copy. `TerminalScreen` moves pre-scroll content
  marks WITH the content (damage is always current-coordinate), accumulates whole-viewport
  shifts arithmetically (SU then SD composes soundly), and POISONS the hint — degrading to the
  old whole-region mark — for anything it can't describe (sub-region scrolls, a net shift
  covering the grid, full damage). `FrameBuilder.buildShifted(freshRows:)` re-resolves the fresh
  band and shift-copies the rest; the renderer rotates its row-instance cache via the same
  `scrollShift` machinery scrollback scrolls use. Differentially pinned byte-identical
  (`testBuildShiftedWithFreshRowsMatchesFullBuildOnOutputScroll`).
- **Occlusion gating:** `RenderScheduler.isOccluded` (ANDed into `hasPendingWork` and the
  `presentNow` echo gate) holds every present while the hosting window is covered/minimized —
  the display link pauses even under output flood; parsing and dirty marks continue, and
  un-occlusion presents the accumulated damage as one fresh frame. Driven by
  `NSWindow.didChangeOcclusionStateNotification` with **no attach-time seed** (a window never
  ordered on screen reads as non-visible — every headless test window — so seeding would wrongly
  gate those); `forceRender` stays ungated and `scheduler.stop()` resets the flag on re-host.
- **Frame pacing / telemetry:** on variable-refresh (ProMotion) panels the render display link
  requests the panel's full rate via `preferredFrameRateRange` (min 60 so the system can adapt
  down; re-applied on backing-property changes; the link still pauses at idle).
  `FrameSignposter` flush lines report p50/p95/**p99**/max and split dropped presents by cause
  (`nilDrawable` = pool exhaustion vs `encodeFailure`) — `presentFrame` returns a
  `PresentAttempt`, not a `Bool`.
- **Minimum contrast** (`CellColorResolver.minimumContrast`, default 1 = off, byte-identical):
  after faint / before inverse, the foreground is lifted toward black/white until it meets the WCAG
  ratio (symmetric, so it survives an inverse swap; conceal still wins). Imported from a source
  config's `minimum-contrast`.
- **Balanced padding** (`window-padding-balance`, default on): `updateGridSize` splits the sub-cell
  remainder onto both sides so the grid is centered, and `gridOriginPoints*` keeps mouse
  hit-testing / link-hover / IME anchoring aligned with the centered origin. The **resize HUD**
  (`ResizeHUDView`, hosted by `TerminalHostView`) shows the live grid size via the surface's
  `onGridSizeWillChange` callback, gated by the `resize-overlay` setting (suppressed on first open).

---

## Repository map

```
harness/
├── Package.swift, project.yml, Makefile, Harness.entitlements
├── Harness.xcodeproj/             # generated via xcodegen
├── .github/workflows/ci.yml       # swift build/test + non-blocking benchmarks
├── claude.md / agents.md          # slim agent entry (≤40k chars)
├── docs/AGENT-HANDBOOK.md         # this file (extended reference)
├── CHANGELOG.md, design-system.md # release notes; chrome design tokens (GUI)
├── marketing/                     # HyperFrames promo video — see marketing/README.md (not app code)
├── Apps/Harness/
│   ├── Resources/Assets.xcassets, Harness.icns (generated)
│   └── Sources/HarnessApp/
│       ├── AppDelegate.swift, main.swift, Resources/Info.plist
│       ├── Services/              # SessionCoordinator, MainExecutor, KeybindingsService,
│       │                          # TerminalPaneRegistry, TerminalPaneRegistryAccess,
│       │                          # SurfaceShellTracker, CLIInstaller, DaemonLauncher,
│       │                          # DefaultTerminalManager, DefaultTerminalOpener
│       ├── Settings/              # SettingsViewController, KeyRecorderView, LiveTerminalPreview
│       └── UI/                    # MainSplit, sidebar, tabs, PrefixKeymap, CommandPrompt,
│                                  # CopyMode, StatusLine, notifications, CommandPalette, Chrome,
│                                  # DisplayPanesOverlay, AboutPanelController, HarnessControls,
│                                  # Notch/ (Agent Notch HUD)
├── Packages/
│   ├── CHarnessSys/               # C ioctl shim (variadic PTY sizing on Linux)
│   ├── HarnessCore/               # Models, IPC, SessionEditor, Commands, Keybindings,
│   │                              # Options, Events, Format, Layouts, Buffers, Agents,
│   │                              # ShellIntegration, Session/PaneRectSolver
│   ├── HarnessTerminalEngine/     # VT parser, screen/scrollback, images, input encoder
│   ├── HarnessCopyMode/           # Shared copy-mode reducer for GUI + attach-window
│   ├── HarnessTheme/              # 490-theme catalog + .harnesstheme import/export
│   ├── HarnessTerminalRenderer/   # FrameBuilder, CoreText glyph atlas, Metal renderer
│   ├── HarnessTerminalKit/        # TerminalHostView, ThemeManager, GridCompositor,
│   │                              # HarnessTerminalSurfaceView (native CAMetalLayer view)
│   ├── HarnessOnboarding/         # Embedded SwiftUI first-run wizard
│   └── HarnessDaemon/
│       ├── Sources/HarnessDaemon/ # HarnessDaemonCore: SurfaceRegistry, DaemonServer,
│       │                          # RealPty, AgentScanner
│       └── Sources/HarnessDaemonMain/main.swift
├── Tools/harness/Sources/HarnessCLI/  # HarnessCLI, AttachClient, WindowAttachClient,
│                                      # AgentHookInstaller
├── Tests/
│   ├── HarnessBenchmarks/
│   ├── HarnessCopyModeTests/
│   ├── HarnessCoreTests/
│   ├── HarnessDaemonTests/
│   ├── HarnessOnboardingTests/
│   ├── HarnessTerminalEngineTests/
│   ├── HarnessTerminalKitTests/
│   ├── HarnessTerminalRendererTests/
│   └── HarnessThemeTests/
├── Scripts/                       # build-release, package-app, preview.sh, generate-app-icon.sh,
│                                  # create-dmg.sh, sign-and-notarize.sh, generate-appcast.sh,
│                                  # finalize-release.sh, completions/
└── docs/
    ├── COMMANDS.md                # full command grammar
    ├── KEYBINDINGS.md             # default bindings + FormatString tokens
    ├── MODES.md, MIGRATION.md, MULTIPLEXER_GUIDE.md
    ├── shell-integration/         # OSC 133 bash/zsh/fish snippets
    ├── THIRD-PARTY-NOTICES.md
    └── agent-hooks/
```

### SPM products

| Product | Target | Role |
|---------|--------|------|
| `HarnessCore` | `HarnessCore` | Shared library |
| `HarnessTerminalEngine` | `HarnessTerminalEngine` | Pure Swift VT engine + grid/scrollback/images |
| `HarnessCopyMode` | `HarnessCopyMode` | Pure copy-mode state/reducer over engine grids |
| `HarnessTheme` | `HarnessTheme` | Theme catalog + `.harnesstheme` documents |
| `HarnessTerminalRenderer` | `HarnessTerminalRenderer` | Frame builder + CoreText/Metal rendering |
| `HarnessTerminalKit` | `HarnessTerminalKit` | Native terminal surface host + compositor |
| `HarnessOnboarding` | `HarnessOnboarding` | Embedded first-run wizard |
| `CHarnessSys` | `CHarnessSys` | C `ioctl` shim for PTY resize (Linux; linked by daemon/engine) |
| `Harness` | `HarnessApp` | GUI |
| `HarnessDaemon` | `HarnessDaemon` | Thin `main` over `HarnessDaemonCore` |
| — | `HarnessDaemonCore` | Testable daemon logic |
| `harness-cli` | `HarnessCLI` | CLI client (depends on terminal packages for attach/compositor) |

**One external dependency.** Every library/daemon/CLI product is first-party pure Swift; the GUI app's **only** package dependency is **Sparkle** (macOS auto-update), pinned `.upToNextMinor(from: "2.9.2")` (the audited line; `Package.resolved` locks the exact revision). `Package.swift` lists Sparkle alone, so `git clone && swift build` fetches just that one package and builds on any machine. The terminal engine, theme system, renderer, daemon core, and CLI link nothing external. The whole package builds in the **Swift 6 language mode** (complete strict concurrency everywhere); the two foundational, dependency-free libraries — `HarnessCore` and `HarnessTerminalEngine` — additionally treat **warnings as errors** (`strictFoundationSettings`) so a Sendable/data-race/deprecation warning in the layer everything builds on can't rot.

---

## IPC

JSON over `harness.sock` via `IPCEnvelope` / `IPCReply` (`IPCCodec`). Clients: `DaemonClient` (CLI), `DaemonSessionService` (app). Server: `DaemonServer` → `SurfaceRegistry`.

Extend in [`IPCMessage.swift`](Packages/HarnessCore/Sources/HarnessCore/IPC/IPCMessage.swift).

| Group | Requests (representative) |
|-------|---------------------------|
| **Health / query** | `ping`, `getSnapshot`, `listWorkspaces`, `listSurfaces`, `daemonStats`, `listClients` |
| **Layout** | `newWorkspace`, `newSession`, `newTab`, `newTabInWorkspace`, `newSplit`, `closeTab/Session/Workspace`, `closeEphemeralSessions`, `killPane`, `swapPanes`, `resizePane`, `resizePaneRatio`, `zoomPane`, `breakPane`, `joinPane`, `linkWindow`, `unlinkWindow`, `rotatePanes`, `applyLayout`, `nextLayout`, `previousLayout`, `renumberWindows`, `selectPaneDirectional`, `selectPane`, `respawnPane` |
| **Selection** | `selectWorkspace`, `selectWorkspaceByName`, `selectSession`, `selectTab`, `reorderTab`, `swapTab`, `reorderSession`, renames |
| **Metadata** | `updateTabTitle/Cwd/GitBranch`, `setTheme`, `setKeepSessionsOnQuit`, `setSessionPersistent`, `notify`, `clearNotification` |
| **PTY I/O** | `createSurface`, `ensureSurface`, `attachSurface`, `closeSurface`, `sendData`, `send`/`sendKeys`, `capturePane`, `capturePaneRange`, `pipePane`, `setCopyMode`, `resizeSurface` |
| **Streaming** | `subscribeSurfaceOutput`, `subscribeSnapshot`, `cancelSubscription`, `replayScrollback`, `detachSurface`, `identifyClient`, `detachClient` |
| **Buffers** | `setBuffer`, `getBuffer`, `listBuffers`, `deleteBuffer`, `pasteBuffer` |
| **Options / hooks / UI** | `setOption`, `showOptions`, `setEnvironment`, `showEnvironment`, `bindHook`, `unbindHook`, `listHooks`, `displayMessage`, `waitFor` |
| **Agents** | `detectAgent` |

**Responses:** `ok`, `pong`, typed IDs, `clientID`, `snapshot`, `snapshotChanged`, `text`, `data`, `agentInfo`, `clients`, `daemonStats`, `buffer`, `buffers`, `options`, `hookID`, `hooks`, `workspaces`, `surfaces`, `error`.

**IPC-only (no CLI subcommand):** `closeWorkspace`, `reorderTab`, `swapTab`, `reorderSession`, `resizePaneRatio`, `setTheme`, `setKeepSessionsOnQuit`, `setSessionPersistent` from GUI pinning, `closeEphemeralSessions`, `clearNotification`, tab metadata updates (`updateTabTitle/Cwd/GitBranch`), and streaming internals (`subscribeSurfaceOutput`, `subscribeSnapshot`, `ensureSurface`, etc.).

**markWaiting (invariant):** `notify` must resolve tab by **surface ID string** only — never mark all tabs waiting.

```swift
guard let match = editor.tab(forSurfaceKey: surfaceKey) else { return }
editor.setTabStatus(workspaceID: match.workspaceID, tabID: match.tabID, ...)
```

**Terminal I/O:** `ensureSurface` → `sendData` (GUI keys) → `subscribeSurfaceOutput` → scrollback replay on attach. `listWorkspaces.tabCount` = sidebar **session** count (legacy field name).

---

## harness-cli

Binary: `.build/{debug,release}/harness-cli`, `Harness.app/Contents/MacOS/harness-cli`, or `~/Library/Application Support/Harness/bin/harness-cli` after `install`.

Requires daemon running (app or launchd). Full flags: `harness-cli` (no args) or [docs/COMMANDS.md](docs/COMMANDS.md).

| Category | Examples |
|----------|----------|
| **Health** | `ping`, `doctor [--json]`, `daemon-stats`, `list-clients`, `detach-client --client <uuid>` |
| **Remote** | `remote add --name <n> --ssh <user@host> --socket <remote-path>`, `remote list`, `remote remove`; global `--host <name>` on every daemon command (SSH tunnel to `sessions/remote-hosts.json`) |
| **Query** | `list-workspaces`, `list-surfaces`, `list-sessions`, `list-windows`, `list-panes`, `has-session`, `get-snapshot`, `list-commands` |
| **Layout** | `new-workspace --name api`, `new-session --workspace Default --cwd ~`, `new-tab --workspace Default`, `new-split --tab <uuid> --direction horizontal`, `select-workspace/tab/session`, `rename-tab/session`, `rename-workspace --id <uuid> --name "…"`, `close-tab/session`, `promote-session`, `demote-session` |
| **Pane** | `send-keys --surface <uuid> --keys "C-c Enter"`, `capture-pane [-S <n> -E <n>] [-e] [-J]` (`-e` raw escapes, `-J` joins soft-wraps; plain = grid-reconstructed), `pipe-pane --surface <uuid> "<cmd>"`, `kill-pane`, `swap-pane`, `resize-pane --dir L`, `zoom-pane`, `select-pane --pane <uuid> --dir L`, `break-pane`, `join-pane --src --dst --direction`, `respawn-pane -k`, `copy-mode` |
| **Window link / control** | `link-window --tab <uuid> --target-session <uuid>`, `unlink-window --tab <uuid>`, `control-mode` / `-CC` (tmux control protocol over stdio) |
| **Layouts** | `select-layout --tab <uuid> --layout tiled`, `next-layout --tab <uuid>`, `previous-layout --tab <uuid>`, `rotate-window --tab <uuid> [--reverse]` |
| **Attach** | `attach --surface <uuid> [--detach-keys "C-a d"]` (single pane); `attach-window [--tab <id> \| --session <id\|name> \| --window <id>] [--detach-keys …]` (full split layout — the compositor) |
| **Bindings** | `bind-key` (`bind`), `unbind-key` (`unbind`), `list-keys` (local `keybindings.json`) |
| **Buffers** | `set-buffer`, `list-buffers`, `show-buffer`, `delete-buffer`, `paste-buffer --surface <uuid>` |
| **Options** | `set-option` (`setw`) `-g status on`, `show-options -g` |
| **Environment** | `set-environment [-g] [-u] [-s <sessionID>] <key> [value]` (`setenv`), `show-environment [-g] [-s <sessionID>]` (`showenv`) — injected into pane shells on spawn/respawn |
| **Hooks / sync** | `bind-hook after-new-tab 'display-message "new tab"'`, `list-hooks`, `unbind-hook --id <uuid>`, `wait-for [-S|-L|-U] <channel>` |
| **Agents** | `notify --surface "$HARNESS_SURFACE" --body "…"` (`--message` alias), `detect-agent`, `install-hooks claude-code` |
| **Diagnostics** | `color-check` (ANSI/256/truecolor swatches), `theme-preview [--theme <name>] [--all]` (deterministic themed sample output); both are local stdout and do not open the daemon |
| **Display** | `display-message '#{cwd_basename}'` |
| **Install** | `install` (copy CLI to app support `bin/`, fish completion, LaunchAgent when bundled), `install-shell-integration [bash|zsh|fish|all]` |
| **Legacy** | `send --surface <uuid> --text "y\n"` |

**Key tokens** (`KeyTokenParser`): `C-c`, `C-a`, `Enter`, `Up`, `M-x`, etc. A modifier on a *named* key encodes the xterm CSI form — `S-Tab` → `ESC[Z`, `S-Up`/`C-Up`/`M-Up` → `ESC[1;<mod><final>`, `Delete`/`F5`+ → `ESC[<n>;<mod>~` (`mod = 1 + shift + alt·2 + ctrl·4`) — byte-identical to the GUI's `InputEncoder`; a modifier on a plain char keeps the legacy C0/`ESC`-prefix path.

**Note:** Marked `join-pane -h/-v` is a normal `Command` (prefix `j`). The explicit `harness-cli join-pane --src --dst --direction` form bypasses `CommandParser` and calls IPC directly.

**Remote socket path:** run `harness-cli doctor` on the remote box to print its control-socket path for `remote add --socket`. Full grammar: [docs/COMMANDS.md](docs/COMMANDS.md) (Remote section) and [docs/MULTIPLEXER_GUIDE.md](docs/MULTIPLEXER_GUIDE.md).

---

## Terminal compositor (`attach-window`)

The headline feature: `harness-cli attach-window` renders a tab's **full split layout** (every pane, borders, status line, active-pane cursor) into any plain terminal, including over ssh — like tmux, but Harness-native.

**Why a native engine.** Faithful compositing of N side-by-side panes needs each pane's **styled cell grid**, not just text. `HarnessGridTerminal` (in `HarnessTerminalEngine`) is a headless VT emulator exposing `readGrid()` for exactly that — pure Swift, no external dependency.

**Headless + synchronous.** `HarnessGridTerminal` wraps the engine's `TerminalEmulator` with a value-snapshot `readGrid()` — no Metal, no IO thread — so compositing N panes off-screen is fully synchronous and crash-free.

**Pipeline (client-side emulation; the daemon stays a dumb byte pipe):**

```
daemon PTY bytes ──subscribeSurfaceOutput──▶ HarnessGridTerminal (per pane)
                  replayScrollback (seed)        │ readGrid() → TerminalGridSnapshot
PaneNode tree ──PaneRectSolver──▶ [PaneRect] ────┤
                                                 ▼
                              GridCompositor ──ANSI frame (diffed)──▶ TTY
```

| Piece | File | Role |
|-------|------|------|
| `HarnessGridTerminal` | `HarnessTerminalEngine` | Headless per-pane VT emulator; `readGrid()` → snapshot |
| `TerminalGridSnapshot` | `HarnessTerminalEngine` | Value snapshot of a viewport (codepoints, SGR colors, attrs, wide, cursor) |
| `PaneRectSolver` | `HarnessCore/Session/PaneRectSolver.swift` | `PaneNode` + cols×rows → interior `[PaneRect]` with 1-cell dividers |
| `GridCompositor` | `HarnessTerminalKit/GridCompositor.swift` | Panes → ANSI frame: box-drawing borders, SGR re-emit, back-buffer diff, status, cursor |
| `WindowAttachClient` | `HarnessCLI/WindowAttachClient.swift` | Live wiring: subscribe/seed/composite, raw TTY (reuses `AttachClient`), SIGWINCH, **snapshot-push** structure tracking, prefix bytes → `KeyTable` → `CommandIPCTranslator`, follows the session's active tab |

**Geometry invariant:** `.horizontal` = side-by-side (first = left), `.vertical` = stacked (first = top), `ratio` = first child's fraction — matches the GUI's `split.isVertical = direction == .horizontal`. **Surface-key invariant:** `PaneLeaf.surfaceID.uuidString` is the daemon surface key (used directly for `subscribeSurfaceOutput`/`sendData`/`resizeSurface`). **Active pane is server-authoritative** (`Tab.activePaneID`/`lastActivePaneID`, schema v3): cycle/directional select commit via `selectPane`/`selectPaneDirectional` IPC and the GUI + compositor mirror it.

**Prefix routing:** the compositor decodes post-prefix bytes (printable / `C-x` / `M-x` / CSI+SS3 arrows with xterm mod codes, tolerant of split reads) into a `KeySpec`, looks it up in the merged prefix `KeyTable` (`KeybindingsStore.load` — user `keybindings.json` overrides apply), and runs the resulting `Command` through the shared **`CommandIPCTranslator`** (the same mapping the GUI `MainExecutor` and the daemon hook executor use). Status line is `FormatString` over `status`/`status-left`/`status-right` from `showOptions`.

**`CommandIPCTranslator`** (`HarnessCore/Commands`): pure `Command` + `CommandTarget` → `.requests([IPCRequest])` / `.clientLocal(Command)` / `.unresolved`. The **one** home of the split-direction inversion (`Command.SplitDirection` is divider-orientation — `.vertical` = side-by-side per `CommandParser`; the layout `SplitDirection` is the opposite, so `layoutDirection(for:)` inverts). Adopted by the GUI, the compositor, and `DaemonCommandExecutor` so a prefix verb, a `keybindings.json` override, and a hook-fired command behave identically.

**Multi-client sizing:** `DaemonServer` records each client's requested PTY size per surface and resizes to the **smallest** (tmux `window-size smallest`); a surface grows back when a small client detaches.

**Concurrency invariant (compositor):** the stdin reader thread does **only** `read()` — every byte is handed to `renderQueue`, the single owner of all input/mode/layout state (`inPrefix`, `prefixPending`, `pendingTable`, `copyMode`, `rects`, `activeSurface`, …). Never touch that state off `renderQueue`. Teardown drains the queue (`renderQueue.sync`) and sets `tornDown` before the final cleanup write, so no `composeAndWrite` races the reset sequence.

**Robustness invariants (daemon/IPC):** client sockets are **non-blocking**; `DaemonServer.send` buffers unsent bytes per-fd and flushes from a writable `DispatchSource` (a slow/stuck client can never block the serial queue or hang shutdown), dropping a client past `maxWriteBacklog`. The client's `DaemonSubscription` mirrors this: the read loop closes the fd **under `writeLock`** on teardown and `writeFrame` re-checks the cancelled/finished flags, so a fire-and-forget keystroke write can never land on a closed (and possibly recycled) descriptor mid-teardown. IPC frames are length-prefixed and bounded by `IPCCodec.maxPayloadLength` (16 MiB); an over-cap declared length **throws** so the reader drops the (unrecoverable) connection instead of mis-framing. A framed request the daemon can't decode (version skew) — **or one that de-frames cleanly but carries no request** (`{}` / `{"request":null}`) — replies `error("unrecognized request")` and keeps the connection (only a `tooLarge`/unrecoverable frame drops it), so a single bad request never silently hangs a client. `wait-for` releases a **held lock on holder disconnect** (hands it to the next queued locker via `WaitForRegistry.remove`) so a crashed holder can't wedge the channel forever. The PTY scrollback ring evicts by advancing a **head index** (O(1)) with batched compaction — never `removeFirst()` per chunk on the read hot path — and `respawn` reuses the surface's **original shell**, not the ambient `$SHELL`. The PTY master `write()` is **non-blocking** (an `EAGAIN`-loop on the surface's own serial `writeQueue`), so a backed-up shell never blocks `SurfaceRegistry.lock` or the IPC serial queue; the per-subscriber delivery queue is depth-bounded, and the `pipe-pane` tee + hook child `Process`es run on their own bounded queue and are reaped, so one stalled piped command can't wedge fan-out for every subscriber. `processMonitors` evicts orphan `monitors` keys (output that raced `closeSurfaces`) so the map can't grow unbounded. `WaitForRegistry` prunes channels left empty by a signal/unlock/disconnect (the map can't grow per unique channel name). `capture-pane` and reattach `replay` decode scrollback **lossily** (`String(decoding:as:UTF8.self)`) so a multibyte split at an eviction seam can't blank the history. Corrupt `layout.json`/`options.json`/`hooks.json`/`environment.json` (daemon) **and** `settings.json`/`keybindings.json` (app) are renamed `.corrupt` via the shared `HarnessPaths.backupCorruptFile` (which gates the "backed up" log on the *actual* move, so a failed backup is never reported as success; `atomicWrite` likewise logs save failures) and replaced with in-memory defaults — never silently overwritten — so a partial write never discards a user's config; `settings.json` is rewritten **only** when a migration actually mutates it (a no-op launch never rewrites it), and a changed source-terminal config never auto-overwrites visuals the user already customized (re-import is the consented path). `VTParser` caps OSC (1 MiB)/CSI-params (32)/intermediates (8) so hostile output can't grow them without bound and always recovers to ground (`ParserRobustnessTests`). The **control socket is `0o600` and `accept()` verifies the peer euid via `getpeereid`** (only the owning user can drive the daemon); the Harness home + subdirs are `0o700`. `pipe-pane`/hook failures never log the command (secret hygiene). Keep these contracts in code; there is no separate reliability doc in this checkout.

**Tests:** `GridCompositorTests` (borders/SGR/diff), `GridCompositorCopyModeTests`, `PaneRectSolverTests` (layout), `CommandIPCTranslatorTests` (verb mapping + split inversion), `HarnessGridTerminalTests` (engine fidelity), `CopyModeReducerTests`, and renderer/engine conformance suites. Run AppKit-linked grid tests via `xcrun xctest` only if `swift test`'s parallel runner is flaky.

**Parity:** the compositor now has copy-mode + SGR mouse, `-t session:window.pane` targeting, `wait-for`, the `bind -n` root table, and `switch-client -T` modal key tables — the broad tmux verb surface is captured in [docs/COMMANDS.md](docs/COMMANDS.md) and [docs/MULTIPLEXER_GUIDE.md](docs/MULTIPLEXER_GUIDE.md): control mode `-CC`, `link-window`, `display-popup`/`-menu`, `lock`/`clock-mode`, `command-prompt`, `choose-*`, `confirm-before`, `pipe-pane`, `capture-pane -S/-E/-e/-J`, command aliases. Deliberate architectural divergences are called out in [docs/MIGRATION.md](docs/MIGRATION.md); grouped sessions and session-lifecycle options should not be half-wired against Harness's value-typed session-owned tabs + always-visible-sessions model.

---

## Settings

`HarnessSettings` in `settings.json`. High-signal fields:

| Field | Purpose |
|-------|---------|
| `fontSize`, `fontFamily`, `defaultShell`, `defaultCWD` | Terminal defaults |
| `customBackgroundHex`, `customForegroundHex`, `customCursorHex` | Canvas colors; resolved via `ThemeManager.resolvedCanvas` (custom > theme preset > baseline) for terminal **and** chrome |
| `windowPaddingX/Y`, `backgroundOpacity` (0.05–1), `backgroundBlur` (0–100) | Chrome translucency; one uniform CGS `WindowBlur` for the whole window (terminal stays opaque) |
| `colorRendering`, `colorGamut`, `vividColors` | Accurate sRGB identity by default; vivid is opt-in Display-P3 output with first-party sRGB→P3 conversion plus a capped saturation lift (`vividColors` is the legacy alias) |
| `textRendering`, `linearBlending` | Glyph coverage gamma only (`native`/`crisp`/`soft`); never changes RGB conversion (`linearBlending` is the legacy crisp alias) |
| `ligatures`, `applyThemeToTerminalOutput` | Programming ligatures (CoreText shaping); theme palette recolors program output (off = untouched) |
| `offMainParserFramePipeline` | **Default ON**; moves terminal byte ingestion and frame building to a per-surface serial worker while AppKit and Metal presentation stay on the main actor. Race-guarded for production: `nextDrawable` keeps its timeout (a stalled GPU/occluded window can't block the main thread), the `lastPlainFrame` row-reuse cache is **generation-tagged** (a frame built against a superseded grid is dropped, never presented), frame builds coalesce **latest-wins** on the worker, a failed encode/present re-arms `needsRender`, and resize/first-paint render **synchronously** (`RenderScheduler.renderSynchronously`) so they land inside the `CATransaction` with no stretch flicker. An explicit stored `false` opts out (legacy byte-for-byte main-thread path) |
| `showPromptGutter` | Draws the OSC 133 prompt gutter stripe (green/red success/failure) when shell integration marks are present |
| `prefixKey` | Prefix binding (`ctrl-a`; empty disables); edited via `KeyRecorderView` in Settings |
| `experienceMode` | `ExperienceMode` (plain/persistent/tmux/agent). Gates chrome + default persistence on the one daemon core. Fresh installs → `.plain`; pre-modes files migrate → `.tmux`. See [docs/MODES.md](docs/MODES.md) |
| `tmuxControlsEnabled` | `Bool?` override for tmux chrome; nil derives from mode. `showsTmuxChrome` (mode default ⊕ override) is the single gate `PrefixKeymap`/`StatusLineView`/onboarding consult; `effectivePrefixKey` is nil when chrome is hidden or the key is blank |
| `scrollbackLines` | Scrollback size; **0 = unlimited** (the daemon ring stays small — the GUI emulator owns unbounded history, and the on-disk scrollback file uses `ScrollbackFile.unlimitedSafetyCap`) |
| `cursorStyle`, `cursorBlink`, `copyOnSelect` | Terminal behavior |
| `dividerHex`, `statusLineHex` | Chrome accents (nil → derive from theme) |
| `selection*Hex`, `boldColorHex`, `cursorTextHex`, `paletteHex[16]` | Terminal colors; seeded by theme preset, applied by the native renderer |
| `agentColorOverrides` | Per-agent brand color overrides |
| `systemNotificationsEnabled` | Delivery channel: show a macOS banner for an enabled notification event (in-window bell still updates). *Which* events notify is gated per-event by `notificationEvents` |
| `notificationSoundEnabled` | Chime with agent alerts; banner carries the sound, or an in-app `NSSound` chime when banners are off |
| `importedConfigSignature` | Fingerprint of last imported terminal config (migration) |
| `transparentTitlebar`, `sidebarVisible` | Chrome |
| `showStatusLine` | GUI hard override for the bottom status band (independent of the tmux `status` option); off collapses the band height to 0 |
| `resizeOverlay`, `resizeOverlayPosition` | Live resize HUD: when shown (`after-first`/`always`/`never`) + placement; rendered by `ResizeHUDView` |
| `windowPaddingBalance` | Center the grid by distributing the sub-cell remainder onto both sides (default on) |
| `minimumContrast` | WCAG fg/bg contrast floor (1 = off … 21); imported from `minimum-contrast`, enforced by `CellColorResolver` |
| `lightThemeName`, `darkThemeName` | Both set ⇒ the active theme follows the macOS appearance (KVO on `NSApp.effectiveAppearance` in `SessionCoordinator`); the window then follows the system appearance |
| `pasteProtection` | Confirm pastes containing newlines / control chars when bracketed paste is off (default on) |
| `commandFinishedThresholdSeconds` | Minimum runtime (OSC 133 timing) for the `commandFinished` notification to fire in an unfocused pane (default 10s) |
| `notificationEvents` | Sparse per-event banner gating keyed by `NotificationEvent` (`agentWaiting`, `agentFinished`, `bell`, `commandFinished`); an absent key uses the event's default. Picks *which* events notify; `systemNotificationsEnabled` / `notificationSoundEnabled` pick *how*. Read via `isEventEnabled(_:)`. The old `commandFinishedNotifications` bool migrates into `notificationEvents["commandFinished"]` |

**Terminal config import** (`TerminalConfigImporter`): reads a compatible source terminal config so users migrating in keep their colors/font. The font **face** is imported but the font **size** is not — `fontSize` is Harness-owned (default 16); `makeDefaults`/`applyImportedDefaults`/`resetToImportedConfig` deliberately don't pull `font-size` from the source terminal (a terminal's size preference doesn't carry over). **Do not strip `#` in values** — only lines starting with `#` are comments. Re-import via Settings or `source-config` / prefix `r`. `minimumContrast` is imported into `settings.json` and enforced by the renderer (`CellColorResolver`).

**Apply colors (single source of truth):** `ThemeManager.resolvedCanvas(themeName:custom*Hex:)` resolves the canvas bg/fg/cursor (explicit custom > theme preset > baseline). **Both** `TerminalHostView.applyNativeAppearance` (→ `HarnessTerminalSurfaceView.configureAppearance`) and `HarnessChrome.update` consume it, so terminal canvas and chrome paint the **identical** color — no seam. `CellColorResolver` stays byte-exact and gamut-free; `FrameBuilder` is the RGBColor→RenderColor boundary, and the Metal clear color must use the same converter as default cell backgrounds. Chrome is **fully flat**: `HarnessChromePalette` paints the resting sidebar/tab/status background as the *exact* terminal color (no lift), so the window reads as one seamless surface — only interaction states (active/hover) blend toward the foreground. Program **output** keeps untouched/default ANSI colors unless `applyThemeToTerminalOutput` is on; the daemon PTY exports `COLORTERM=truecolor` (with `TERM=xterm-256color`, see `RealPty`) so TUIs like Claude Code emit true 24-bit color instead of a washed 256-color fallback, and the off-mode baseline ANSI palette (`ThemeManager.defaultBaselinePaletteHex`) is the bundled muted ANSI-16 set. Selecting a theme seeds the full editable color set into `settings.json` (`SessionCoordinator.setTheme` + `ThemeManager.presetColors`); colors flow from settings. **Translucency + blur:** the native canvas honors `backgroundOpacity` (default-bg cells get the alpha so the one window-wide CGS `WindowBlur` shows through), while glyphs and explicit program backgrounds stay opaque so output reads true. Chrome backdrop: `ChromeBackdrop` with `.underWindowBackground` or Liquid Glass — **not** `.sidebar` / `.titlebar` (blue tint).

---

## Agent integration

Shell env: `/usr/bin/env HARNESS_SURFACE=<uuid> $SHELL -l`

**Detection:** `AgentDetector` + daemon `AgentScanner` (~1.5s) on process tree from shell PID. Kinds: codex, claude-code, cursor, pi, hermes, openclaw, opencode, aider, gemini, goose, generic. **`install-hooks`** writes configs for six agents (codex, claude-code, cursor, pi, hermes, openclaw); it **deep-merges** into the agent's existing config (e.g. `~/.claude/settings.json`) — never overwrites — and is idempotent (`JSONMerge.deepMerge` in HarnessCore, covered by `HarnessCoreTests`). Codex's hooks use the event/matcher shape (NOT the inert `on_pause`/`on_done` keys) **and** `install` enables `[features] hooks = true` in `~/.codex/config.toml` (Codex won't load `hooks.json` otherwise — mirrors the Skillz integration). Agents with no shell-command hook mechanism (opencode, aider, gemini, goose) are **not** installable — they notify via the hook-independent activity path once detected. The install logic lives in **`HarnessCore.AgentHookInstaller`** (`install`/`isInstalled`/`installableAgents`, `homeOverride` for tests), shared by the CLI shim (`AgentHookInstallerCLI`) **and** the GUI's per-agent "Install hooks" button (Settings ▸ Agents) — no shelling out, no duplication.

**OSC 9;4 progress pipeline:** `TerminalProgressReport` (engine, `HarnessTerminalEngine`) parses `ESC ] 9 ; 4 ; <state> ; <value> ST` (ConEmu/Ghostty/Windows Terminal semantics) and invokes `onProgress` on the surface view. `SurfaceProgressTracker` (`@MainActor`, app-local, never persisted) aggregates reports per surface and expires them after a hardcoded **15 s stale timeout** (re-armed by each keep-alive) — matching Ghostty's cleanup window for programs that die without sending the remove. `TabPillView` reads `SurfaceProgressTracker.shared.isActive(_:)` and paints the **working dot** (Ghostty-style tiny indicator before the tab title) while the report is live. **Fallback for agents that don't emit OSC 9;4** (e.g. Codex): the tab dot also lights when `tab.agent?.activity == .working` and the tab is not already `.waiting` — the activity comes from `AgentDetector` / `AgentScanner` output recency via the daemon. An explicit OSC 9;4 report always outranks the fallback.

**Title fallback:** `AgentTitleInference.kind(from: tab.title)` when proc-tree misses agent (sidebar/tab use `tab.agent?.kind ?? inference`).

**Hooks for agents:**

```bash
harness-cli install-hooks claude-code
harness-cli notify --surface "$HARNESS_SURFACE" --body "Approval required"
```

Per-agent guides: [docs/agent-hooks/](docs/agent-hooks/). Daemon hooks (`hooks.json`): `after-new-tab`, `after-new-session`, `after-kill-tab`, `after-split-pane`, `after-kill-pane`, `after-resize-pane`, `pane-exited`, `client-attached`, `client-detached`, `agent-state-changed`, `notification-posted` (full list in [docs/COMMANDS.md](docs/COMMANDS.md)).

**UI:** `SessionCardRowView`, `TabPillView`, **`AgentChipView`** in sidebar/session rows when agent kind is detected or inferred (static chip, not activity-gated), `NotificationBellButton` / `NotificationDropdownPanelView`, `Cmd+Shift+U` jump to notification (skips still-`working` agents). OS banners gated per-event by `notificationEvents` then by `systemNotificationsEnabled`, and presented even in-foreground via `DesktopNotifier`'s `ForegroundPresenter` (`UNUserNotificationCenterDelegate`).

**Agent Notch HUD:** `NotchPanelController` + `AgentNotchRootView` (`UI/Notch/`) show at-a-glance agent rows on Macs with a notch; data from `AgentNotchProjection` in `HarnessCore/Notch/`. Click a row → `SessionCoordinator` focuses that session/tab.

**Quick terminal (v1.9):** `QuickTerminalController` — a Quake-style dropdown panel on a global hotkey (`quickTerminalEnabled`/`quickTerminalHotkey` settings); slides over the frontmost app, hosts a normal daemon-owned session, hides on focus loss. **Bell feedback (v1.9):** `terminalHostDidRingBell` → `BellFeedback` (audible/visual per `bellMode`), tab badge for background bells, bridged to tmux `visual-bell`/`bell-action` options.

**Notification delivery (one path):** `SessionCoordinator.deliverAgentAlert(event:title:body:)` is the single sink. It first gates on the per-event "which events notify me" choice (`settings.isEventEnabled(event)`, backed by `notificationEvents`), then honors the two delivery toggles — banner (`systemNotificationsEnabled`) and chime (`notificationSoundEnabled`). The `NotificationEvent` cases and their sites: `.agentWaiting` — the explicit `harness-cli notify` path (`pushNewRemoteNotifications`, rich message, owns `.waiting` tabs) plus `terminalHostDidRequestDesktopNotification`; `.agentFinished` — the **hook-independent** `pushAgentActivityNotifications` path firing on the agent-activity `working → idle/awaiting` edge (the AI stopped producing output), so a ping lands for **any detected agent under any shell** with no hook install; `.bell` — `terminalHostDidRingBell`; `.commandFinished` — `terminalHostDidFinishCommand`. The activity path skips `.waiting` tabs (so the two never double-fire), skips the pane you're actively watching, and has a 30s per-surface cooldown so a streaming agent can't spam. Only the OS banner is gated by these settings — the in-app sidebar ring/waiting state (`requestDaemon(.notify)`) is independent.

**Chrome icon buttons (one source of truth):** every circular chrome button — `NotificationBellButton`, the sidebar toggle, footer gear/＋/palette, tab-strip ＋/overflow (all `SoftIconButton`) — paints through **`HarnessDesign.applyIconButtonChrome(to:bounds:isHovered:)`**: a subtle `surfaceElevated` disc + `borderStrong` rim (the same as the adjacent search field), flat (no drop shadow), hover lifts toward foreground. They follow the theme like the session cards instead of floating as opaque near-black discs. The **active top-tab pill** (`TabPillView.applyChrome`) is painted identically to the **selected session card** (`SessionCardRowView`): accent-tinted fill + accent rim + `elevation1` + card radius, so the tab strip and the side tab read as one system.

**Brand icons:** `AgentChipView`, `TabPillView`, the `MenuBarController` menu, and Settings ▸ Agents render each agent's mark from **`AgentIconArt`** via **`SVGPathParser`** → `CGPath` and **`AgentIconRenderer`** (`templateImage` tintable by `contentTintColor`; `coloredImage` baked for `NSMenuItem`; `monogramTemplate` for the text-only fallback). Sources (attribution in [docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md)): **lobe-icons** `@lobehub/icons-static-svg` (MIT) for `codex`, `claude`, `cursor`, `openclaw`, `opencode`, `gemini`, `goose`; a **vendor brand mark** (matching the Skillz app) for `pi` (Inflection). No bundled raster assets — vector, crisp at any size, the same procedural approach as the box-drawing. Agents with no mark (Hermes, Aider) fall back to a tinted two-letter monogram (`AgentIconRenderer.monogramTemplate`); the per-agent color override tints it. **Hermes** uses the monogram deliberately: its official mark is a detailed portrait that is illegible at the 14–18px sizes the icon is shown at.

---

## UI and key classes

```
┌──────────────────────────────────────────────────────────┐
│ Search 🔔 ▢   │ Tab bar (pills +)                      │
│ Session cards  ├────────────────────────────────────────┤
│                │ Terminal panes (native renderer)       │
│ Footer         │ Status line (FormatString)             │
└────────────────┴────────────────────────────────────────┘
```

> Sidebar header is **search field + notification bell + sidebar toggle** (single active
> workspace — the workspace pill / switcher and footer "new workspace" button are dormant,
> not wired into the UI; `WorkspacePillButton` / `WorkspaceSwitcherPanelView` stay in
> `HarnessSidebarPanelViewController` for easy re-enable).

| Component | File | Notes |
|-----------|------|-------|
| Window shell | `MainWindowController` | Root window, chrome palette |
| Main menu | `MainMenuBuilder` | Global shortcuts (Cmd+T, Cmd+K, …) |
| Main split | `MainSplitViewController` | Snapshot observer; sidebar collapse via `SplitChromeDelegate.allowFullCollapse` (divider min drops to 0 for a programmatic collapse, stays 200 for user drags) + a tab-strip toggle button; traffic-light leading inset applies to `WindowTitleStripView` (via `ContentAreaViewController.setTabBarLeadingInset`) when the sidebar collapses — the tab bar itself receives inset 0 (it sits below the title strip, already clear of the lights) |
| Sidebar | `HarnessSidebarPanelViewController` | Sessions, agents |
| Tab bar | `TerminalTabBarView` | `SoftIconButton`: `isBordered = false` for `+` |
| Terminals | `ContentAreaViewController` | Pane mount on structure change |
| Copy mode | `HarnessCopyMode`, `TerminalHostView` / `HarnessTerminalSurfaceView` | Shared reducer over engine grids; vim/emacs tables; yank to pasteboard + buffer |
| Status line | `StatusLineView` | `OptionStore` + `FormatString` |
| Notifications | `NotificationBellButton`, `NotificationDropdownPanelView` | Waiting-tab badge + dropdown |
| Agent Notch HUD | `NotchPanelController`, `AgentNotchViewModel`, `AgentNotchRootView` | macOS notch overlay; `AgentNotchProjection` in HarnessCore |
| Title strip | `WindowTitleStripView` | Draggable strip above the tab bar (30 pt); shows active tab's `folder · basename` (Ghostty-style); hidden while an agent owns the pane; traffic-light leading inset slides in via `setLeadingInset` when sidebar collapses; hosted by `ContentAreaViewController` |
| Window edge border | `WindowBorderOverlayView` | Click-through hairline overlay on the window's inner edge; color/opacity from `windowBorderHex` / `windowBorderOpacity` settings; auto-hidden in fullscreen |
| Scrollbar | `TerminalScrollbarView` | Transient auto-hide overlay scrollbar in `TerminalHostView`; purely decorative (click-through, no track chrome); shares debounced-fade timing with `ResizeHUDView` |
| Resize HUD | `ResizeHUDView` | Live grid-size overlay shown during resize; gated by `resize-overlay` setting (suppressed on first open); hosted by `TerminalHostView` via `onGridSizeWillChange` callback |
| Default terminal | `DefaultTerminalManager`, `DefaultTerminalOpener` | Settings ▸ Terminal — `ssh`/`telnet`/`x-man-page` + `.command`/`.tool`; `AppDelegate` opens URLs via `SessionCoordinator.openDefaultTerminalLaunch`. **Gotcha:** `NSWorkspace.setDefaultApplication` completions must be `@Sendable` (invoked off main actor; Swift 6 traps MainActor-isolated closures). |
| Display panes | `DisplayPanesOverlay` | Prefix `q` / `display-panes` — tmux-style numbered overlay |
| About | `AboutPanelController` | Menu → About Harness |
| Onboarding | `OnboardingController` → `HarnessOnboarding` | Thin app bridge to the embedded SwiftUI immersive first-run wizard; first launch + Help → Welcome; dismisses back into Harness, never exits the app |
| Prefix / prompt | `PrefixKeymap`, `CommandPromptController` | |
| Palette | `CommandPaletteController` | `Cmd+K`, MRU; featured themes only |
| Menu bar | `MenuBarController` | `NSStatusItem` (Harness mark, template); menu lists active agent sessions + every workspace's sessions from the daemon snapshot (shell-agnostic); rebuilt on open |
| Design / chrome | `HarnessDesign`, `HarnessChrome` | Tokens, `ChromeBackdrop`, `HarnessPillButton` (theme-aware monochrome primary/secondary — used by onboarding + settings instead of system-blue bezels), Liquid Glass |
| Toast / blur | `Toast`, `WindowBlur` | Transient feedback, backdrop blur |
| App launch | `AppDelegate` | Daemon, prefix keymap, shell tracker |
| Coordinator | `SessionCoordinator` | IPC, registry, themes |
| Executor | `MainExecutor` | `Command` → coordinator |
| Keybindings | `KeybindingsService` | Load/merge `keybindings.json` |
| Pane registry | `TerminalPaneRegistry` | Reuse `TerminalHostView` by `SurfaceID` |
| Pane lookup | `TerminalPaneRegistryAccess` | `@MainActor` lookup by `SurfaceID` |
| Shell tracker | `SurfaceShellTracker` | cwd polling via proc tree |
| Daemon fallback | `DaemonLauncher` | Starts daemon when launchd unavailable |
| Terminal | `TerminalHostView` | Hosts `HarnessTerminalSurfaceView`; daemon I/O |
| Settings UI | `SettingsViewController`, `KeyRecorderView`, `LiveTerminalPreview`, `HarnessControls` | Standalone native macOS Settings window via `SettingsWindowController` (not embedded); rebuilt per open; standard titled window, sidebar vibrancy, native search, and pages **Appearance · Colors · Terminal · Keys · Agents · Advanced** as grouped preference sections. Form controls in `HarnessControls.swift` use system semantic colors and the user accent so the window tracks macOS light/dark appearance while keeping Harness-specific controls for sliders, swatches, segmented choices, and searchable selects. `LiveTerminalPreview` remains a theme-true mini pane. **Agents** page = per-agent rows (icon + matched executables + color swatch + one-click Install hooks). **Advanced** = curated daemon-owned `OptionStore` options (status format, mouse, base-index, monitor, repeat-time, pane borders…) read/written via `showOptions`/`setOption` IPC. |
| Daemon | `SurfaceRegistry`, `RealPty`, `DaemonServer` | Session authority |
| Core | `SessionEditor`, `CommandParser`, `OptionStore`, `HookRegistry`, `PasteBufferStore`, `FormatString` | |

---

## Build and test

```bash
make build | preview | preview-stop | preview-clean | release | release-notes | package | dmg | smoke-dmg | sign | appcast | finalize | hotfix-release | icon | clean
xcodegen generate
swift test                                    # fast, deterministic
HARNESS_LIVE_DAEMON_TESTS=1 swift test        # + real shell / socket tests
```

`make package` is an alias for `make release`. Optional marketing video targets (`video-dev`, `video-render`, …) live in the Makefile and run under `marketing/video` — see [marketing/README.md](marketing/README.md).

**CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)): **Build & test (macOS)** on `macos-15` (Xcode 16) — full `swift test` + non-blocking benchmarks; **Build & test (Linux, headless daemon)** — daemon/CLI/core/engine only (no GUI/renderer/compositor).

**Release prep:** after updating CHANGELOG.md, run `make release-notes` — it regenerates `GeneratedReleaseNotes.swift` (the post-update "what's new" terminal banner) from the top changelog block. `ReleaseNotesGuardTests` and a `package-app.sh` guard fail on stale notes.

**Release order (do not reorder):** `make release` → `make sign` → `make dmg` → `Scripts/finalize-release.sh`. `dmg`/`sign` operate on the **existing** `Harness.app` and must NOT re-run `release` (a rebuild would clobber the signature with an unsigned bundle). `package-app.sh` resolves + verifies `Sparkle.framework` and **fails** the build if it's missing (the app links Sparkle and would crash when the menu touches the updater). `sign-and-notarize.sh` fails loud when notarization creds are absent (unless `--sign-only`) and `codesign --verify --deep --strict` after signing/stapling; `finalize-release.sh` single-sources the version/TAG from the built `Info.plist`, reads the signing identity back from the signed app, auto-detects the repo via `gh`, and never masks the `spctl` Gatekeeper check.

Bundle in `Harness.app/Contents/MacOS/`: `Harness`, `HarnessDaemon`, `harness-cli`; icon at `Contents/Resources/Harness.icns`.

**Building in Xcode:** `xcodegen generate` (only after adding/removing files or editing `project.yml`), then `open Harness.xcodeproj`; pick the **`Harness`** scheme + **My Mac** and ⌘B / ⌘R. The app target depends on `HarnessDaemon` + `harness-cli` and a `postBuildScript` copies both into the bundle, so one build refreshes all three. The generated scheme runs ten test targets (Core, Daemon, TerminalKit, CopyMode, TerminalEngine, Theme, TerminalRenderer, Onboarding, GridCompositorParity, plus the env-gated Benchmarks); only `HarnessCLITests` and `HarnessAppTests` stay SPM-only (they depend on executable targets, which Xcode test bundles can't link) — run those via `swift test`.

**Daemon restart (critical, learned the hard way):** `HarnessDaemon` is a separate launchd process (`KeepAlive`) — rebuilding/relaunching the app does **not** restart it. Daemon-code changes (PTY env like `COLORTERM`, IPC, session authority) only take effect after you restart it **and** open a fresh pane (PTY env is applied at shell spawn):

```bash
launchctl kickstart -k gui/$(id -u)/com.robert.harness.daemon
```

App/renderer changes (colors, chrome, opacity, Settings) need only ⌘R. The launchd plist points at the build it was installed from (often DerivedData Debug); `make release` users run `harness-cli install` once to repoint it at the release bundle, else the old binary keeps running.

**HarnessCoreTests:** `SessionEditor`, `SessionEditorPhase4`, `IPCCodec`, `KeyTokenParser`, `KeyTable`, `FormatString`, `CommandParser`, `CommandIPCTranslator`, `PasteBufferStore`, `LaunchAgentInstaller`, `HarnessSettings`, `AgentDetector`, `AgentNotchProjectionTests`, `DaemonClient`, `HarnessPaths`, `TerminalConfigImporter`, `PaneRectSolver`, `JSONMerge`, `AgentHookInstaller`, `ShellIntegration`, `EnvironmentStore`, targeting, options, alerts, and tmux migration.

**HarnessDaemonTests:** `SurfaceRegistry`, `ShellLaunchProfile`, `ScrollbackFileTests`, `DaemonRoundTrip`, `RealPtyLifecycle` (`DaemonRoundTrip` and `RealPtyLifecycle` opt-in via `HARNESS_LIVE_DAEMON_TESTS=1`).

**HarnessOnboardingTests:** onboarding wizard coverage.

**HarnessCopyModeTests:** `CopyModeReducerTests` for shared GUI/compositor copy-mode motions, selection, search, prompt jumps, and side effects.

**HarnessThemeTests:** theme document import/export plus catalog/resource coverage.

**HarnessCLITests:** `flagValue` argument-parsing coverage (the shared flag extractor behind the `harness-cli` subcommands, incl. the flag-present-but-no-value case) — a `@testable import` of the `@main` `HarnessCLI` executable target, no library split.

**HarnessTerminalKitTests:** `GridCompositorTests`, `GridCompositorCopyModeTests`, `HarnessTerminalSurfaceWorkerTests` (experimental off-main parser/frame pipeline).

**HarnessTerminalRendererTests:** `FrameBuilderTests` (incl. color conversion, selection and prompt gutter), `FrameBuilderCopyModeTests`, `GlyphRasterizerTests` (incl. shaped-run cache), `CellColorResolverTests`, `MetalRendererTests` (offscreen structural render guardrails; `HARNESS_WRITE_RENDER_SNAPSHOTS=1` writes optional PNGs to `/tmp/HarnessRenderSnapshots` for human debugging only).

**HarnessTerminalEngineTests:** `HarnessGridTerminalTests`, `InputEncoderTests` (incl. mouse), `ScrollbackTests`, `EngineConformanceTests`, `VTConformanceCorpusTests`, `ParserRobustnessTests` (hostile/oversized OSC/CSI/DCS stay bounded + recover), `AsciiFastPathTests` + `CodepointRunFastPathTests` (the SIMD ASCII run path and the bulk-UTF-8 codepoint path are byte-for-byte equal to `feedScalarwise` across well-formed + malformed input at 8 chunk-splits), `TerminalProtocolCompatibilityTests` (OSC 9/777/22, tab stops, charsets), `KittyKeyboardTests` (CSI u + modifyOtherKeys; legacy byte-identical when off), `ImageProtocolTests` (Sixel/Kitty/iTerm2 decode + placement, headless), `ClipboardOSCTests`, `SemanticPromptTests`. Renderer `MetalRendererTests` adds offscreen render-readback coverage.

**HarnessBenchmarks** (opt-in perf baselines for VT parse / readGrid / scrollback / IPC codec / compositor / frame building / renderer stats / atlas caches / off-main stall sampling): `make bench` or `HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks` (skipped otherwise so `swift test` stays fast). Benchmarks print JSON timing lines; do not gate CI on absolute timings. The engine gate is `testConsumerScoreboard` (`consumer_<workload>` with the `feedNanos`/`frameBuildNanos` split — parse dominates, frame build is ~0.1 ms); `testIPCInclusiveScoreboard` runs the same payloads through the real `IPCCodec` output frame to confirm the daemon framing/chunking tax is negligible. The cross-terminal `Scripts/benchmarks/terminal_stress_runner.py` drain is **not** an engine measure (PTY-drain, ±25–33% on window focus, can move opposite to engine speed) — gate on the in-process scoreboard, not the drain ratios.

**Frame signpost instrumentation (`HARNESS_FRAME_SIGNPOSTS=1`):** `FrameSignposter` (`HarnessTerminalKit`) is gated off by default (each call is a single branch when disabled, so it is safe on the hot path). Enable with `PREVIEW_SIGNPOSTS=1 make preview` — `open` strips the shell environment, so the preview script passes the flag as a launch argument (`open -n … --args -HARNESS_FRAME_SIGNPOSTS 1`, read via `UserDefaults`); setting `HARNESS_FRAME_SIGNPOSTS=1` in the launch environment also works for direct binary launches (`xctrace … --launch`). This enables `os_signpost` intervals around the per-frame `parse → gridRead → frameBuild → present` pipeline on the `com.robert.harness / frame` track, and `TerminalRenderStats` splits `encodeNanos` into `buildInstancesNanos` (CPU instance build) + `uploadNanos` (GPU buffer upload) so a slow encode is attributable per value boundary (grid read / frame build / instance build / upload). The periodic log line blends samples from ALL presenting surfaces — single visible surface for attribution. The `present` interval is the most informative: it wraps `nextDrawable()` + `inFlightSemaphore.wait()` on the main thread and captures the vsync / GPU back-pressure stall. Every 120 frames it also logs p50/p95/max present latency (µs) to the unified log, readable with `log stream --predicate 'subsystem == "com.robert.harness"'` without Instruments. Profile with `xctrace record --template 'os_signpost'` on a `make preview` run.

New mode/persistence/security tests also live in **HarnessCoreTests** (`ExperienceModeTests`, `SessionPersistenceTests`, `HookRegistryTests`, perms in `HarnessPathsTests`) and **HarnessDaemonTests** (`closeEphemeralSessions` + socket-perms in `DaemonRoundTripTests`).

**Smoke:**

```bash
harness-cli ping && harness-cli new-tab --workspace Default --cwd "$HOME"
# cd in GUI → sidebar/tab show folder name ~1s
harness-cli notify --surface "$(harness-cli list-surfaces | head -1)" --body test
```

---

## Keyboard shortcuts

Global menu shortcuts are defined in `MainMenuBuilder`, not `KeyTableSet.root` (which only holds prefix/copy-mode tables).

| Action | Shortcut |
|--------|----------|
| New workspace / tab | `Cmd+Shift+N` / `Cmd+T` |
| Close tab / workspace | `Cmd+W` / `Cmd+Shift+W` |
| Split H / V | `Cmd+D` / `Cmd+Shift+D` |
| Jump to notification | `Cmd+Shift+U` |
| Command palette | `Cmd+K` |
| Command prompt | `Cmd+;` |
| Settings | `Cmd+,` |
| Toggle sidebar | `Cmd+\` |
| Switch to tab 1–9 | `Cmd+1` … `Cmd+9` (shown as ⌘N on the pills) |
| Tab prev/next | `Cmd+Shift+[` / `]` |
| Font +/- / reset | `Cmd++` / `Cmd+-` / `Cmd+0` |

**Prefix (default `Ctrl-A`):** [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `connection failed` | Daemon down | Open app or check launchd |
| Not true black | Hex stripped or missing | Fix importer; re-import terminal config |
| Blue sidebar | Wrong material | `.underWindowBackground` / glass |
| Tab shows `Shell` | cwd not updating | `SurfaceShellTracker`, `displayTitle` |
| cwd in daemon, stale UI | Snapshot push not arriving (subscription dead) | `SessionCoordinator` snapshot subscription + 30 s safety poll; check daemon `subscribeSnapshot` |
| Stale/missing git branch label | `HEAD` watcher not armed for the repo | `GitBranchMonitor` (one `FileWatcher` per resolved `HEAD`); `GitHEADReader` for parsing |
| `+` dead | Button bezel | `isBordered = false` |
| All tabs waiting | `markWaiting` bug | Filter by surface key |
| Terminal colors wrong | Stale hex or import path | Re-import terminal config; check `ThemeManager.resolvedCanvas` + `applyNativeAppearance` |
| Seam: sidebar ≠ terminal | A caller bypassed `resolvedCanvas` | Route bg/fg/cursor through `ThemeManager.resolvedCanvas` |
| Blur does nothing | Window opaque | Blur is a window-wide CGS `WindowBlur`; set `backgroundOpacity` < 1 so the canvas + chrome show it |
| Blur squares the corners / dark hairline seam around the window | the root `contentView` was forced layer-backed (`wantsLayer`) — via `makeClear` in `MainSplitViewController.loadView` **or** `applyChrome` — making the window layer-backed → CGS blur clipped to the contentView rectangle, not the rounded frame (dark seam at the rounded edge, hard at the corners as blur thins) | No site may layer-back the root contentView: `loadView` keeps it a plain `NSView`, `applyChrome` must not `makeClear` it, `applyTransparency` must not touch its layer (and never corner-clip it). Leave it non-layer-backed so the system rounds the frame + blur |
| Hard dark corner edge on a translucent window when blur is low/off | macOS derives the window drop-shadow from the content's *rectangular* alpha → a dark band hugging the rounded frame, hidden by a strong blur but sharpening as blur drops (the "edge that won't go away") | `applyTransparency` sets `window.hasShadow = isOpaque` + `invalidateShadow()`: translucent windows shed the shadow (the blur gives separation), opaque windows keep it |
| Dragging a tab moves the whole window | the tab strip sits in the `.fullSizeContentView` titlebar drag region and AppKit treats a pill drag as a window move | `TabPillView.mouseDownCanMoveWindow = false` — pills reorder via their own `mouseDragged` → `onDragChanged`; the empty tab-bar background keeps the default `true` so it still drags the window |
| Sidebar won't fully collapse | Divider min clamped at 200 | Set `SplitChromeDelegate.allowFullCollapse` during the programmatic collapse so the divider can reach 0 |
| No agent chip | Proc-tree miss | `AgentTitleInference` |
| First-run tour / what's-new banner missing or repeating | `version-state.json` out of sync, or banner suppressed | One-shot per build: daemon records the build in `version-state.json` when the first *user-created* surface consumes it (`SurfaceRegistry.injectVersionBannerIfPending`; rendered by `TerminalBanner`, notes from `GeneratedReleaseNotes.swift`). Delete the file to re-show; `update-banner off` option suppresses. Only `HarnessDaemonMain` enables it (`DaemonServer(enableVersionBanner: true)`) — embedded/test registries never banner |
| Xcode build fails | Stale project | `xcodegen generate` |

---

