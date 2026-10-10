# Preview panes and remote connections

Use **Open Preview…** in the command palette to create a page beside the selected
pane. The existing shell keeps its process, environment and input stream. Preview
panes use the same split layout, focus, drag, zoom, close, Overview and Saved Setups
as terminals. Their URL is on the pane's recorded host. Changing a preview's address
updates that preview; it never turns a live terminal into a page.

The CLI/API equivalent is:

```sh
harness-cli api call pane.preview --args '{"pane":"TARGET","url":"http://localhost:3000"}'
```

Pass `"update":true` only for an existing preview. `pane.view` includes typed
`content`; preview panes have no PTY, terminal size, process sample or input stream.
Terminal controls on a preview return an actionable error. Headless Linux hosts can
retain and edit the layout; the macOS application renders the page.

Preview URLs must be HTTP or HTTPS and explicitly loopback: localhost, canonical
127.x.x.x, or IPv6 loopback. Embedded credentials, file navigation and downloads are
refused. Every top-level navigation and redirect is checked. External navigation
presents a native **Open link in browser** button; scripts cannot automatically open
an external browser. There is no terminal JavaScript bridge. Each preview uses
[WebKit's nonpersistent website store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore),
so its cookies and website cache stay in memory for that view's lifetime. A local
page can still request external assets and frames. This is not an all-network sandbox.
Certificate, server and renderer failures stay visible with a Reload action.

A remote preview gets a private SSH forward bound to 127.0.0.1 on this Mac. Harness
allocates a port, checks that the owned SSH process actually owns its listener, and
preserves the logical URL's path, query and fragment. Port collisions cannot cause
adoption of another application's server. Closing the preview or disconnecting its
host stops the scoped forward. Stale view callbacks cannot stop a newer view's
forward. Connection work is bounded and rejects requests when busy. HTTPS still
validates certificates normally; hard-coded absolute remote loopback URLs are not
rewritten, and may need adjustment in the development server.

On wake and usable network changes, the application probes attached hosts before
reconnecting. Concurrent connection attempts share one host operation. Jittered
backoff is bounded, progress is visible, and manual disconnect invalidates queued
attempts. A failed daemon health probe retains a live SSH process and its binding;
it cannot authorize killing or replacing a potentially healthy transport. An
unresponsive binding owned by another process is reported for explicit recovery.
Terminal attachment resumes within the retained stream epoch/window or explicitly
resynchronizes the screen and replay. Uncertain terminal input is never retried.

Pasted images and files use the existing authenticated daemon upload path. The
remote directory is owner-only; new files use exclusive creation, no-follow checks,
complete writes and owner-only permissions. Only a successfully uploaded, quoted
remote path is inserted, without Enter. Failed uploads return an error, and old
Harness-created files expire after a day. These files must be readable by the agent
and are private plaintext files, not encrypted terminal-history records.

Clients explicitly negotiate `pane-content-v1` for layout-bearing responses.
Legacy reads receive a terminal-shaped projection labelled as unavailable; their
ensure/input calls cannot create a hidden shell for the actual preview. Capturing,
opening or overwriting a typed Saved Setup without that capability is refused.
Unknown future content is retained as semantic JSON and shown as unsupported,
never replaced with a terminal. Legacy on-disk leaves decode as terminals.

The native macOS walkthrough verifies actual split hosting, focus and restored
layout, plus a task-owned SSH host with a pinned key, loopback forwarding and
authenticated private image paste without submission. See [native acceptance](NATIVE-ACCEPTANCE.md).

A remote host can explicitly select an existing trusted SSH configuration file with `--ssh-arg -F --ssh-arg /absolute/path/to/config`. SSH reads that file normally, including its host-key and identity settings; Harness does not weaken host-key checks or modify the user's SSH configuration. This is useful for isolated development hosts and separate profiles. Tunnel diagnostics are drained for the process lifetime and kept only as a 64 KiB memory tail, with classified errors shown to the user.
