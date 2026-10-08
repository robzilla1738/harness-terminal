# Workspace workflows

These workflows use the same daemon-owned sessions as the terminal and CLI. The macOS app presents them; each attached host retains its own layouts, processes, and saved setups. iOS remains a separate follow-up.

## Activity

Open **Session → Activity…** or the sidebar's Activity button. The bell opens the same view filtered to items needing attention. Each row identifies its host, session, tab, and source pane. Linked views of a surface produce one activity entry.

Program reports and hook notifications can say that input is required. Process detection is labeled as inferred activity; an idle process is not asserted to be an approval prompt. Selecting a row or clicking its system notification opens its exact pane. Closed or disconnected targets report their state rather than opening a different pane.

Right-click a row to mark it read, snooze notifications for 15 minutes or one hour, or resume notifications. Read state does not resolve a blocked process or reset its activity timestamp. Repeated alerts of the same kind are suppressed for 15 seconds; a change to a different event kind can still notify. Notification-event, sound, and system-banner preferences remain respected.

**Settings → Agents** offers Install, Update, or Reinstall Hooks. The button's tooltip reports whether managed hook configuration is current, missing, or unreadable. Existing user configuration remains preserved by the installer.

## Saved Setups

Open **Session → Saved Setups…**, select a host, and choose **Save Current Session**. A setup stores tab names, split orientation and ratios, directories, and shell paths. Capture does not copy running command arguments or agent conversations.

The editor allows optional startup commands, explicitly entered per pane. **Open** returns to the most recently selected running session created from that setup. **Open New Copy** creates a new session. Startup commands run only for a newly created setup session, never on reconnect or when returning to a running one.

Edit, duplicate, import, and export JSON definitions in the library. Import opens the editor and never executes commands. **Update from Current** previews a replacement recipe from the host's current session; startup commands must be entered again. Definitions are per-host and use absolute paths on that host. Deleting a definition leaves running sessions intact.

Directories and shell executables are checked before launch. If a later shell spawn fails, the partial layout remains available, no startup commands run, and the error explains how to repair it without opening another copy. Limits: 200 definitions, 32 tabs and 64 panes per definition, split nesting of 16.

## Recently Closed

**Session → Recently Closed…** keeps the latest 20 closed panes, tabs, or sessions on each host. Closing a workspace records its sessions. Disconnecting or quitting does not add entries.

Restore creates fresh shells from layout metadata. It does not resume a closed process, restore an agent conversation, or execute startup commands. A pane restores as a new tab in its original session when that session still exists. If the original session is gone, restoration creates a session. Successfully or partially restored entries are consumed so retries cannot duplicate live panes. Entries can be deleted or cleared.

## Output and file search

**Session → Search All Sessions…** searches retained terminal output in open sessions across all attached hosts, the source host, or the source session. Search is literal, with optional case matching. Results arrive in pages of 100 per host, and partial host errors remain visible. No archive of closed terminal output is created.

Opening a result checks the daemon incarnation, snapshot revision, exact pane identity, and captured line fingerprint, then validates the displayed buffer before highlighting. Output that moved or expired requests a fresh search. Searches run on bounded background workers and can be cancelled as the query changes or the window closes.

**Insert Path** and **Go to Directory** in the palette use a fuzzy picker on the source pane's host. Current Folder lists files and directories; Project Files uses Git's tracked and untracked, non-ignored paths. Outside Git, traversal is bounded and skips hidden folders, packages, symlinks, `node_modules`, `vendor`, and `build`; it will not recursively scan the home directory or filesystem root. Up to 200 matches are shown; narrow the query to find more.

Insert Path supports multiple selected paths, shell-quotes them, and adds no Return. Paths containing control characters are rejected for insertion and `cd`. Go to Directory explicitly sends `cd`; Command-Return opens a tab in the source session. Switching the active pane while the picker is open does not change its destination.

## Remote connections and migration

A dropped SSH tunnel leaves the last terminal output visible with a reconnect notice. Automatic retries reattach to surviving processes. **Remote → [host] → Retry Connection** retries manually; **Connection Details** shows status and daemon capabilities with copyable diagnostics that exclude credentials and terminal output. Quitting the app differs from terminating its daemon: only surviving processes can be reattached. Sleeping a local machine pauses its local processes.

Older daemons report that newer workflows require an update. The new workflows do not require an account or a separate transport.

**Harness → Import Terminal Settings…** previews supported configuration differences and skipped keys. Customized values and shortcut imports start unchecked. Supported declarative Command-key bindings map to new tab/window, split right/down, and pane zoom; executable or unsupported bindings are listed as skipped. Existing prefix, root bindings, and vi/Emacs copy-mode controls remain available.

**Undo Last Settings Import** reverts only imported values that still match their imported value, preserving later edits. Font size remains Harness-owned. Sidebar filtering now matches host names as well as session names, tab titles, and directories.

## Automation

Use `harness-cli api describe <method>` for exact arguments. The same calls can target a registered host using `--host`.

```sh
harness-cli api call attention.list --args '{}'
harness-cli api call setup.capture --args '{"name":"Project"}'
harness-cli api call setup.list --args '{}'
harness-cli api call setup.open --args '{"id":"SETUP_UUID","mode":"existing"}'
harness-cli api call output.search --args '{"query":"error","case_sensitive":false}'
harness-cli api call pane.search_paths --args '{"query":"readme","project":true}'
```

Also available: `attention.read`, `attention.snooze`, `setup.save`, `setup.delete`, `closed.restore`, and `closed.delete`. Library changes share the daemon's atomic snapshot persistence. There is no second client-owned layout store.

## Appearance and local preview

**Settings → Appearance → Panes** controls comfortable-mode spacing from 0 to 24 points, with an 8-point default. Outer and between-pane gutters match; the horizontal tab row stays vertically centered as spacing changes. Compact panes remain flush. Sidebar tabs share the horizontal tabs’ height and selected styling. Right-click empty sidebar or tab-bar space for workspace options; tab menus offer tab-specific actions.

`Scripts/preview.sh` builds and launches a development app. `HARNESS_PREVIEW_HOME` selects an isolated data directory and `HARNESS_PREVIEW_BUNDLE_ID` selects its application identity. Use both to keep a feature preview separate from an existing preview. Relaunching the GUI preserves the preview daemon and its sessions; daemon-code changes require a deliberate restart of that preview daemon to take effect.
