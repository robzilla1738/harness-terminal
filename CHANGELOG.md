# Changelog

All notable changes to Harness are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Harness follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each released version
has a matching `vX.Y.Z` tag and a signed, notarized DMG on
[GitHub Releases](https://github.com/robzilla1738/harness-terminal/releases).

## [Unreleased]

A quality-of-life pass aimed at 1:1 parity with the polish of a mainstream GPU terminal.

### Added
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

### Fixed
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

[1.1.0]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.1.0
[1.0.6]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.0.6
[1.0.5]: https://github.com/robzilla1738/harness-terminal/releases/tag/v1.0.5
