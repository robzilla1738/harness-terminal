# Changelog

All notable changes to Harness are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Harness follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each released version
has a matching `vX.Y.Z` tag and a signed, notarized DMG on
[GitHub Releases](https://github.com/robzilla1738/harness-terminal/releases).

## [Unreleased]

### Added
- **Real-time live resize (Ghostty parity).** Dragging the window edge now reflows the grid and
  signals the running program (`SIGWINCH`) at every cell boundary, so interactive programs
  (vim/htop/btop/tmux/less) and alternate-screen TUIs redraw *during* the drag instead of snapping
  at release. The authoritative reflow runs off-main with latest-wins coalescing (a fast drag runs
  ~1–3 reflows, not one per column), presents inside an explicit `CATransaction` so it flushes even
  when the pointer is held still, and the PTY vote coalesces per-fd and to distinct cell counts so
  the daemon isn't stormed. Default on, with a **Real-time resize** setting (`liveResizeReflow`)
  that reverts to the previous defer-to-release behavior. The non-mutating re-wrap preview is
  retained as instant feedback under the live reflow.
- **Tab persistence indicator.** A tab pinned to stay running after a clean quit
  ("Keep Tab Running After Quit") now shows a small accent pin at the leading edge of
  its tab pill — a tmux-style window flag — so kept-alive tabs are identifiable at a
  glance instead of only through the right-click checkmark. The pin also appears beside
  the tab in the overflow menu.
- **Granular notification settings.** Settings → Agents now splits notifications into
  *Notify me about* (per-event toggles for **Agent needs input**, **Agent finished**,
  **Terminal bell**, and **Command finished**) and *Delivery* (macOS banner + sound),
  so you can pick exactly which events ping you instead of one all-or-nothing switch.
  Defaults preserve prior behavior, and an existing "command finished" choice migrates
  automatically. Backed by a new `NotificationEvent` type and a sparse
  `notificationEvents` map in settings; only desktop banners are gated — the in-app
  bell/waiting indicators are unaffected.

## [1.4.1] - 2026-06-04

The resize-parity release: the live render path stops crossing full-frame value boundaries.
A width-drag boundary tick now costs the main thread no more than a sub-cell tick, and
steady-state frames cost O(damage), not O(grid) — the Ghostty `Contents` model.

### Performance
- **Async re-wrap preview.** (#72) Crossing a cell boundary mid-drag no longer blocks the main
  thread on the emulator queue for the reflow + full frame build (~3ms per crossing, scaling
  with grid height): the preview builds asynchronously with latest-wins coalescing and lands on
  the next hop, while the drag keeps re-presenting the cached frame at full frame rate. Under
  heavy output the re-wrap now works instead of being skipped. Hardening: previews coalesce in
  their own token namespace (output bursts during animated resizes — sidebar slides — can no
  longer cancel them), the debounced grid commit defers while the drag holds (a stationary
  >60ms hold used to freeze the screen until the next pointer move), and stale previews are
  dropped at drag end and across pane re-mounts.
- **Content-keyed row salvage.** (#76) A column-count change used to discard the renderer's
  whole row cache; rows whose rendered content is unchanged (hashed over every render-affecting
  field) now re-bind their cached instances across the width change — per crossing, the CPU
  instance encode drops 1510→338µs and the GPU upload 71KB→13KB; a non-rewrapping width change
  re-encodes zero rows.
- **Persistent instance arrays.** (#74) Every frame used to re-flatten all rows' instances into
  freshly allocated arrays (megabytes of copies per frame on large grids, even for a one-row
  keystroke). The renderer now owns persistent flat arrays with a per-row segment table and
  splices only dirty rows in place — clean rows' bytes are never touched, and steady state
  allocates nothing. Scattered damage (a status row plus the cursor row) uploads two row-sized
  spans instead of everything between them.
- **Images no longer disable render caching.** (#75) Any inline image (Sixel / Kitty / iTerm2)
  forced every frame of that pane to re-encode every row; images draw as a separate quad pass,
  so image-bearing panes now keep incremental row reuse — typing next to an image re-encodes
  one row instead of the whole grid.

### Added
- **Per-boundary render instrumentation.** (#72) `TerminalRenderStats` splits encode time into
  CPU instance build vs GPU upload; `HARNESS_FRAME_SIGNPOSTS=1` brackets the grid read and
  frame build on the signpost track; a boundary-crossing benchmark steps a full cell column per
  tick and attributes each crossing's cost per pipeline stage.

## [1.4.0] - 2026-06-04

The control release: experience presets unbundle into per-piece overrides, persistence gets
per-tab pins, and the renderer stops re-uploading the whole screen on every keystroke.

### Added
- **Per-tab persistence pins.** (#71) Right-click a tab → "Keep Tab Running After Quit" — the
  finest-grained keep-on-quit control. A tab survives a clean quit iff the global switch, its
  session's pin, or its own pin is set; unpinned siblings close individually while the pinned
  tab keeps its session alive as a container. The session pin is now always shown in the
  sidebar (with a note when the global switch supersedes it).
- **Decoupled experience-preset controls.** (#71) The presets (Plain / Persistent / Full /
  Agent) now just seed defaults: separate **Command prefix** and **Status line** tri-states
  (Auto / On / Off) replace the single "Harness controls" umbrella, so e.g. a Plain terminal
  can show a status line without arming the prefix. Existing settings keep their exact
  behavior, and switching presets re-syncs the keep-on-quit default without clobbering an
  explicit choice made in Settings.

### Performance
- **Row-incremental GPU instance upload.** (#70) Outside the stable-frame fast path, every
  frame re-uploaded the whole screen's instance arrays to the GPU — one keystroke forced a
  full-screen memcpy. Frames now upload only the changed rows' bytes (per-stream dirty spans,
  reconciled across both in-flight ring slots); scroll and full repaints are unchanged — the
  worst case is identical to the old whole-array upload.

### Fixed
- **Thai and other combining marks render correctly.** (#59, fixes #56) Zero-width marks now
  stack onto their base cell instead of occupying their own.
- **Multi-client sizing actually holds.** (#67) Resize votes ride the persistent subscription
  fd, so the smallest-client rule survives reconnects instead of decaying to the last writer.
- **Daemon/session correctness.** (#69) `joinPane` validates before mutating (no partial
  layouts), client attach/detach hooks always fire in pairs, and dead panes drop their stale
  metadata and keep their exit status.
- **Config/CLI hardening.** (#68) `unbind` now writes a tombstone so a re-`source-file` can't
  resurrect the binding, a corrupt `buffers.json` is backed up instead of silently replaced,
  CLI targets are strictly validated, and `set-environment` global writes land in
  `environment.json`.

## [1.3.2] - 2026-06-04

The delivery release: updates now reach the parts of Harness that live outside the app bundle.
After updating, the first launch restarts the daemon once to pick up the new build — sessions
and scrollback come right back; anything running in a pane restarts.

### Fixed
- **App updates now actually update the daemon and CLI.** (#60) The launchd-supervised
  `HarnessDaemon` and the on-PATH `harness-cli` live under
  `~/Library/Application Support/Harness/bin/` (placed there by onboarding or
  `harness-cli install`), but app updates only replaced the copies inside Harness.app — so
  daemon-side fixes (like the 1.2.0 `TERM_PROGRAM` identity fix, #39) never reached updated
  installs. The app now refreshes the installed copies from the bundle on launch
  (remove-then-copy, so the kernel's per-vnode code-signature cache can't kill the new daemon),
  points the LaunchAgent at the canonical installed copy, and detects a stale running daemon
  through a real version handshake — `daemon-stats` now reports the daemon's version/build —
  instead of a file-timestamp heuristic that any daemon restart defeated. The first launch
  after updating restarts the daemon once to pick up the new build (sessions and scrollback
  replay; running pane processes restart).
- **Daemon/CLI version constants no longer drift.** `TERM_PROGRAM_VERSION` and the XTVERSION
  reply said 1.2.0 on 1.3.x builds because the shared version constant missed the release
  bump; packaging and the release workflow now fail when it disagrees with Info.plist.

### Added
- **`harness-cli version`** prints the CLI's version/build and the running daemon's, and flags
  a mismatch. `harness-cli doctor` gained a "Daemon version" check that warns when the running
  daemon's build differs from the CLI's.

## [1.3.1] - 2026-06-04

The fluidity release: resize-drag and scrolling re-measured on 120Hz hardware and fixed at the
root — drag presents now cost ~1.7ms on the main thread (was ~12ms) and trackpad scrolling is
pixel-smooth.

### Added
- **Pixel-smooth scrolling.** Trackpad scrolling moves by sub-line fractions instead of whole
  cells: the fraction renders as a vertex-stage translate over the unchanged GPU row cache (a
  fraction-only tick re-encodes nothing and uploads nothing), with a real content row revealed
  at the edge. Line-based features (selection, copy mode, find, prompt jumps, mouse reporting)
  keep their exact semantics; clicky mouse wheels keep the classic 3-line notch.
- **Fluidity measurement tooling.** `PREVIEW_SIGNPOSTS=1 make preview` now actually enables the
  frame signposts (`open` strips the environment, so the flag travels as a launch argument), and
  `Scripts/measure-fluidity.sh` drives a real resize drag + scroll fling while reporting present
  p50/p95 breakdowns from the unified log.

### Fixed
- **Resize-drag lag.** Three compounding causes: every drag tick paid a full GPU re-encode
  (the repaint now reuses the row cache — zero rows re-encoded on sub-cell ticks); streaming
  output presented through the synchronized path mid-drag (it now defers to the per-tick
  repaint and flushes at drag end); and the drawable pool of two blocked the next tick behind
  the window server for most of a frame (a third drawable is held for the duration of the drag
  only — keystroke echo latency is untouched). Measured: drag present p50 ~12ms → ~1.7ms,
  zero dropped frames, with the glitchless edge-latch preserved.
- **Scroll-while-busy hitches.** Wheel events no longer wait on the parser's queue for the
  history count; a main-thread mirror keeps the clamp lock-free under heavy output.

## [1.3.0] - 2026-06-04

The smoothness release: window resizing and scrollback scrolling rebuilt at the presentation
layer for Ghostty-class feel, plus a first-run font fix.

### Added
- **Glitchless live resize.** While dragging a window edge, every frame now presents inside
  the same Core Animation transaction as the window's new frame
  (`presentsWithTransaction` + commit → wait-until-scheduled → present), so the terminal
  content stays latched to the edge instead of lagging it by a frame or two.
- **Scroll-delta rendering.** Scrolling through history now rebuilds only the rows the scroll
  exposed: the frame builder shifts the previous frame's surviving rows (~7× faster per
  tick), and the GPU row cache rotates in place — kept rows skip glyph shaping and atlas
  work entirely.
- **Present-pipeline instrumentation.** With `HARNESS_FRAME_SIGNPOSTS=1`, the present
  signpost now logs a rolling p50/p95 breakdown (drawable wait / GPU back-pressure /
  transaction schedule) plus a genuine frame-drop counter.

### Fixed
- **Text shimmer while resizing.** Balanced window padding re-centered the grid on every
  sub-cell layout, shifting the text ±1px per pixel of drag; the origin now anchors for the
  duration of the drag and re-centers once at release.
- **Resize lag after release.** The grid reflow + `SIGWINCH` commit now fires the moment the
  drag ends instead of waiting out the coalescing delay (which still applies to animated
  resizes like sidebar slides).
- **Broken letter-spacing on first run.** On machines without the configured font family
  (e.g. a fresh install without the default Nerd Font), the renderer silently accepted a
  proportional system font whose advances disagree with the cell grid; it now falls back to
  Menlo, keeping text monospace-correct. Nerd icon coverage is unchanged.
- **Stale rows after a dropped frame.** A present that failed transiently (no drawable /
  encode failure) could leave the renderer's row-reuse cache disagreeing with the screen;
  the caches now reset on any drop so the retry re-encodes from frame content.

## [1.2.0] - 2026-06-03

A quality-of-life release aimed at 1:1 parity with the polish of a mainstream GPU terminal:
resize that feels instant, Ghostty-minimal chrome, protocol fills (focus reporting, alternate
scroll, OSC 9;4 progress), and a pre-release audit's worth of bug fixes.

### Added
- **Live re-wrap while resizing.** Dragging the window edge now re-wraps the visible viewport
  every frame (at viewport cost, not history cost) and the full reflow commits when the drag
  settles — with a byte-identical wide-character (CJK/emoji) reflow fix and a height-only
  resize fast path that skips re-wrapping entirely when the width didn't change.
- **Agent working dot (OSC 9;4).** Agents that emit ConEmu progress reports (Claude Code, …)
  drive a working indicator on the tab pill directly from the protocol — same handling as
  Ghostty, including consuming `OSC 9;4` so it never fires as a desktop notification. Agents
  that don't emit it fall back to output-recency detection.
- **Transient scrollbar.** A thumb-only overlay scrollbar appears on the right edge while
  scrolling and fades out once the viewport settles.
- **Draggable title strip.** A slim strip above the tab bar shows the active tab's folder
  icon + basename and gives the window a generous drag target (hidden while an agent owns
  the pane).
- **Window edge hairline.** A faint perimeter line around the window (Ghostty-style), themed
  and configurable (`windowBorderHex` / `windowBorderOpacity` in Settings ▸ Colors).
- **Alternate-screen wheel scrolling (DECSET 1007).** The scroll wheel/trackpad now scrolls
  `less`, `man`, and other full-screen TUIs by synthesizing arrow keys when the program didn't
  enable mouse reporting — on by default, programs can opt out with `CSI ? 1007 l`.
- **Middle-click paste.** Middle click pastes the current selection (the X11/Ghostty primary-
  paste convention), falling back to the clipboard — with bracketed paste and paste protection
  applied exactly like ⌘V.
- **Bold is bright toggle.** Settings ▸ Colors can now disable the classic bold→bright-palette
  mapping (`bold-is-bright` in an imported Ghostty config is honored too).
- **Command-finished threshold control.** The long-running-command notification threshold is
  now editable in Settings ▸ Agents (previously JSON-only).
- **Live resize overlay.** Resizing the window shows the live grid size (e.g. `120 × 32`) and fades
  out once it settles. Configurable in Settings ▸ Appearance (`after-first` / `always` / `never`).
- **Balanced window padding.** The grid is now centered — the leftover sub-cell space is split
  evenly on both sides instead of being parked at the bottom-right edge. Toggle "Center grid" in
  Settings ▸ Appearance.
- **Word, line, and rectangular selection.** Double-click selects a word, triple-click selects a
  line, and Option-drag makes a rectangular (block) selection — using the same word rule as copy
  mode. Copy-on-select copies the expanded selection.
- **Hollow cursor when unfocused.** When the window loses focus the cursor becomes a hollow box
  outline (standard macOS behavior), so it's clear which window is active.
- **Minimum contrast.** An optional WCAG contrast floor lifts dim foreground text to a chosen ratio
  (Settings ▸ Colors, 1 = off). Honored from an imported `minimum-contrast` config value.
- **Automatic light/dark theme.** Pick a light and a dark theme and Harness follows the macOS system
  appearance, switching live (Settings ▸ Appearance ▸ "Auto light/dark").
- **Paste protection.** Pasting text with line breaks or control characters now asks for
  confirmation when the program hasn't enabled bracketed paste — guarding against blind command
  execution. On by default (Settings ▸ Terminal).
- **Long-running command notifications.** Optionally get a desktop notification when a command that
  ran longer than a threshold finishes in an unfocused window (uses OSC 133 shell-integration
  timing; off by default, Settings ▸ Agents).
- **Non-native ("fast") full screen.** A new ⌃⌘⇧F fills the screen without the macOS Spaces
  animation, alongside the existing native ⌃⌘F.
- **Terminal identity (`TERM_PROGRAM`, XTVERSION, secondary DA).** Harness now introduces itself to
  programs: it exports `TERM_PROGRAM`/`TERM_PROGRAM_VERSION` and answers the XTVERSION (`CSI > q`) and
  secondary-DA (`CSI > c`) identity queries. A new Settings ▸ Advanced ▸ "Terminal identity" control
  (also `harness-cli set-option terminal-identity …`) chooses between **Compatible** (default —
  reports a protocol-compatible identity so tools like Claude Code enable the Kitty keyboard protocol
  immediately) and **Harness** (the true name + version).
- **Paste a screenshot.** ⌘V with an image on the clipboard now writes it to a temp PNG and pastes
  the file path (bracketed-paste-wrapped), so agents that accept image-file paths — Claude Code, etc.
  — attach it. Pasting a file copied in Finder works the same way.
- **Agent activity indicators.** Tab pills and the notch HUD show a working dot while an agent
  is busy (driven by OSC 9;4 when the agent emits it, output recency otherwise) — alongside the
  existing red waiting count and sidebar bell. Honors Reduce Motion.

### Changed
- **Ghostty-minimal pane chrome.** Pane borders, waiting rings, and corner badges are removed
  by design — the tab dot (plus the sidebar bell and desktop notifications) is the working /
  attention indicator. Unfocused panes still dim. If you relied on the blue waiting ring,
  watch the tab pill instead.
- **Typing latency.** A measurement pass confirmed keystroke→photon latency is at the local
  floor; input handling gained no extra cost from this release's features.

### Fixed
- **Resize-drag preview cursor.** With the cursor parked well above the bottom of a filled
  viewport, the live re-wrap preview mapped the cursor to the top-left corner for the duration
  of the drag (it snapped back on release). The preview also no longer flashes a cursor that
  the program explicitly hid (DECTCEM).
- **Selected text honors minimum contrast.** With a contrast floor set, selected cells lifted
  their text color against the cell's own background, not the selection highlight actually
  drawn behind them — dim text could turn unreadable while selected.
- **Cursor-text color is honored.** The theme/imported `cursor-text` color (the glyph under a
  block cursor) was accepted by Settings but never reached the renderer, silently drawing the
  canvas background color instead.
- **Working state agrees everywhere.** The notch HUD now consumes the same OSC 9;4 progress
  signal as the tab-pill dot, so the two can't disagree about whether an agent is busy; the
  tab dot's animation now honors Reduce Motion.
- **Settings: toggling auto light/dark no longer drops in-flight edits.** The toggle bypassed
  the normal flush path, losing e.g. a color-well change made just before it.
- **`ESC c` (RIS) abandons command timing.** A full reset no longer lets a later OSC 133;D
  report a spurious "command finished" measured from before the reset. (Plus: XTVERSION replies
  no longer carry a trailing space when no version is set.)
- **Copy-mode scroll state stays in sync.** Entering/leaving copy mode resets the scrollbar
  and the sub-line wheel remainder, so the first wheel tick afterwards isn't swallowed.
- **`respawn-pane` clear-history flags unified.** `harness-cli respawn-pane` accepts `-k`
  alongside `--clear-history`, and the command grammar accepts `--clear-history` alongside
  `-k` — the two layers previously each understood only their own spelling.
- **Focus reporting (DECSET 1004) now actually reports.** The mode was tracked but `CSI I`/
  `CSI O` were never sent on focus changes — vim/tmux autocommands now fire, including when
  the whole window activates or deactivates (which also fixes the hollow-cursor state for
  window-level focus changes).
- **Ghostty `theme = light:Name,dark:Name` imports correctly.** The dual-appearance form was
  stored verbatim, failed the catalog lookup, and silently fell back to the default theme; it
  now maps onto the auto light/dark theme pair.
- **Unterminated escape strings can no longer eat your output.** CAN/SUB now abort an
  in-progress OSC/DCS/APC sequence (VT500 "anywhere" rule); previously an unterminated string
  left the parser consuming everything until the next ESC.
- **Scrollback persistence can no longer truncate itself.** If the scrollback log couldn't be
  opened for append, the fallback rewrote the whole file with just the newest chunk —
  discarding all prior history. The fallback now rewrites existing + new content, and drops
  the write rather than the history when the file can't be read.
- **`respawn-pane` keeps your working directory.** The cwd is probed before the old shell is
  signalled (not after, when the PID is already gone), and a shell that exited on its own
  respawns into the tab's last-known cwd instead of `$HOME`.
- **Command palette covers every tab.** The Tabs section listed only the active session's
  tabs; tabs in other sessions were unreachable. It now lists all sessions' tabs (labelled by
  session) and removes a duplicate "New Session" entry that corrupted the recents list.
- **Command prompt history navigation.** Down from a blank prompt no longer recalls history,
  and Down past the newest entry returns to your in-progress draft (readline behavior).
- **Tab drag survives background reloads.** A metadata refresh landing mid-drag (e.g. an
  agent status update) silently cancelled the reorder; the drag now commits first.
- **Waiting tabs in the overflow menu show a bell, not a checkmark.**
- **Security: OSC 8 hyperlinks no longer open `file://` URLs.** Terminal output (including
  from remote hosts) could plant a ⌘-clickable link to an arbitrary local path —
  NSWorkspace executes `.app`/`.command` targets on open. `http(s)`, `mailto`, `ftp(s)`
  remain allowed.
- **Daemon shutdown no longer truncates in-flight replies.** Pending client responses (e.g. a
  large `capture-pane`) get a bounded drain before the sockets close.
- **`harness-cli` reaps its SSH tunnels.** Tunnel `ssh` processes and forwarded sockets in
  `runtime/tunnels/` are cleaned up on process exit instead of lingering.
- **Shift+Enter inserts a newline in Claude Code (#39).** Claude Code only enables native Shift+Enter
  once it recognizes the terminal; Harness previously advertised no identity, so the Kitty keyboard
  protocol stayed off and Shift+Enter submitted. Harness now reports a compatible identity by default
  (see "Terminal identity" above), so Shift+Enter works out of the box.
- **Onboarding is readable in light mode.** The onboarding window is now pinned to a fixed dark
  appearance, so its light text/logo no longer rendered invisibly on a light glass panel on
  light-mode Macs. The install screen's Daemon row now reports "Found HarnessDaemon" instead of
  duplicating the CLI's "Found harness-cli".
- **Nerd Font / Powerline glyphs render correctly (#37).** Prompt icons and Powerline separators
  rendered as "tofu" boxes (□) when the configured font wasn't a Nerd Font or its name didn't
  resolve cleanly. Harness now bundles a symbols-only Nerd Font as a guaranteed fallback for icon
  codepoints and resolves the configured font more robustly, so shell prompts (Starship,
  Powerlevel10k, …) render their symbols regardless of the primary font.

## [1.1.2] - 2026-06-02

### Added
- **Finder "New Harness Tab/Window Here."** Right-clicking a folder in Finder now offers
  "New Harness Tab Here" and "New Harness Window Here" (via `NSServices`), opening a Harness
  terminal rooted at that folder — the system "open terminal here" workflow, at parity with
  other terminals.
- **Full Kitty keyboard protocol.** The terminal now implements the complete progressive-
  enhancement protocol — event types (press/repeat/release), alternate keys, report-all-keys,
  and associated text — so modern TUIs (Neovim, Helix, …) get unambiguous key reporting.
  Functional, lock, and modifier keys report their Kitty codepoints; F13–F20 are supported.
  Legacy output is byte-identical until a program opts in.

### Fixed
- **Shift+Tab (back-tab) now reaches the PTY.** macOS delivers Shift+Tab as `NSBackTabCharacter`
  (0x19), which was dropped before encoding — it now correctly emits `ESC[Z` (and the Kitty
  form when enabled), so back-tab navigation in full-screen TUIs works.
- **Smooth window resize during heavy output.** Resizing while text streamed was jumpy because
  each drag frame rebuilt the terminal frame synchronously behind the output parser. The drag
  now re-presents the cached frame without touching the parser queue; the grid reflows once when
  the drag settles — matching the smoothness of other GPU terminals.

### Changed
- **"Set as default terminal" now claims the full terminal type set.** Beyond
  `ssh`/`telnet`/`x-man-page` links and `.command`/`.tool` files, Harness now registers for
  `public.unix-executable` and shell scripts (`.sh`/`.zsh`/`.csh`/`.pl`, `public.shell-script`),
  and the script/command claim is promoted from Alternate to Default rank — so scripts and
  executables open in Harness instead of falling through to another terminal.

## [1.1.1] - 2026-06-02

### Fixed
- **Crash when setting Harness as the default terminal.** Clicking "Set Harness
  as default terminal" in Settings ▸ Terminal crashed immediately
  (`EXC_BREAKPOINT`). `NSWorkspace` invokes its `setDefaultApplication`
  completion handlers on a background queue, but the handlers had inherited
  `@MainActor` isolation from the enclosing type, so Swift 6's executor-isolation
  check trapped on entry. The completion closures are now `@Sendable`
  (non-isolated); the `NSWorkspace` call itself still runs on the main actor.

## [1.1.0] - 2026-06-02

### Added
- **Remote & headless daemon.** Run `HarnessDaemon` on a headless or remote box and
  drive it from the CLI with a global `--host <name>` flag, tunnelled over your existing
  SSH trust — no new crypto. Register hosts with
  `harness-cli remote add --name <name> --ssh <user@host> --socket <remote-path>`, and
  list/remove them with `harness-cli remote list` / `harness-cli remote remove`. Every
  client command (`ping`, `new-session`, `send-keys`, `capture-pane`, `doctor`, …) accepts
  `--host`. The daemon and `harness-cli` now build and run on **Linux** (headless), in
  addition to the macOS app.
- **Persistent scrollback.** A pane's scrollback is persisted to disk per surface and
  restored when the daemon restarts, so history survives a daemon restart or crash.
  `respawn-pane --clear-history` drops the persisted history.

### Changed
- **Settings overhaul.** A native, themed Settings window with grouped sections
  (Appearance · Colors · Terminal · Keys · Agents · Advanced) and more customization;
  the placeholder preview was replaced with a theme-true live pane.
- **Agent tooling.** Agent hooks and setup prompts, with a one-click "Install hooks"
  button per agent in Settings ▸ Agents.
- **Window memory & terminal UX.** Window position/size is remembered across launches,
  plus assorted terminal UX improvements.
- **Faster VT engine.** The VT parse hot path is 1.5–1.66× faster on unicode/throughput
  workloads, with byte-identical output.

### Fixed
- **Daemon launch reliability.** Release startup now installs/bootstraps the launchd
  LaunchAgent first, so `HarnessDaemon` is launchd-supervised from the start. This
  eliminates an "another HarnessDaemon is already running" retry loop; a directly-spawned
  child is used only when launchd can't bring one up. Verified on a clean macOS VM
  (launchd-parented, `runs = 1`, no retry loop).
- **IME composition.** The input method now owns keys while a composition is active, so
  dead keys and multi-stroke input commit correctly.
- **Xcode/package wiring.** The first-party `CHarnessSys` C shim is exposed as an SwiftPM
  product so xcodegen-generated Xcode builds match the SwiftPM build.

## [1.0.6] - 2026-06-02

### Added
- Agent Notch HUD for at-a-glance agent activity.

### Changed
- Daemon read-path performance improvements.

## [1.0.5] - 2026-06-01

### Fixed
- Theme fidelity fix plus a batch of reliability and security-audit fixes.

## [1.0.0] - [1.0.4] - 2026-06-01

Initial public releases of Harness: a native macOS terminal with its own GPU
rendering engine, daemon-owned sessions/tabs/splits, `harness-cli` automation, the
`attach-window` compositor, agent detection and notifications, 490 built-in themes,
and a signed/notarized DMG with Sparkle auto-update. See the
[GitHub Releases](https://github.com/robzilla1738/harness-terminal/releases) for the
per-patch detail.

[1.4.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.4.0
[1.3.2]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.3.2
[1.3.1]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.3.1
[1.3.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.3.0
[1.2.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.2.0
[1.1.2]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.1.2
[1.1.1]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.1.1
[1.1.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.1.0
[1.0.6]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.0.6
[1.0.5]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.0.5
