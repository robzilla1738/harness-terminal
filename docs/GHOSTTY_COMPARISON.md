# Harness ↔ Ghostty — side-by-side

Ghostty is an excellent **native GPU terminal**. Harness is a native GPU terminal **plus a
tmux-class multiplexer in one binary set** — the daemon-backed session model Ghostty has no
equivalent for. This ledger compares them feature-by-feature and records where Harness now
matches Ghostty, where it deliberately diverges, and where it has a structural edge.

Legend: ✅ have · 🟰 Harness-equivalent (different design, same capability) · 🛣️ deliberate
roadmap (documented, not shipped half-wired) · ➖ n/a.

---

## Rendering & fonts

| Capability | Ghostty | Harness |
|---|---|---|
| GPU-accelerated renderer | ✅ Metal/OpenGL | ✅ own Metal renderer (CoreText atlas, diffed) |
| Truecolor + 256 + 16 palette | ✅ | ✅ (`COLORTERM=truecolor`) |
| Ligatures (programming fonts) | ✅ | ✅ CoreText run shaping |
| Box-drawing / block elements | ✅ procedural | ✅ procedural (font-independent, seamless) |
| Underline styles (curly/dotted/dashed) + color | ✅ | ✅ (SGR 4:x / 58) |
| Reflow on resize | ✅ | ✅ (soft-wrap-aware) |
| Cursor styles + blink | ✅ | ✅ + **DECSCUSR** (program sets shape per mode) |
| Background opacity / blur | ✅ | ✅ one window-wide CGS blur, translucent canvas |
| Themes | ✅ (iTerm2-compatible) | ✅ **485 built-in** + `.harnesstheme` import/export |
| Wide chars / emoji / grapheme width | ✅ | ✅ (wide-aware; per-scalar) |
| **Custom background shaders** | ✅ | 🛣️ (Ghostty signature; not core to a multiplexer) |
| **Images (Kitty graphics / Sixel)** | ✅ | 🛣️ (see "Deliberate roadmap") |

## Terminal protocol

| Capability | Ghostty | Harness |
|---|---|---|
| Mouse (SGR 1006, 1000/1002/1003) | ✅ | ✅ + demuxed to panes in the ssh compositor |
| Focus reporting (1004), bracketed paste (2004) | ✅ | ✅ |
| Alternate screen (1049) | ✅ | ✅ |
| **Synchronized output (DEC 2026)** | ✅ | ✅ engine mode + renderer frame-hold + timeout (GUI **and** compositor) |
| **DECSCUSR cursor shape** | ✅ | ✅ block/bar/underline + blink, overrides the user setting |
| **OSC 8 hyperlinks** | ✅ | ✅ cell-level link registry; ⌘-click opens (safe-scheme allowlist) |
| **URL auto-detection** (no OSC 8) | ✅ | ✅ `NSDataDetector`; ⌘-click opens plain URLs too |
| **Dynamic colors (OSC 10/11/12, OSC 4)** | ✅ set + query | ✅ **query** (light/dark detection); set deliberately deferred to the theme |
| DECRQM mode reports (`?…$p`) | ✅ | ✅ (mouse / sync / bracketed / …) |
| OSC 52 clipboard | ✅ | ✅ (gated on `set-clipboard`) |
| OSC 7 cwd, OSC 0/2 title | ✅ | ✅ (drives the sidebar/tab labels) |
| DSR / DA / cursor reports | ✅ | ✅ |
| **Kitty keyboard protocol** | ✅ | 🛣️ (see "Deliberate roadmap") |
| Shell integration / semantic prompts (OSC 133) | ✅ | 🛣️ (Harness uses agent hooks + OSC 7 for the same UI today) |

## Multiplexing & sessions — **Harness's edge**

| Capability | Ghostty | Harness |
|---|---|---|
| Native tabs + splits | ✅ | ✅ workspaces → sessions → tabs → splits |
| **Detachable, persistent sessions** | ➖ none | ✅ daemon-owned; survives app quit / crash (launchd `KeepAlive`) |
| **Attach a window's full layout over ssh** | ➖ none | ✅ `attach-window` compositor (borders, SGR, status, cursor, mouse, copy-mode) |
| **tmux command/verb surface** | ➖ none | ✅ 1:1 superset (see [TMUX_PARITY.md](TMUX_PARITY.md)) |
| **Control mode (`-CC`)** | ➖ none | ✅ |
| **Multi-client, smallest-wins sizing** | ➖ none | ✅ |
| **Agent awareness** (Claude/Codex/Cursor/…) | ➖ none | ✅ detection, chips, notifications, `install-hooks` |
| Command palette (`Cmd+K`) | ✅ | ✅ |
| Config file + hot-reload | ✅ | ✅ `keybindings.json` / `options.json` / Settings; `source-config` |

## Platform / app

| Capability | Ghostty | Harness |
|---|---|---|
| Native macOS chrome | ✅ | ✅ (Liquid Glass on macOS 26) |
| IME / dead keys | ✅ | ✅ (`NSTextInputClient`) |
| Quick terminal (Quake dropdown) | ✅ | 🛣️ |
| Cross-platform (Linux) | ✅ | ➖ macOS-first by design |
| Ghostty config import | — | ✅ (opt-in, so Ghostty users keep colors/font) |

---

## Deliberate roadmap (honest gaps)

These are real Ghostty features Harness does **not** ship today. Each is deferred on purpose —
shipping a partial version would be the tech debt this project forbids:

- **Kitty graphics protocol / Sixel (images).** A large subsystem (image decode, placement,
  z-order, deletion, GPU texture lifecycle) that doesn't compose with the daemon→client byte-
  pipe cheaply. High value for some workflows; high bloat risk done wrong.
- **Kitty keyboard protocol.** Needs the parser to surface the private introducer (`>`/`<`/`=`/`?`)
  and a full CSI-u key encoder (functional keys, modifier bitmaps, event types, associated
  text). Worth doing as one clean addition, not a partial one — most TUIs work without it.
- **Custom background shaders / quick terminal.** Ghostty-signature polish, orthogonal to the
  multiplexer that is Harness's reason to exist.
- **OSC color *set*** and **OSC 133 semantic prompts.** Harness's theme owns the canvas colors
  (one resolver, no per-surface drift) and its agent-hook + OSC 7 plumbing already drives the
  sidebar UI; honoring program color-sets / prompt marks is additive when wanted.

## Where Harness already wins

A native GPU terminal that is **also** a detachable, scriptable, ssh-attachable multiplexer with
first-class agent awareness — in one self-contained, dependency-free Swift codebase. Ghostty is a
terminal; tmux is a multiplexer with no GPU renderer. Harness is both, and now matches Ghostty on
the high-frequency terminal features (synchronized output, hyperlinks, DECSCUSR, dynamic-color
queries, ligatures, themes, mouse, reflow) that users actually feel day to day.
