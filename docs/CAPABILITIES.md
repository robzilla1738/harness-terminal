# Harness capabilities and limits

Harness is a native macOS terminal with persistent, daemon-owned sessions. Its CLI
and daemon also run on Linux. The terminal parser, screen model, multiplexer and
Metal renderer live in the Harness packages in this repository. See
[architecture and provenance](ARCHITECTURE-AND-PROVENANCE.md) for dependencies and
compatibility details.

## Sessions and panes

- Shell processes run in `HarnessDaemon`, independently of the macOS window.
  Closing a window can detach the client while its sessions keep running.
- Workspaces organize sessions, tabs and split panes. Prefix commands, the command
  palette and `harness-cli` operate on the same daemon model.
- Attach and reconnect restore the selected pane. Stream sequences and daemon
  epochs distinguish resumable output from a connection that needs a checkpoint.
- Clients can view separate scrollback positions. Sizing follows the configured
  owner or smallest-client policy.
- A machine reboot ends running processes. Restoration can recreate layout,
  retained history and shells; it does not resume the execution of an exited program.

See the [sessions and panes guide](MULTIPLEXER_GUIDE.md) and
[workspace workflows](WORKSPACE-WORKFLOWS.md).

## Terminal interaction

The native engine handles VT sequences, Unicode text, alternate screens, terminal
queries, hyperlinks and supported image and keyboard protocols. The macOS surface
adds selection, copy/paste, find, IME composition, touchpad scrolling and live resize.
Program status and agent detection feed pane titles, activity indicators and
notifications. Protocol support and limits are documented in
[program status](PROGRAM-STATUS.md), [keybindings](KEYBINDINGS.md) and
[the security posture](SECURITY-POSTURE.md).

Harness Graphite is the default theme. Original Harness palettes and community
palettes remain selectable; the latter have their own attribution and licenses.
Settings imports provide migration compatibility rather than an engine dependency.

## Remote and mobile

Remote desktop and CLI workflows use SSH. The native iPhone/iPad companion uses
SSH exec channels and the versioned companion protocol to address exact panes.
QR pairing carries public connection metadata, including the host fingerprint.
Tailscale can provide the network route; it does not replace SSH authentication.

The companion requires iOS/iPadOS 26 or later and a companion-ready host. Its source
is available in [harness-ios](https://github.com/robzilla1738/harness-ios); it is not
currently distributed through the App Store. Background monitoring and push
notifications are not promised. See [mobile setup](MOBILE-BRIDGE.md).

## Distribution and measured limits

The downloadable macOS app is signed and notarized. Linux CLI/daemon and iOS
companion builds are available from source. Read [the release runbook](RELEASE.md)
for toolchain, publication and validation requirements.

Performance claims are scoped to the measured workload, hardware and revision.
[SCORECARD.md](SCORECARD.md) retains methods and named reference measurements;
it does not establish universal performance leadership. Release acceptance gaps
remain tracked in [issue #187](https://github.com/robzilla1738/harness-terminal/issues/187).
