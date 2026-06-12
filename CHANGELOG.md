# Changelog

All notable changes to Harness are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Harness follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each released version
has a matching `vX.Y.Z` tag and a signed, notarized DMG on
[GitHub Releases](https://github.com/robzilla1738/harness-terminal/releases).

## [Unreleased]

### Fixed
- **Reopening the app no longer types stray characters at the prompt.** (#168) On reattach,
  persisted scrollback was replayed through the emulator, which re-answered the queries
  embedded in it — Powerlevel10k's DECRQM and kitty-keyboard probes came back as
  `2026;2$y2027;0$y1u1u` typed at the shell, long after anything was waiting for them.
  Replayed bytes still restore state (grid, title, cwd, modes), but no longer write query
  replies to the PTY — and historical bells, desktop notifications, OSC 52 clipboard writes,
  and command-finished reports stay quiet on replay too, instead of re-firing on every
  reopen. A query split across the replay→live boundary (a program actively waiting while
  you attach) still gets its answer.
- **Selections survive scrolling.** (#161) Selecting text and then scrolling — even a grazing
  trackpad flick — cleared the selection. Selections are now anchored to the content
  (absolute buffer lines, the same space copy mode uses) instead of the viewport: the
  highlight rides the text as you scroll or as new output pushes it into history, ⌘C copies
  the selected lines even after they've scrolled out of view, and a triple-click's logical
  line keeps its off-screen wrapped tail. Typing, pasting, and resizing still clear the
  selection, as before.

## [1.11.0] - 2026-06-11

An engine efficiency pass. The theme is paths that did per-item work where one pass would
do: per-byte OSC consumption, per-cell search Strings, per-chunk main-thread dispatches,
whole-file reads to keep a file's tail. Plus one real bug the audit turned up in the
hyperlink registry.

### Changed
- **Inline images and clipboard writes parse 7–10× faster.** (#164) OSC payloads were decoded
  to a String (full UTF-8 validation + copy of a multi-megabyte base64 body), re-encoded back
  to bytes, then decoded to a String *again* — and the parser consumed every payload byte
  one at a time through the state machine. The dispatcher now routes by code bytewise, bulk
  payloads (OSC 1337 images, OSC 52 clipboard) stay byte slices end to end, and the parser
  bulk-consumes OSC bodies to the next delimiter. A 4 MiB inline image feeds in 5.6ms
  (was 41ms); an 800 KiB clipboard set in 0.5ms (was 4.9ms).
- **Find-bar keystrokes search the buffer 1.9× faster.** (#165) Each keystroke re-scans the
  whole buffer, and every cell built (and discarded) its own String. Per-cell units now come
  from a static ASCII table plus a codepoint memo; only cells carrying combining marks still
  pay the cluster build. A 20k-line search drops from 51ms to 27ms per keystroke.
- **Output floods no longer schedule per-chunk work on the main thread.** (#166) The off-main
  output path dispatched a main-queue hop for every PTY chunk — tens of thousands of
  dispatches per second under `yes`-class floods, all competing with input and rendering.
  Chunks now merge their post-parse state into one staged hop (1025 hops → 1 in the drain
  benchmark); a lone keystroke echo still hops immediately, so latency is unchanged.
- **Scrollback compaction streams the log's tail instead of reading the whole file.** (#163)
  Trimming an over-limit log read the entire file into memory on the same queue that
  persists output — up to 1 GiB with unlimited scrollback. It now seeks to the tail and
  streams it through a 4 MiB buffer; a 64 MiB log compacts in under 10ms.
- **Renderer encode path sheds its steady-state allocations.** (#167) Ligature run buffers,
  the prompt-gutter cache key, dirty-row sets, and splice spans were rebuilt per frame;
  row content keys were hashed twice per resize salvage. All now reuse or memoize, with
  byte-identical instance output.

### Fixed
- **A stale hyperlink can no longer point at a different URL.** (#162) When the OSC 8
  registry hit its flood bound it purged all entries *and reset the ID counter*, so links
  already on screen could silently resolve to whatever URL later landed on the recycled ID.
  Purged links now go dead instead.

## [1.10.0] - 2026-06-10

### Added

- **Shell integration is auto-injected at spawn** (zsh / bash / fish): prompt marks, the
  success/failure gutter, and jump-to-prompt work out of the box with no
  `install-shell-integration` step. zsh rides a `ZDOTDIR` shim that restores your real
  `ZDOTDIR` and chains to your own `.zshenv` — the integration loads from `.zshenv`
  (before `.zshrc`), so an rc that overwrites `precmd_functions=(…)` wholesale removes
  the marks (same as kitty/Ghostty); fish rides an `XDG_DATA_DIRS` vendor dir;
  bash uses the `--posix` + `$ENV` technique (kitty/Ghostty lineage) and **requires
  bash ≥ 4.4** — older bash (notably the stock macOS 3.2, which never reads `$ENV` under
  `--posix`) spawns untouched, the same floor Ghostty ships; **known caveats:
  `shopt -q login_shell` reports off inside injected bash panes** (the shim replays the
  login startup files itself) **and `~/.bash_logout` does not run on pane exit** (the
  shell is not a login shell under the injected vehicle). Idempotent alongside a manual
  install; never active for non-interactive shells; opt out with
  `set-option shell-integration off` (applies to subsequently spawned panes). User
  `set-environment` values always win: a collision with any of the injection's variables
  drops the whole injection for that pane (spawn untouched).
- Parity long tail (engine/core half): the numeric keypad honors DECKPAM/DECKPNM —
  application mode emits the xterm SS3 forms, numeric mode stays byte-identical to plain
  typing, and the kitty protocol reports the functional KP codepoints; OSC 1337
  `CurrentDir=` reports the cwd (absolute paths only, the OSC 7 trust policy) and
  `SetUserVar=` stores per-surface user variables (base64-decoded, name/size/population
  bounded, cleared by RIS) that the GUI surfaces as pane-scoped `@name` user options —
  readable from `#{@name}` format tokens; new `windowInheritCWD` setting (default **on**,
  matching the shipped behavior and Ghostty's default) lets new tabs/windows be pinned to
  `defaultCWD` instead of inheriting the focused pane's directory.
- `persist-scrollback` option (default on, per-pane with global fallback): turning it off
  stops writing a surface's scrollback to disk AND synchronously wipes what's already
  there — the secrets-at-rest control documented in the new `docs/SECURITY-POSTURE.md`
  (which also records the no-sandbox rationale, the hardened-runtime/notarization and
  Sparkle EdDSA/HTTPS audit, the Services surface, and the control-socket posture).
- `Scripts/scorecard.sh` + `docs/SCORECARD.md`: the Harness-vs-Ghostty comparative
  scorecard — cold start (per-phase from `startup.log` vs wall-clock-to-window),
  sustained PTY throughput (the cross-terminal stress runner, including the issue #27
  re-measure set), idle power (`powermetrics`, app + daemon summed), long-session memory,
  and Harness-side input-to-photon percentiles. Orchestration + reporting only — no
  production code; numbers are receipts, never CI gates; probe asymmetries are stated in
  the report itself.
- VT conformance polish (engine): DA1 now identifies as a VT220-class terminal with Sixel
  and ANSI color (`CSI ?62;4;22c`); DA3 (`CSI = c`) replies with DECRPTUI; DECRQM gains the
  ANSI (non-private) form (`CSI Ps $ p`) with the conformance-correct state-0 reply for
  unrecognized modes, and the private form now also reports modes 5/12/47/1047/1048/1049/1016;
  DECSET 1048 saves/restores the cursor; DECSET/DECRST 12 (att610) controls cursor blink;
  DECSET 5 (DECSCNM reverse video) and DECSET 1016 (SGR-pixel mouse) are tracked and
  reported (rendering/encoding land with the kit half); XTWINOPS `CSI 22/23 t` push/pop the
  title on a depth-capped stack and `CSI 18/14 t` report the text-area size in
  characters/pixels — the pixel report derives from the same host-supplied cell metrics
  inline images use (window resize/move remain deliberate non-goals).
- VT polish, kit/renderer half: any-event mouse tracking (DECSET 1003) now reports
  button-less pointer motion (deduped per cell), and SGR-pixel mouse (DECSET 1016) encodes
  pixel coordinates — taking precedence over 1006, degrading to cell coordinates when the
  host can't supply pixels; DECSCNM reverse video actually renders (the screen's default
  fg/bg swap, in every pipeline including resize previews and copy mode — explicit SGR
  colors keep their values); SGR blink (`SGR 5`) renders — blinking cells' glyphs hide on
  the off-phase, driven by a timer that exists only while blinking content is visible, and
  a phase flip re-encodes exactly the rows containing blink cells; dotted/dashed/undercurl
  underline patterns keep a continuous phase across cells instead of restarting at every
  cell boundary.
- **Session navigation from the prefix keymap** (#46): `prefix (` / `prefix )` cycle the
  focused sidebar session within the active workspace (tmux's `switch-client -p`/`-n` keys),
  backed by new `previous-session` / `next-session` / `select-session <index>` commands in
  the shared vocabulary — usable from the `:` prompt, rebindable via `keybindings.json` /
  `bind-key`, and routed through `CommandIPCTranslator` so the `attach-window` compositor
  and hook-fired commands resolve them identically (they are bindable verbs, not standalone
  `harness-cli` subcommands — the UUID-based `harness-cli select-session` is unchanged). The
  prefix cheatsheet lists the new keys, and an existing `keybindings.json` gains the two
  defaults on load without touching custom bindings.
- **Crisp text rendering now thickens glyphs** (#48): the Crisp mode (Settings ▸ Colors ▸
  Text rendering) applies Ghostty-style synthetic glyph thickening (a coverage-boost pass at
  full strength, alongside Crisp's existing coverage gamma) — and it applies *uniformly*
  across all three rasterization paths: single glyphs, shaped ligature runs, AND composed
  clusters (Thai base + vowel + tone marks via CTLineDraw), which previously rendered
  visibly thinner than their neighbors in crisp mode. The default (Native) stays
  byte-identical; CoreGraphics font smoothing remains off.
- **System appearance mode** (#58): a Settings ▸ Appearance popup — **Theme** (always render
  the selected theme) or **Follow macOS Appearance** with separate **Light Theme** / **Dark
  Theme** picks resolved live from the system appearance (terminal canvas and chrome both
  refresh on the macOS light/dark flip). Settings files carrying the legacy auto light/dark
  theme pair migrate to Follow macOS automatically, preserving both picks; switching modes
  (or either pick) clears stale per-theme color overrides so the new palette seeds cleanly; a
  source-terminal config import maps Ghostty's `theme = light:X,dark:Y` onto the same
  mechanism without overwriting visuals the user already customized.

### Changed

- **The Option key now types composed characters by default** — `@`, `|`, `é`, dead keys,
  whatever the macOS keyboard layout produces — matching Terminal.app / iTerm2 / Ghostty /
  kitty and unblocking international layouts that need Option for everyday symbols (#155).
  Readline/emacs users who relied on the old always-Meta behavior pick it back up in
  Settings ▸ Keys ▸ Option Key: *Meta (Esc+)*, or *Left/Right Meta* to split the two Option
  keys (the Ghostty `macos-option-as-alt` shape — the config import now carries it over,
  `left`/`right` included). Unchanged in every mode: ⌥←/⌥→/⌥⌫ word motion keeps its Esc
  encoding (macOS terminal convention), Ctrl+Option combos still take the escape-code path,
  `M-…` key-table bindings still match the physical modifiers, and Kitty-protocol reports
  stay spec-true — a composing Option no longer sets a stale alt bit.

- Mechanical decomposition (renderer): the Metal renderer's CPU-side instance/cache value
  types (GPU instance layouts, per-row encode caches, upload-cache keys) moved to
  `TerminalRenderInstances.swift` — same definitions, zero logic change.

- Mechanical decomposition (daemon + core): `SurfaceRegistry`'s output monitoring and the
  version-banner one-shot moved to extension files (same members, same locks — the
  single-lock serialization is untouched); `SessionEditor`'s split-tree algebra (the pure
  `PaneNode` walks/rewrites) moved to `SessionEditor+SplitTree.swift`; and
  `HarnessSettings.init(from:)`'s 35 uniform hand-written `decodeIfPresent ?? fallback`
  lines now funnel through a default-instance-driven keypath decoder — the typo class
  where a line decodes one key but falls back to a different field's default can no longer
  be written (migrations and deliberate non-default fallbacks stay hand-written).

### Fixed

- **Follow-macOS appearance now re-skins the terminal on the system light/dark flip** —
  the appearance handler refreshed window chrome only, so the canvas kept the pre-flip
  palette until an unrelated settings change forced a reapply; the flip now routes through
  the same full per-host re-apply the settings path uses (with a distributed-notification
  backstop for the transition). And **cleared color overrides stay cleared across
  relaunches**: absent color keys no longer fall back to the source-terminal import at
  decode (the import-aware fallback made "cleared" and "never set" indistinguishable and
  resurrected imported colors over an appearance-mode switch); first-run backfill remains
  the explicit signature-gated import in `load()`.

- A stale scrollback index can no longer crash a shipping build: `HistoryRingBuffer`'s
  empty-buffer release trap is replaced by a graceful fallback to the most recently
  appended line (the debug assert stays). The daemon also caps per-connection buffered
  partial-frame bytes at one max IPC frame + slack, dropping a stream that can never
  decode instead of buffering it without bound.
- **Unicode width tables are now derived from the Unicode Character Database** (15.1) instead of
  hand-curated ranges. The old tables missed ~140 East-Asian-Wide codepoints — including the
  emoji every modern CLI prints (⭐ ⚡ ✨ ❌ ✅ ⌚, the U+1F680–6FF transport block 🚀🚗, colored
  shapes 🟠🟢, and U+1FA70+ extended pictographs 🫠🫶) — which Harness measured width-1 while the
  child process's `wcwidth` counted 2, desyncing the cursor and overlapping glyphs in npm/vitest/
  cargo/agent-CLI output. The zero-width side gains the full combining repertoire (Devanagari
  virama, Hebrew/Arabic/Syriac/Indic/Lao/Tibetan marks, bidi isolates). Deliberate deviations are
  documented in `CharacterWidth.swift` (soft hyphen narrow; Hangul conjoining jamo V/T narrow
  until the grapheme layer composes syllables; regional indicators narrow per scalar).
- Configured terminal fonts resolve through one shared `TerminalFontResolver` (#48): the
  requested family is matched once against its family/PostScript/full/display names —
  detecting `CTFontCreateWithName`'s silent proportional substitution — and an unmatched
  family walks an explicit fallback chain (the default JetBrainsMono Nerd Font, then Menlo,
  then Monaco) before landing on monospace Menlo, the #37-era guarantee. The surface view,
  Metal renderer, and glyph rasterizer all construct from the same `ResolvedTerminalFont`,
  so the effective face — and the bold/italic faces derived from it — is identical at every
  call site instead of being re-derived privately inside the rasterizer.
- The Xcode scheme now runs ten test targets instead of four — engine conformance, reflow
  goldens, renderer parity, theme, onboarding, and compositor-parity suites were silently
  skipped in Product → Test (CI's `swift test` covered them; local Xcode runs did not).
- Sparkle is pinned to the same version (2.9.2, up-to-next-minor) in all three manifests
  (`Package.swift`, `project.yml`, `project.pbxproj`); they had drifted (2.6.0 in the Xcode
  path), letting SPM and Xcode builds ship different versions of the auto-update framework.
  A new CI `manifest-lint` job asserts the three stay in agreement.
- The stale-daemon PID-file identity check compares the exact executable basename instead of a
  spoofable substring match; the daemon's control socket is created under `umask(0o177)` so it
  never exists with broader permissions, even momentarily.
- Scrollback persistence is fsync'd: appends reach stable storage before the debounce window
  closes, and compaction syncs the replacement file before the atomic rename — a daemon crash
  can no longer lose the last ~2 s of scrollback or leave a truncated log.
- `wait-for` channels cap concurrent waiters (1 024) instead of accumulating blocked fds without
  bound; the agent scanner skips a tick when the previous scan is still running instead of
  queuing scans behind each other under load.
- The onboarding installer and the in-app "Install CLI" flow no longer run `launchctl` and
  version probes on the main thread (up to ~8 s of beachball on first run); the menu-bar menu
  no longer performs a blocking daemon round-trip inside `menuNeedsUpdate`.
- Structure changes in background tabs (e.g. a `harness-cli split` against an unfocused tab)
  now bump the structure revision — the fingerprint covers all live surfaces, not just the
  active tab.
- Store writes (options, hooks, environment, paste buffers) are debounced (150 ms) instead of
  hitting the disk synchronously under lock on every mutation; a graceful shutdown flushes all
  debounce windows. `source-file`-style bursts of `set-option` no longer serialize on disk I/O.
- Option/buffer save failures and remote-host lock degradation are logged to stderr instead of
  being silently swallowed.

### Performance

- Frame building with the find bar open no longer scans every search match per cell
  (O(matches × cells) — hundreds of matches over a 19 K-cell viewport while scrolling):
  highlights are bucketed once per build into per-row sorted merged column intervals that
  `appendRow` consumes with a monotonic cursor. The baked (`build`) and overlay
  (`applyHighlights`) paths share the one index, so they remain byte-identical by
  construction; pinned by randomized differential tests and a new
  `build_frame_search_highlights_160x48` benchmark (~200 hits).
- Idle-efficiency bundle: the cursor-blink timer now exists only while its pane is
  effectively focused and un-occluded (unfocused panes used to tick a 0.53 s timer forever
  just to early-out — 20 background panes ≈ 40 pointless main-runloop wakeups/s); the
  daemon's 500 ms monitor tick skips the registry lock and option reads entirely when no
  fresh output/bell arrived and silence monitoring is disarmed (the orphan sweep is
  preserved — racing-read entries are born flagged); and the shell cwd tracker parks its
  2 Hz process-tree scan while the app is inactive, relaxes to 0.5 Hz after ~5 s of no cwd
  movement, and snaps back on tab/pane creation, focus change, or any observed change.
- Git branch labels are event-driven instead of polled: the app watches each repository's
  resolved `HEAD` file (one watcher per repo/worktree, shared by all its tabs) and reads the
  branch in-process — no more `git rev-parse` subprocess per tab every 2 seconds, and labels
  update instantly on checkout instead of up to 2 s late. A tab that leaves a repository now
  clears its stale branch label (previously it stuck forever), and an identical branch
  re-send no longer bumps the snapshot revision or wakes subscribers.
- The GUI subscribes to the daemon's snapshot-push channel (the same one `attach-window`
  uses), so external structure changes (`harness-cli split-pane` against a GUI session)
  arrive instantly via push instead of being discovered by the old 0.5 Hz blind full-snapshot
  poll — which is gone, along with its forever-ticking fetch+decode even while idle and
  inactive. A 30 s app-active-only safety poll remains purely as push-loss insurance
  (the daemon drops subscribers whose write backlog exceeds its cap). Branch watchers and
  the safety poll pause while the app is inactive and refresh on re-activate.
- The PTY-output and keystroke IPC read loops consume frames in O(1) amortized via an
  offset-tracking read buffer (`IPCReadBuffer`) instead of `Data.removeFirst`'s O(remaining)
  byte shift per frame — quadratic under flood on both the app's subscription loop and the
  daemon's per-client loop. Keystroke writes no longer copy the payload an extra time
  (`writeFrame` writes straight from the frame's storage).
- The status line no longer constructs a `DateFormatter` per `#{time:…}` evaluation (cached by
  format, ~0.3 ms per 750 ms tick) nor re-resolves `#{host}`/`#{user}` via syscalls each tick;
  the daemon logger reuses one ISO-8601 formatter.
- On Linux, post-fork fd cleanup uses `close_range(2)` (kernel 5.9+, loop fallback) instead of
  up to 65 k `close` syscalls per shell spawn.
- The benchmark suite is now enforceable: `Scripts/benchmarks/compare_benchmarks.py` plus
  `make bench-record` / `make bench-check` gate hot-path regressions (>15 %) against a
  committed baseline (`benchmark-baselines.json`, recorded deliberately on real hardware).

### Removed

- Two dead empty-bodied functions that ran O(hosts × tabs) scans on every daemon sync
  (`syncWaitingRings`, `PaneContainerView.refreshChrome`), the stale `video-*` Makefile
  targets, and the 300 ms timing kick after tab/session creation (replaced by the
  notification-driven cwd scan).

## [1.9.0] - 2026-06-09

### Added
- **Quick terminal: a Quake-style global-hotkey dropdown.** A global shortcut (Settings ▸ Keys ▸
  Quick Terminal; default ⌘⌥`) drops a terminal down from the top of the active screen and toggles
  it away again, even when Harness is in the background. It floats above other windows, shows on
  every Space, and hosts its own session. It's built on Carbon `RegisterEventHotKey`, so it needs
  no Accessibility permission. Off by default.
- **Find bar: regular-expression and case-sensitivity toggles.** The find bar (⌘F) gains two
  latching buttons next to the search field: **Aa** (match case) and **{}** (regular expression).
  Search was previously substring-only and always case-insensitive; regex mode runs an
  `NSRegularExpression` over each scrollback line (an invalid pattern simply shows no results).
- **Unlimited scrollback.** Setting the scrollback line count to **0** (Settings ▸ Terminal ▸
  Behavior, or `scrollbackLines`) now means *unlimited* — the live history grows unbounded instead
  of trimming the oldest lines. Persisted (on-disk) scrollback is still capped by a large safety
  ceiling so a runaway process can't fill the disk.
- **Four Ghostty-style quality-of-life features.**
  - **Scroll speed multiplier** (Settings ▸ Terminal ▸ Behavior, or `scrollMultiplier`): scale
    mouse-wheel / trackpad scroll distance (1× = native). Previously a fixed 3-lines-per-notch.
  - **Hide cursor while typing**: the mouse cursor hides until the mouse next moves on a keystroke
    (off by default, matching Ghostty's `mouse-hide-while-typing`).
  - **Config reload-on-save**: editing `settings.json` or `keybindings.json` outside the app (a
    text editor, a dotfile sync, `harness-cli`) now applies live — no relaunch. The app's own saves
    are no-ops (it compares the reloaded values), and the watch survives atomic saves.
  - **Triple-click selects the logical line** across soft wraps (Ghostty/iTerm2/kitty), not just the
    one display row — driven by the engine's wrap flags.
- **Terminal bell feedback (audible / visual).** A bell (`\a` / BEL) on the *focused* surface
  previously produced no feedback at all — only a tmux window-flag + background notification. A
  new **Bell** setting (Settings ▸ Appearance: off / audible / visual / both, default **visual**)
  is honored on every bell regardless of focus: audible rings the system beep; visual flashes the
  ringing surface briefly. The tmux `visual-bell` / `bell-action` options bridge in — `bell-action
  off`/`none` silences everything (feedback and notification); `visual-bell on`/`off`/`both`
  overrides the audible/visual split. The unfocused OS-notification path is unchanged.
- **`clear-history` — clear a pane's scrollback without respawning the shell.** Previously the
  only way to clear scrollback was `respawn-pane -k`, which *kills the running process*.
  `clear-history` (alias `clearhist`) resets the in-memory ring **and** the persisted scrollback
  file in place and pushes `ESC[3J` to attached clients, leaving the shell untouched — so
  `bind C-k clear-history` is now real muscle memory. Takes the universal `-t` like every other
  per-pane verb (a missing target fails loudly, never clears the focused pane); CLI:
  `harness-cli clear-history --surface <id>`.
- **`status-interval` is now honored** (tmux: seconds between status-line redraws, default 15,
  `0` disables). The GUI status footer and the `attach-window` compositor both re-render the
  status band on this cadence so `#{time:%H:%M}` and other time tokens advance without an
  unrelated event; a runtime `set-option status-interval N` re-arms both in step. (The GUI
  previously hard-coded a 1s tick; it now follows the option like the compositor.)
- **Bindable `send-keys -l`/`-H`, `display-message -p`, and four more hooks.** `send-keys -l <text>`
  (literal) and `-H <hex…>` (raw bytes) now work from keybindings / the `:` prompt / hooks, not just
  the CLI (previously the flags were dropped and the words were token-parsed). `display-message -p`
  prints the rendered format to stdout for scripting. New hook events: `command-error` (fires when a
  server-executed command can't resolve, with the failing command as `#{hook}`), `pane-focus-in` /
  `pane-focus-out`, and `window-pane-changed` (active-pane change). A list-driven test now forces
  every hook event to have a firing test.
- **Copy-mode jump-to-char and friends.** vi `f`/`F`/`t`/`T` jump to a character on the line (the
  front-end captures the next keystroke as the target), `;`/`,` repeat the jump forward/reversed,
  `o` swaps the selection's other end, `goto-line N` jumps to a line, and `W`/`B`/`E` are bound as
  the whitespace-delimited (big-WORD) motions. Previously a bound `jump-forward` (etc.) was a
  parse-time failure. Works in both the GUI overlay and the `attach-window` compositor.
- **More format operators.** Building on the nested-conditional fix: `#{!=:a,b}` (not-equal),
  `#{||:a,b}` / `#{&&:a,b}` (logical or/and), `#{n:…}` (display-column length), `#{T:…}` (expand,
  then expand the result again), `#{a:65}` (character from a code point), and `#{pN:…}` (pad to N
  columns). Their argument is a format string, matching tmux (bare text is literal, `#{…}` expands).
- **Kitty graphics protocol: ack, query, transmit-once/place-many, delete.** The decoder was
  display-only; the control protocol is now answered. Commands with an image id/number get an
  `APC G i=<id>;OK ST` ack (or an `EBADF`/`ENOENT` error), gated by quietness (`q=1` silences OK,
  `q=2` silences errors) — so `icat`/`timg`/`chafa`, which gate on the `a=q` query reply, detect
  support instead of hanging. `a=t` transmits an image for later use and `a=p` places it (the
  transmit-once / place-many model image plugins rely on), and `a=d` deletes placements (`d=a`
  all, `d=i` by id) so a redrawing TUI can clear stale images. Animation (`a=a`) stays deferred.
- **`status-position` is now honored** (tmux `set -g status-position top|bottom`, default bottom).
  The GUI status footer moves to the top or bottom of the window and its `status 2..5` rows
  stack so the main line stays against the terminal; the `attach-window` compositor reserves and
  paints the band at the matching edge. Changing it in Settings ▸ Advanced re-lays-out live.
  Previously the option (and its Settings toggle) existed but nothing read it.
- **`@`-prefixed user options.** `set-option @my_var value` is stored and `#{@my_var}` now renders
  it (resolved through the scope chain, global preferred) — the mechanism theme/status-line
  `.tmux.conf` plugins rely on. Previously `@`-options were accepted but `#{@foo}` always read empty.
- **VoiceOver support for the terminal grid.** The Metal-backed surface view now conforms to the
  AppKit static-text accessibility protocol (role `.textArea`, the scrollback + screen as the
  accessible value, line/character navigation, cursor as the insertion point), so VoiceOver can
  read terminal output and navigate it — previously the grid was entirely invisible to it.
- **Secure Keyboard Entry** (Edit ▸ Secure Keyboard Entry, off by default). When on, Harness takes
  the process-global `EnableSecureEventInput` lock while it's the active app, so another local
  process can't keylog keystrokes typed at a sudo / ssh-passphrase prompt. The lock is released
  whenever Harness is backgrounded or quits (balanced accounting, pinned by test).

### Changed
- **Agent scanning builds the process tree once per tick.** The ~1.5s agent scan rebuilt the whole
  `pid → ppid` map once *per surface*; it now builds it once per tick and shares it across all
  surfaces (O(surfaces × processes) syscalls → O(processes)). The GUI shell-cwd tracker now uses
  that same shared `ProcessScan` primitive instead of its own duplicate. No behavior change.
- **One key-encoder.** `send-keys` / keybinding tokens are now encoded by the same engine
  `InputEncoder` that physical keypresses use, instead of a second hand-maintained escape table
  kept in agreement by hand. Tokens resolve to the engine's `SpecialKey`/`KeyModifiers` and gain a
  `modes:` seam for mode-correct encoding. Common keys are byte-identical; Option-modified editing
  keys now match a physical Alt+key (e.g. `send-keys M-Left` emits the readline word-motion `ESC b`
  rather than the CSI modifier form). The daemon's `send-keys` is mode-blind by design (it's a
  byte-pipe with no live per-surface emulator) and passes default/normal modes.
- **Layout persistence moved off the input-latency path.** The daemon no longer does a full
  prettyPrinted `layout.json` encode + atomic write under the registry lock on every mutation;
  writes are now coalesced through a 0.5s debounce and flushed synchronously on graceful
  shutdown, so a burst of agent activity no longer taxes keystroke latency. `layout.json` is now
  written compactly (still deterministically key-sorted).

### Fixed
- **The window-edge border now hugs the rounded corners.** The hairline border (Settings ▸
  Appearance) drew its corner with a fixed 10 pt radius read from the wrong layer. On macOS 26 the
  window server rounds corners at 16 pt, so that 10 pt arc fell outside the window's clip and
  disappeared, leaving the border on the straight edges only. It now reads the real corner radius
  and follows the system's continuous-curve corner, so the perimeter stays unbroken.
- **The agent notch opens and closes as one motion.** Closing faded the content out in about
  0.1 s while the shape took 0.45 s to collapse, so the pill emptied and then shrank. The content
  now fades on the same spring as the shape, the open/close springs are gentler, and the panel no
  longer re-asserts its frame and window level on every metadata tick, which had been interrupting
  the animation mid-flight.
- **The notch no longer shows one agent as both waiting and working.** A single Claude Code
  instance waiting on input could read "1 waiting" and "1 working" at the same time: a lingering
  OSC 9;4 progress signal promoted the waiting agent to working, and the two counts were tallied
  independently. Waiting now supersedes working wherever a count is derived.
- **The agent-update peek clears the notch.** On a notched Mac the peek's single line sat at the
  top of the card, partly behind the camera housing, so its title was clipped. Its content now
  sits below the notch reserve, the way the full dropdown already did.
- **Clicking a notch row restores a minimized window.** Before, it brought the window forward when
  it was in the background but did nothing when it was minimized to the Dock. It now deminiaturizes
  (and unhides) the target window before bringing it to the front.
- **`capture-pane` (plain mode) now strips DCS / charset-designation escapes.** The scrollback
  ANSI filter behind `capture-pane` (without `-e`) only neutralized CSI and OSC sequences, so a
  DCS reply (e.g. a DECRQSS/XTGETTCAP answer) leaked its raw payload and a charset-designation
  escape (`ESC ( B`) leaked a stray byte into the "plain text" capture. It now folds in the full
  C1 string family (DCS/SOS/PM/APC) and consumes multi-byte escapes (intermediates + final).
- **VT correctness cluster (REP / IRM / DECOM / DECSTR / DECALN).** Five control functions that
  were previously dropped now work: `CSI Ps b` (**REP**) repeats the preceding graphic character;
  `CSI 4 h/l` (**IRM**) toggles insert vs. replace mode so insert-mode editors shift the line
  instead of overwriting; `CSI ?6 h/l` (**DECOM**, origin mode) makes CUP/HVP/VPA address rows
  relative to the scroll region and confines the cursor to it; `CSI ! p` (**DECSTR**) performs a
  soft terminal reset (cursor visibility, insert/replace, origin, scroll region, saved cursor, and
  SGR back to defaults); and `ESC # 8` (**DECALN**) fills the screen with `E` for alignment.
  DECSTR/DECALN were being swallowed by the intermediate-byte guards, and REP/IRM/DECOM had no
  handler at all.
- **DCS device-control strings are now demuxed instead of all being fed to the Sixel decoder.**
  The parser routed any DCS containing a `q` into the Sixel decoder, so DECRQSS (`DCS $ q …`),
  XTGETTCAP (`DCS + q …`), and tmux control-mode passthrough (`DCS tmux; …`) decoded as nothing
  and were silently dropped. DCS is now demuxed by its header (params / intermediate / final):
  real Sixel still decodes, **DECRQSS** is answered for the settings the engine tracks (cursor
  style `DECSCUSR`, scroll region `DECSTBM`), **XTGETTCAP** answers the stable capabilities
  (`TN`, `Co`/`colors`, `RGB`), and tmux passthrough is recognized rather than misread.
- **Primary device attributes (DA1) now advertise Sixel.** The `CSI c` reply is `CSI ?1;2;4c`
  (feature code `4` = Sixel), so tools that gate graphics on the DA1 response (`img2sixel`,
  `chafa`, `timg`) will actually emit Sixel — which the engine decodes.
- **Three copy-mode motions were silently mis-aliased to the wrong action.** `next-word-end`
  landed on a word *start* (aliased to `next-word`), `top-line`/`bottom-line` jumped to the
  scrollback *extent* (aliased to `history-top`/`history-bottom`) instead of the visible top/bottom
  row, and `back-to-indentation` went to column 0 ignoring indent (aliased to `start-of-line`).
  Each is now its own motion — plus `middle-line` — and bound to the vi keys `e`, `H`/`M`/`L`,
  and `^` in copy mode.
- **`set-option` now rejects unknown option names loudly.** A typo or unsupported invention like
  `set -g moused on` was silently persisted and never read; it now fails with `unknown option: …`
  in every front-end (CLI, the `:` prompt, `source-file`). Real Harness options, recognized tmux
  options (accepted for `.tmux.conf` migration even when not yet honored), and `@`-prefixed user
  options are all still accepted.
- **Format conditionals can now nest an operator in the test.** `#{?#{==:#{pane_current_command},vim},…,…}`
  and friends (a `.tmux.conf` staple) previously evaluated the test only as a bare token, so any
  nested comparison/operator read as unknown → empty → falsy and the else-branch always won. The
  test is now evaluated as a full expression. Also removes a dead identity-no-op helper.

### Security
- **Paste-injection hardening.** A clipboard payload that embeds the bracketed-paste end marker
  (`ESC[201~`) can no longer terminate the paste early and run the trailing text as typed input —
  every embedded end marker is stripped before the paste is wrapped, matching kitty/ghostty/foot.
- **OSC 7 working-directory validation.** A directory report is now honored only when it is a
  `file://` URL resolving to an absolute path; a relative path, a non-`file` scheme, or junk is
  ignored, so program output can't steer the cwd inherited by new tabs.

## [1.8.0] - 2026-06-07

The tmux-parity close-out: every remaining tracked gap is either shipped, adapted with a
documented rationale, or explicitly rejected in [docs/TMUX_PARITY.md](docs/TMUX_PARITY.md) —
Harness now carries its own complete tmux at the capability level. Plus the first-run /
what's-new terminal banner. Each piece was review-hardened pre-merge (every Bugbot finding
adversarially verified, 39 additional findings fixed, all pinned by tests).

### Added
- **First-run welcome tour and post-update "what's new" banner.** A one-shot MOTD in the
  first fresh terminal: a quick tour on a clean install, the release highlights after an
  update. Daemon-injected like real shell output, never repeated (durable ack with retry),
  suppressible via the `update-banner` option.
- **~25 new `#{…}` format variables** — `pane_pid`, `pane_current_command`, `pane_width/height`,
  `pane_dead(+_status)`, `history_bytes`, `session_id`, `window_id`, `session_windows`,
  `window_panes`, `window_active`, `window_flags`, `session_attached`, `session_group`,
  `client_width/height/tty/termname`, `host(_short)`, `pid`, … — with tmux's `$`/`@`/`%`
  ID prefixes so displayed IDs round-trip into `-t` targets.
- **Full `-t` target grammar for `select-pane` / `swap-pane`**, plus `swap-pane -s <src>`
  (swap two arbitrary panes). Strict resolution everywhere: a `-t`/`-s` that names a missing
  session/window/pane fails loudly in every front-end — `kill-pane -t bogus` can no longer
  silently kill the focused pane.
- **Bindable config/buffer/hook verbs** — `set`/`setw`/`show`/`setenv`/`showenv`/`setb`/
  `pasteb`/`deleteb`/`lsb`/`showb`/`set-hook [--if]`/`show-hooks`/`unbind-hook` work from
  `bind-key`, the `:` prompt, hooks, and `source-file`, so a `.tmux.conf`'s config lines
  migrate unchanged.
- **`find-window`** (name/title by default, `-C` pane-content) with loud no-match in every
  front-end; tmux's `copy-mode-vi` table name accepted everywhere a table is typed.
- **Session/window lifecycle hook events** — `session-created/renamed/closed`,
  `window-renamed/linked/unlinked/layout-changed` — with subject-true contexts (a
  `session-closed` hook formats the closed session, not the survivor), plus `set-titles(+string)`,
  `detach-on-destroy`, and `display-time` options.
- **Grouped sessions** (`new-session -t <session>`, CLI `--group-with`): a shared window
  list with per-member focus; window create/kill propagates group-wide, including after
  members' layouts diverge.
- **Server-admin verbs** — `kill-server` / `start-server` adapted to launchd supervision
  (PID-identity-checked, remote-`--host` safe), `respawn-window`, `refresh-client`,
  `show-messages` (includes hook-fired messages).
- **`docs/TMUX_PARITY.md`** — the honest capability ledger: at-parity / adapted / rejected /
  deferred, with the no-silent-misroute invariant it protects.

### Fixed
- `synchronize-panes` is one state across the GUI, the SSH compositor, and `setw` — toggles
  write the per-tab option through, so a snapshot push can't revert a local toggle.
- GUI, compositor, and control mode surface daemon validation errors (unknown hook event,
  bad option scope) instead of reading as success; control mode emits `%error` for them.
- CLI `setw` writes the tab scope like every other front-end (it silently wrote a global);
  scoped CLI sets resolve the calling pane via `$HARNESS_SURFACE`.
- Option/env/buffer values that begin with `-` are no longer swallowed as flags (getopt-style
  parsing with `--` support); a bare `set-environment KEY` errors instead of persisting `""`.
- Detaching `attach-window` restores the outer terminal title (`set-titles`); destroying the
  attached session re-pins the surviving session's workspace.

## [1.7.1] - 2026-06-06

The post-release audit of 1.7.0: a second exhaustive multi-agent pass (56 hunt dimensions across
the release diff and the whole app, refute-by-default verification, every fix below pinned by a
regression test that fails on the pre-fix code where feasible).

### Fixed
- **RIS left the saved cursor alive, so `DECSC → RIS → DECRC` restored pre-reset state.** A full
  reset (`ESC c`) now clears the DECSC save like xterm; DECRC after RIS restores home + the
  default pen instead of leaking the old position and colors into freshly-reset programs.
- **A torn read in the hook registry could crash the daemon.** `bind-hook`/`unbind-hook` saves
  encoded the live hook array outside the lock; concurrent mutations made `JSONEncoder` trap
  (reproduced: index-out-of-range within 15 runs). Saves now snapshot under the lock, matching
  the option/environment stores.
- **Copying a selection after scrollback eviction silently produced blank text.** The selection
  anchor (unlike the cursor) was never clamped when history shrank under copy mode; stale anchors
  now clamp on every motion and at extraction, so `y` copies real content instead of whitespace.
- **Block/char selections dropped a wide (CJK) glyph when only its trailing cell was covered.**
  Extraction now includes any character whose span intersects the selected columns — the text you
  copy matches the cells the highlight covers.
- **`n`/`N` in copy-mode search jumped to stale rows after scrollback eviction.** Matches are
  re-derived from the live buffer on every search step instead of trusting line numbers cached at
  search time.
- **A wedged binary froze onboarding forever.** The install step's `version --json` probe had no
  timeout; a corrupted/stuck binary blocked the main actor with Continue/Skip locked until
  force-quit. The probe is now fully bounded (3s + SIGTERM/SIGKILL escalation) and surfaces as
  "no version info" so the install continues on the fallback path.
- **Settings fields could show a value the terminals weren't using.** Committing an out-of-range
  fontSize / window padding / scrollback now reflects the clamped value back into the field (the
  command-finished threshold already did); color swatches and placeholder hex now refresh when
  auto light/dark flips the theme while Settings is open.
- **`bind -n` (root-table) bindings ignored caps lock.** An uppercase letter typed without Shift
  now falls back to the lowercase binding, mirroring the prefix table — while Shift+letter stays
  distinct so a typed `C` is never swallowed when only `bind -n c` exists.
- **IME composition over a selection was indistinguishable from the selection.** Preedit text
  inherited the selection / find-highlight background; it now resets its cells to the canvas
  background (translucency intact) so composition always reads as "being typed".
- **`select-pane`/`swap-pane -t` silently misrouted bad targets to the next pane.** Unrecognized
  or dangling `-t` values now fail loudly with the accepted forms (`:.+`, `:.-`, `!`), like every
  other validated flag.
- **Status-line layout counted scalars, not columns.** `status-left`/`status-right` padding and
  `display-message`/`status-format` clipping in `attach-window` overflowed one column per wide
  (CJK) glyph; all measurement and truncation is now display-width-aware.
- **`harness-cli remote add` could report success without persisting.** Write failures in
  `remote-hosts.json` are now surfaced (exit 1, naming the file); concurrent CLI invocations are
  serialized with a cross-process file lock so the second writer no longer silently discards the
  first's hosts.
- **SSH tunnel failures all read as timeouts.** When `ssh` exits before the tunnel is ready the
  error now reports its exit status ("check the host, credentials, and remote socket path")
  instead of the generic not-ready-in-time message.
- **A dangling `--ssh-arg` was silently dropped**; it now errors with exit 64 like the other
  validated flags, and `bind-key`/`unbind-key` no longer eat a key spec literally named `prefix`
  when `-T` wasn't passed.
- **Killed panes leaked their terminal views.** The pane registry now prunes hosts that left the
  daemon snapshot on every structural sync, so split+kill cycles no longer accumulate dead
  Metal-backed views for the life of the app.
- **Hooks installed on Linux pointed at the macOS binary path.** `install-hooks` now emits the
  XDG path (`${XDG_DATA_HOME:-$HOME/.local/share}/harness/bin`) on Linux, so agent notifications
  actually reach the daemon there.
- **Closing a session never cleaned its scoped environment.** `set-environment -t <session>`
  entries now clear on session/workspace close instead of accumulating in `environment.json`
  forever.
- **A respawn racing the metadata scan could briefly publish the dead shell's cwd.** The off-lock
  cwd probe now records which child PID it measured and skips the commit when a respawn swapped
  the child mid-probe.

### Added
- **`.harnesstheme` files now open in Harness.** Double-click (or Open With) imports the theme —
  validate → "Install / Install and Apply" — installing into `Application Support/Harness/themes`
  and optionally applying its colors and appearance immediately. The format was already shipped;
  the app-side wiring was the missing piece.
- Regression tests pinning the daemon-reconnect backoff policy, the OSC 9;4 stale-progress
  timeout, corrupt `layout.json` recovery, reap-generation eviction order, and the onboarding
  probe failure modes (~45 new tests).

## [1.7.0] - 2026-06-06

The production-hardening release: a full adversarial audit (multi-dimension bug hunt →
refute-by-default verification → fixes → post-fix review → live validation) across the daemon,
IPC, terminal engine, CLI, settings, and onboarding. Every fix below was verified with a repro
or code-trace before it was written, and the fix batch itself was adversarially re-reviewed
(#96–#98 are that review's catches).

### Fixed
- **Daemon could refuse to start forever after a force-kill or reboot.** (#93) The stale-instance
  gate trusted `daemon.pid` + `kill(pid, 0)` alone; a recycled PID belonging to any live process
  made the fresh daemon exit, and launchd's restart loop never escaped. The gate now verifies the
  prior PID is actually a HarnessDaemon via `proc_pidpath` and otherwise clears the stale file —
  the socket-ping guard remains the authority.
- **Attaching to a busy surface could silently drop output.** (#95) Attach was
  replay-then-subscribe across two sockets with no backfill: bytes arriving in the window were
  persisted but never delivered (repro'd: 217 lost markers). Attach now subscribes first, buffers
  live frames, replays, then flushes the buffer deduplicated by the daemon's byte sequence — with
  a compatible fallback against older daemons.
- **Keystrokes typed while a daemon subscription was dying were silently dropped.** (#95)
  `sendInput` now reports failure and input immediately falls back to the one-shot request path.
- **Daemon startup could permanently delete scrollback for a surface whose shell failed to
  spawn.** (#93) The orphan-file sweep only considered live PTYs; it now keeps any scrollback
  referenced by the layout, so a transient spawn failure (fork pressure, missing shell) no longer
  costs the pane's history.
- **A keystroke could stall behind a full process-tree scan every 1.5s.** (#93) The metadata
  refresher held the registry lock — the one every IPC request needs — across an
  all-system-PIDs walk per pane (measured 6–12ms at 10–20 panes). The scan now runs off-lock
  with identity-checked write-back, plus a `childPID` read race and the log-rotation race fixed
  and the PID file made owner-checked.
- **Children that ignore SIGTERM+SIGHUP leaked a blocked reaper thread per close.** (#93)
  `close()`/`respawn()` now escalate to SIGKILL after a grace period, with PID-reuse guards;
  the watcher remains the sole reaper.
- **Thai: SARA AM after a marked base rendered a dotted circle** (น้ำ, ต่ำ, ซ้ำ). (#94, closes #66)
  U+0E33 now decomposes on input into NIKHAHIT (folded onto the base) + SARA AA, so CoreText never
  shapes an orphaned spacing mark; buffer search splits the needle the same way so precomposed
  queries keep matching, and the cursor-text color now applies on marked clusters.
- **`harness-cli bind-hook --if <cond>` crashed with a Swift range trap.** (#92) Malformed
  argument shapes now print usage and exit 1 before any IPC.
- **Invalid `--detach-keys` silently attached with the default detach binding.** (#92) Both attach
  paths now fail loudly (exit 64) naming the bad value and accepted formats; `new-split --pane`
  and `select-layout --main` with a malformed UUID now error instead of silently acting on the
  active pane.
- **CSI parameters above 65535 dropped the whole control sequence.** (#91) `ESC[99999H` (the
  "jump to bottom" idiom) was a no-op; oversized values now clamp (xterm/Ghostty parity) while the
  DoS guards for parameter count stay intact. Invalid DECSTBM (`top ≥ bottom`) no longer clobbers
  the scroll region and homes the cursor (now a no-op), and DECRC without a prior DECSC restores
  the default pen instead of leaking the current SGR state.
- **`fontSize` from a hand-edited settings.json was unclamped.** (#89) Extreme values blanked
  glyphs (atlas overflow at ~500pt) or allocated hundreds of MB of grid (sub-1pt); the persistence
  boundary now clamps to the same 8–32 the zoom shortcuts use. An empty font family now falls back
  to Menlo like an unknown one.
- **Re-running onboarding from an older Harness.app could silently downgrade newer installed
  binaries.** (#90) Install is now version-aware (build-number probe): byte-identical copies are
  skipped and a newer installed daemon/CLI is kept, with the outcome shown in the wizard.
- **The onboarding fish completion drifted from the real CLI.** (#90) The wizard now uses the same
  catalog-driven generator as `harness-cli completions`; the catalog gained the missing verbs and
  a drift-guard test asserts it covers every dispatch case.

### Changed
- **Slider drags persist once on release.** (#89) Opacity/blur/border/contrast drags wrote
  settings.json on every tick (60–120Hz); live-apply is now decoupled from persistence.
- **Destructive resets ask first.** (#89) "Reset to defaults" and "Reset agent colors" confirm
  before wiping; the resize-overlay position picker is now exposed in Appearance.
- **Hex color fields and the notification threshold re-sync after commit** instead of silently
  reverting invalid input. (#89)
- **A disconnected pane now shows a "Reconnecting…" chip** instead of freezing silently for up to
  a minute, and the Settings Advanced page shows an explicit banner (controls disabled) when the
  daemon is unreachable instead of rendering defaults as if they were real. Session IPC requests
  past 250ms now emit throttled signposts. (#95)
- **Onboarding locks navigation while installs run, notes when the CLI won't be on PATH, and
  rescans for agents when the window regains focus.** (#90)

### Added
- **SSH tunnel characterization tests** (16 — the remote-host path previously had zero coverage)
  and a **GridCompositor drift canary** asserting the onboarding preview's compositor port stays
  byte-identical to the live one. (#88)

## [1.6.0] - 2026-06-05

The redraw-efficiency release, from a proven-best-practice deep dive (kitty/foot/Alacritty/
Windows Terminal parity + Apple Metal guidance): overlays no longer disable damage-driven
rendering, streaming output reuses the scrolled band, and invisible panes stop presenting.

### Changed
- **Selection, find highlights, and IME composition ride damage-driven rendering.** (#85) Any of
  these used to force a full grid rebuild every frame for their whole duration and poison the
  reuse caches. The live view now always builds clean and a cell-overlay pass re-shades only the
  overlay rows (byte-identical by construction — it runs the same row resolver the baked path
  used); per-row fingerprints add exactly the changed rows to the damage. A selection drag
  re-encodes the rows it crossed instead of the grid; an idle find bar adds zero per-frame work;
  composition dirties only its row.
- **Streaming output shift-copies the scrolled band.** (#84) Whole-viewport scrolls (`cat`,
  builds, `tail -f`) report a purely additive damage hint; the frame builder re-resolves only the
  fresh rows and the renderer rotates its row-instance cache, as it already did for scrollback
  scrolls. Frame builds during streaming: 299µs → 74µs per tick at 200×60 (4×).
- **Covered and minimized windows stop presenting.** (#86) A pane with output flowing in a fully
  occluded window presented invisibly at full cadence; per Apple guidance it now never acquires a
  drawable while covered (parsing continues; one fresh frame presents on un-occlusion).
- **ProMotion displays render at the panel's full rate while active.** (#83) The render display
  link now requests the variable-refresh panel's maximum via `preferredFrameRateRange`; the link
  still pauses at idle.
- **Frame telemetry: p99 percentiles and classified drops.** (#83) The signpost flush line gains
  p99 (tail dropouts were invisible between p95 and max) and splits dropped presents by cause
  (drawable-pool exhaustion vs encode failure). Cursor-blink cost is pinned by test at ≤1
  re-encoded row per toggle (#87).

## [1.5.1] - 2026-06-05

Cursor and resize-fluidity fixes on the live-resize release: the cursor no longer turns into a
permanent block after a TUI resets it, streaming output keeps moving while you drag, and the
per-boundary re-wrap is 3× faster on deep scrollback.

### Fixed
- **Cursor stuck as a thick block after running a TUI.** (#80) `CSI 0 SP q` (and the parameter-less
  `CSI SP q`) — the standard "reset cursor" sequence programs emit on exit — was mapped to a hard
  blinking block instead of the user's configured style (the Ghostty/kitty/xterm de-facto
  semantics). Because attach replays the persisted scrollback tail, a leaked reset re-applied the
  block at every launch, making it look permanent. `0` now resolves back to your configured
  cursor style; `1` remains the explicit blinking block.

### Changed
- **PTY output presents live during a drag.** (#81) Output arriving mid-drag (a TUI's redraw after
  `SIGWINCH`, streaming logs, keystroke echo) previously reached the screen only at the next
  cell-boundary commit — content rode one boundary behind the drag and froze while the pointer
  held still. Output now presents continuously during the drag inside explicit Core Animation
  transactions. The resize target moved into queue-shared state (`pendingResize`) applied by
  whichever build runs next, so the latest-wins build coalescing can never strand the grid at a
  stale size after the PTY vote went out.
- **Width reflow is 3× faster on deep scrollback.** (#82) The per-boundary re-wrap — paid at every
  cell-boundary crossing of a live drag — streamed source rows by reference and re-wraps
  wide-glyph-free lines with bulk slice copies instead of three full buffer materializations and
  per-cell stepping. Measured at the 10k-line scrollback cap (release): 30.25ms → 10.04ms per
  reflow (CJK-heavy content 1.5×; the drag preview 2.6×). Byte-identical to the previous
  algorithm across the golden corpus, property, fast-path, and preview-parity suites.

## [1.5.0] - 2026-06-05

The live-resize release: dragging a window edge now drives the running program in real time
(Ghostty parity), notifications split into per-event controls, and agents launched through
wrappers are recognized.

### Added
- **Real-time live resize (Ghostty parity).** (#77) Dragging the window edge now reflows the grid and
  signals the running program (`SIGWINCH`) at every cell boundary, so interactive programs
  (vim/htop/btop/tmux/less) and alternate-screen TUIs redraw *during* the drag instead of snapping
  at release. The authoritative reflow runs off-main with latest-wins coalescing (a fast drag runs
  ~1–3 reflows, not one per column), presents inside an explicit `CATransaction` so it flushes even
  when the pointer is held still, and the PTY vote coalesces per-fd and to distinct cell counts so
  the daemon isn't stormed. Default on, with a **Real-time resize** setting (`liveResizeReflow`)
  that reverts to the previous defer-to-release behavior. The non-mutating re-wrap preview is
  retained as instant feedback under the live reflow.
- **Tab persistence indicator.** (#78) A tab pinned to stay running after a clean quit
  ("Keep Tab Running After Quit") now shows a small accent pin at the leading edge of
  its tab pill — a tmux-style window flag — so kept-alive tabs are identifiable at a
  glance instead of only through the right-click checkmark. The pin also appears beside
  the tab in the overflow menu.
- **Granular notification settings.** (#79) Settings → Agents now splits notifications into
  *Notify me about* (per-event toggles for **Agent needs input**, **Agent finished**,
  **Terminal bell**, and **Command finished**) and *Delivery* (macOS banner + sound),
  so you can pick exactly which events ping you instead of one all-or-nothing switch.
  Defaults preserve prior behavior, and an existing "command finished" choice migrates
  automatically. Backed by a new `NotificationEvent` type and a sparse
  `notificationEvents` map in settings; only desktop banners are gated — the in-app
  bell/waiting indicators are unaffected.
- **Wrapper-aware agent detection (Hermes).** (#51) Agents launched through a wrapper —
  `python3 …/hermes --tui`, `uv run hermes`, `env FOO=1 hermes` — are now detected: the
  process scan parses wrapper argv with flag-aware semantics (a `-c` body never false-matches;
  non-wrapper commands never scan their arguments, so `vim hermes-notes.txt` stays invisible).
  Agents without a bundled icon get a monogram glyph in the tab pill and agent UI instead of
  falling back to generic text.

### Fixed
- **Focusing a pane clears its notification.** (#61) Clicking into a pane or ⌘-Tabbing back to
  the app now clears its waiting badge — previously only a programmatic tab switch did. The
  clear is gated on the tab actually showing a waiting badge, so ordinary focus changes skip
  the daemon round-trip.

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

[1.5.1]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.5.1
[1.5.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.5.0
[1.4.1]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.4.1
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
