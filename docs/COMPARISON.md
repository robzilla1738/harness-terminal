# Harness and Rex (Superlogical)

An honest feature-by-feature comparison with Superlogical's Rex, based on its public docs and posts as of October 2026. Rex is in beta and its details change; where it states something without docs, the "Rex" column says so. "Not planned" rows are deliberate choices, not gaps we haven't reached.

## Sessions and the daemon

| Feature | Harness | Rex |
|---|---|---|
| Programs keep running when the app quits | Yes. HarnessDaemon owns every PTY; the app reattaches. | Yes |
| Restore after a reboot | Layout, scrollback, and a shell in each pane's last directory (the program itself is gone). | Same, stated |
| Attach | One request: the screen first for `harness-cli attach` (VT-encoded, modes included), history streamed as binary frames for the app. | Screen first, then history newest-first |
| Resume after a dropped connection | Yes: by daemon epoch and byte sequence, sending only what was missed. A restarted daemon or evicted bytes resync. | Yes |
| Per-client viewports | Each client scrolls on its own. | Same |
| Multi-client sizing | `smallest` (tmux) or `owner`; non-owners reflow locally, see "Viewing at C×R · Take", and can take the size. | Owner/advisory sizing, take, local reflow (designed) |
| Only one client answers terminal queries | The size owner. | Same |
| Read-only watching | `attach --read-only`; Copy Watch Command in the app. | Built in from the start (stated) |
| Idle cost | A pane quiet for a minute has its history held LZ4-compressed; reads decompress a copy. | LZ4 online grid compression, encrypted snapshots |
| Evented PTY I/O | Reads and writes: a pane frozen with Ctrl-S holds a buffer, not a thread. | Yes |

## Automation

| Feature | Harness | Rex |
|---|---|---|
| CLI covering the GUI | `harness-cli`: tmux verbs plus `ls`, `inspect`, `new`, `wait`, `run --wait`, `send` from stdin. | `rex` |
| Targets | Full id, label, position, ≥4-char id prefix or suffix; `-s`/`-w`/`-b`/`-S`; ambiguous exits 3. Default target is the caller's pane. | Same rules, `-s/-w/-b/-C/-S` |
| Exit codes | 0, 1, 2, 3 target, 4 unreachable, 130; waits exit with the program's status. | Same |
| JSON | `--json` on every list, inspect, and create. | `--json` |
| Self-describing API | `api list/describe/call`, JSON Schema, ~35 methods plus every bindable command. | `rex api` |
| Event stream | `events --follow`; `domain.verb` names. | `rex events` |
| Lua | `init.lua`: bindings, key modes, sequences, actions, function bindings. Scripts: `harness.on/wait/stop`, `harness.call` and a function per API method, `harness.layout`, `harness.args`, `harness.log`. | `init.lua`, key modes, sequences, actions, events |
| Program Status (OSC 7501) | Yes: tab spinners, blocked marks, the notch, `terminal.program_status`. | Yes (Rex published it) |

## The app

| Feature | Harness | Rex |
|---|---|---|
| Native splits | Yes, with pane headers. Drag a pane by its header to split, swap, move to a tab, or break out. New panes grow out of the one they split, closed ones shrink away, and the corner where two dividers meet drags both. | SuperSplit: animated, corner drags, cross-window drag |
| Tabs and vertical tabs | Title-bar pills or a sidebar. | SuperTabs, vertical tabs |
| Multiple windows, tab tear-off | Not yet: one window. | Yes |
| Dock tile | Up to four agents, ringed by attention; badge counts what needs you. | Deck icons |
| Tab peek and overview | Yes, with colored previews from the daemon's `vt` capture. | Metal-rendered live previews, gestures |
| Session names | "drifting cedar" style; rename in the switcher. | Same |
| Go to directory | ⌥⌘G browser on the pane's daemon, local or remote. | ⇧⌘G |
| Themes | 492 built in, save and export your own, theme fit for off-palette colors. | 41 designer themes, Oklab harmonization |
| VoiceOver | Tabs, panes, focus announcements. | VoiceOver in SuperSplit |
| Kitty graphics | Direct, file, temp-file, and shared-memory transmission; place-many; every delete target; Unicode placeholders (images that live in text, so they survive tmux and editors). Not yet: animation. | 100% (libghostty) |
| Kitty keyboard, OSC 52 | Yes; clipboard reads opt-in (`allow-clipboard-read`). | Yes |
| Rebind from the palette | Right-click any action ▸ Change Shortcut…; conflicts with menu items and other actions are flagged. | — |

## Remote

| Feature | Harness | Rex |
|---|---|---|
| Transport | SSH: your keys, config, and jump hosts; the daemon socket is forwarded. | QUIC/WebTransport, PAM logins |
| Tailscale | Suggest Tailscale Peers probes peers over SSH and lists those running Harness, socket filled in. | Each server joins as a tsnet node |
| Several remote hosts at once | Not yet: the window shows one daemon at a time; the sidebar lists the others' sessions. | Yes |
| Paste into a remote pane | Images and files upload to that host first. | Bidirectional clipboard protocol (stated) |

## Not planned

- **An SSH replacement** (PAM logins, `who`, identity mapping): Harness rides SSH on purpose.
- **QUIC/WebTransport, web and iOS clients.**
- **Floating layers and non-terminal blocks.**
- **A Linux fd-table trampoline** for daemon upgrades.

## Benchmarks

Harness doesn't publish head-to-head numbers yet. `Scripts/scorecard.sh` measures cold start, throughput, idle power, and memory on your own machine; see [SCORECARD.md](SCORECARD.md).
