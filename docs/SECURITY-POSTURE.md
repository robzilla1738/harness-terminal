# Security posture

The honest ledger of Harness's security-relevant decisions: what is enforced, what is
deliberately not, and why. Sibling to [TMUX_PARITY.md](TMUX_PARITY.md)'s invariants section —
if behavior differs from what this file says, that's a bug in one of them.

## App sandbox: OFF, deliberately

`Harness.entitlements` sets `com.apple.security.app-sandbox` to `false`. This is not an
oversight:

- A terminal's entire job is arbitrary process execution with the user's full ambient
  authority (`forkpty` + the user's shell). Sandboxing the host while the child shells run
  unsandboxed would be theater; sandboxing the children would break the product.
- The daemon architecture makes it structurally impossible anyway: `HarnessDaemon` is a
  launchd-supervised background process that spawns PTYs and owns a Unix control socket —
  none of which fits the sandbox's container model.
- Every mainstream terminal (Terminal.app aside, which ships with private entitlements)
  makes the same call: Ghostty, iTerm2, kitty, Alacritty, WezTerm are unsandboxed.

What we do instead: keep the *attack surface into* Harness small and authenticated (socket
posture below), never execute content we receive (OSC handling is parse-only; paste
protection and bracketed-paste-injection stripping are on by default), and validate
config/IPC inputs loudly.

## Code signing, hardened runtime, notarization

`Scripts/sign-and-notarize.sh` signs every nested Sparkle component (XPC services,
Autoupdate, the framework) and the app itself with `--options runtime --timestamp`
(hardened runtime on everything), verifies with `codesign --verify --deep --strict`, then
notarizes and staples. Library validation comes with the hardened runtime; no exception
entitlements (`disable-library-validation`, `allow-unsigned-executable-memory`, JIT) are
requested — the entitlements file contains exactly one key (the sandbox opt-out).

## Update path (Sparkle)

- Appcast over HTTPS only: `SUFeedURL = https://harnesscli.dev/appcast.xml` (ATS applies;
  no exception domains are declared).
- Updates are EdDSA-signed: `SUPublicEDKey` is baked into Info.plist; the private key
  lives only in the release machine's keychain. Sparkle rejects any download whose
  signature doesn't verify, independent of TLS.
- Sparkle is pinned `upToNextMinor` from an audited release in all three manifests
  (Package.swift / project.yml / project.pbxproj, kept in agreement by the CI
  `manifest-lint` job), so a fresh resolve can't float onto an unaudited major/minor.
- The daemon and CLI are not Sparkle-updated: the app refreshes the installed `bin/`
  copies from its own (signed, notarized) bundle, only when bytes differ
  (`BinaryRefresher`).

## Control socket (verified healthy)

- Created under `umask(0o177)` so it never exists with permissions broader than `0o600`,
  even momentarily; permissions are re-asserted after bind as a second layer.
- Every `accept()` verifies the peer euid via `getpeereid` against the owning UID — a
  same-host different-user process cannot drive the daemon even if it could reach the
  socket file. The Harness home directory tree is `0o700`.
- IPC frames are length-prefixed and bounded (16 MiB max payload); oversized or unframeable
  input drops the connection; per-connection partial-frame and write-backlog caps bound
  memory. Hook/pipe-pane failures never log the command line (secret hygiene).

## Services surface

`NSServices` declares two Finder context-menu items ("New Harness Tab/Window Here") that
*receive* a file path and open a terminal there — input-only (`NSSendTypes`: filenames /
plain text), no data is returned to other apps, and the path flows into the existing
new-tab cwd plumbing (which validates and shell-quotes where applicable). The URL scheme
and document types (`.command`/`.tool`, ssh/telnet) route through the same
`DefaultTerminalLaunchRequest` validation as user-initiated opens.

## Scrollback at rest (`persist-scrollback`)

Scrollback is raw PTY output, persisted per surface (owner-only `0600` files, under the
`0o700` Harness home) so history survives daemon restarts. Raw PTY output can contain
echoed secrets — that's inherent to what a terminal sees, and Harness **will not redact**
(any redaction heuristic is a false promise; the honest control is whether bytes reach
disk at all).

The control: `persist-scrollback` (default **on**), readable per pane with global
fallback. It is pane- or global-scoped only; a tab/session/workspace-scoped set is
rejected loudly (no read path could ever reach it — accepting it would be a silent no-op
on a security control).

```sh
harness-cli set-option -p -T <surface-id> persist-scrollback off   # one pane
harness-cli set-option -p persist-scrollback off                   # the calling pane
harness-cli set-option persist-scrollback off                      # everything (global)
```

Semantics (pinned by `ScrollbackPersistenceTests`):
- Turning it **off wipes the surface's on-disk log synchronously** — the intent is "no
  scrollback at rest", not "no new writes". Output produced while off never reaches disk.
- The in-memory replay ring is unaffected (the option is about bytes at rest; RAM history
  is the terminal working as designed).
- Turning it back on resumes persistence from that point for every live surface —
  including one *spawned* while the option was off (it carries a suspended log writer),
  and across a live `respawn-pane`. Output produced during the off window stays
  memory-only.
- At spawn, a surface whose resolved option is off also removes any log a
  previously-persisted run left behind.
- Copy-mode copies are independent of this option: an explicit copy persists to
  `buffers.json` (user-initiated, by design) regardless of `persist-scrollback`.

## IME audit (deferred, tracked)

The systematic IME-depth pass (dead keys, CJK candidate commit timing, wide marked-text
width math) is deferred until the surface-view decomposition lands (`+IME` extension file,
roadmap PR-30) so the fixes have a clean home; tracked in `docs/V1_10_ROADMAP.md` PR-36.
