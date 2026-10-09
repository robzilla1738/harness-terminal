# Harness mobile companion bridge

Harness Remote connects over a normal, host-key-verified SSH **exec channel without a PTY**:

```sh
/absolute/path/to/harness-cli mobile-bridge --stdio --protocol 1
```

The bridge connects to the existing local Harness daemon. It never restarts a daemon or
creates a login shell. A daemon without `mobile-companion-v1` returns `updateRequired`.
Use one control channel for RPC and state subscriptions, and a separate channel for each
visible terminal pane. The shared Foundation-only `HarnessRemoteProtocol` package is the
authoritative wire model and codec.

## Framing and limits

Frames have a four-byte big-endian length followed by a one-byte tag. Tag 0 is a JSON
`RemoteMessage`; tag 1 is binary output; tag 2 is binary input. Binary frames contain a
two-byte UTF-8 surface-ID length, the ID, and raw data; output additionally includes an
eight-byte big-endian sequence before the data. Sequence numbers count terminal bytes.
The maximum frame is 12 MiB. Uploads are capped at 8 MiB, input at 1 MiB per message,
and a terminal grid at 1,048,576 cells. Control messages contain no shell interpolation.

The first message is `hello`, with protocol range, actual daemon epoch/version and
capabilities. Unsupported methods return correlated structured failures. A disconnect
during input is delivery-uncertain: clients must never replay that input automatically.

## Control and terminal state

`snapshot.get` returns all workspace/session/tab/pane addresses and layout metadata;
`attention.get` returns the activity rows. `snapshot.watch` subscribes to changes and
pushes initial snapshot, attention and resolved appearance. Appearance contains the
host's complete palette and overrides, and updates when configuration changes.

Workspace mutations use explicit UUIDs. The companion aliases include `workspace.newSession`,
`workspace.newTab`, `workspace.renameSession`, `workspace.closeSession`,
`workspace.moveSession`, `workspace.pinSession`, `workspace.renameTab`, `workspace.closeTab`,
and `workspace.moveTab`. Existing public control API methods are also available with an
empty contextual environment, so omission cannot select the desktop's active pane.

Attach requires the complete current `PaneAddress`. A cold attach or failed epoch/sequence
resume returns a checkpoint and its exact end sequence. Checkpoint data is a binary
property list encoding the versioned engine `TerminalCheckpoint` wrapper. Both screens,
parser continuation, modes, links and supported images are preserved; invalid or oversized
checkpoints fail explicitly. Subsequent raw output begins at that same boundary. A valid
resume sends retained byte deltas without restoring a second checkpoint.

Read-only subscribers cannot input or resize. Control subscribers retain their daemon
client ID, sizing and terminal-query-responder state. A `resize` with `takeOwnership`
explicitly claims sizing; ordinary resizes do not repeatedly steal it from another client.
Switching between Watch and Control uses a fresh attach.

`pane.history` accepts a pane or surface UUID plus optional token, before-row and count.
It returns immutable styled rows with wrap, cluster, width, color, attributes and hyperlink
data. Pages contain at most 256 rows, tokens are pane/epoch-bound and expire after 60
seconds, and retained history is independently bounded. History is separate from live
engine state and cannot execute terminal side effects.

`output.openMatch` accepts the original `output.search` match object plus its epoch and
revision. It validates exact topology and the logical-line fingerprint against the same
immutable styled snapshot used to return the centered history page. `targetRow` names the
match's absolute row in that snapshot. Rolled output, closed/moved panes or a restarted
daemon require a fresh search. Unsigned 64-bit fingerprints remain lossless on the wire.

## Pairing and files

The Mac menu/command-palette action **Connect Phone or iPad**, or `/remote` in the Harness command prompt, displays a QR code and copyable connection link. The window discovers local addresses, offers a network selector, and checks the local SSH port. Shell and headless hosts can use:

```sh
harness-cli pair
harness-cli pair --host reachable-hostname --port 22
harness-cli pair --link
harness-cli pair --json
```

`remote pair` and `/remote` are CLI aliases; `remote list/add/remove` are unchanged. `mobile-setup --json` retains the existing metadata interface.

The app scans a versioned `harness://connect` link, reviews the host, and asks for the account password once to install and verify a device key. Existing saved credentials are reused for the same address/port/account. The shared `RemotePairingInfo` parser also accepts legacy JSON and rejects unsupported versions, duplicate URI fields, invalid fingerprints and oversized data.

Metadata contains address, user, the SSH Ed25519 host-key fingerprint and absolute bridge executable path; it contains no credentials and grants no access by itself. Enable SSH first and use a reachable LAN or an existing Tailscale connection. The helper reads `/etc/ssh/ssh_host_ed25519_key.pub`; nonstandard servers must present that key or use manual setup with their verified identity. No SSH configuration or router ports are changed. The portable shell QR encoder is pinned and attributed in `Packages/CHarnessQR/README.md`.

`device.installKey` validates a plain Ed25519 public key and atomically installs one managed
authorized-keys line. `device.removeKey` removes only that exact managed line and returns
`removed`; unrelated/manual lines are preserved. `file.upload` accepts a filename and
base64 data and returns the host's temporary-file path.

## Focused integration check

```sh
python3 Scripts/mobile-bridge-smoke.py
```

This starts a real daemon and bridge in an isolated temporary `HARNESS_HOME`, checks the
hello, snapshot, appearance, checkpoint, binary input/output, history and resume, and cleans
up. It does not touch existing sessions or SSH keys. This check passed on macOS and
Swift 6.2.4 aarch64 Linux during companion implementation. Physical iOS SSH/pairing
acceptance remains a separate release check; bridge pipe validation does not establish
device networking, typing or battery performance.
