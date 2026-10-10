# UI cohesion work

Goal: bring every new tool and configuration surface into the existing terminal /
Settings design. Preserve behavior, privacy decisions, keyboard access, and theme
support. No release or production-session restart. Verification is focused builds
and native visual inspection, not a new test suite.

## Shared treatment

`HarnessToolPage` uses the existing chrome palette, a consistent header,
top-aligned scrollable content, readable tables and text editors, and themed section
cards. `ToolSectionView` supports disclosure for technical detail. This is shared
application UI, not a diagnostic overlay.

## Screen audit

All new root tool surfaces have received native visual inspection. Conditional
dialogs use the same reviewed controls and modal layout; any unexercised
data-dependent states are identified below rather than implied to be tested.

| Surface | State |
|---|---|
| Fan-out | Main task form and populated task/agent tables inspected. Provider and explicit-test dialogs have persistent labels; final native check confirms labels, fixed actions, cancellation and disabled pagination |
| Managed Worktrees | Main populated window and pill actions inspected. Persistent input labels and selection/pagination gating verified in the final populated native view |
| Schedules and definition editor | Main window, selected-action gating, new form and advanced definition editor inspected. One-shot/cron input availability verified; no schedule saved or enabled in this pass |
| AI Summaries and provider/model/consent dialogs | Main window and provider picker/consent inspected; shared themed modal and visible button sizing verified; empty-catalog/manual model entry inspected, preserving the current model; provider and request action availability verified |
| Notification Policy and destination dialogs | Main window and add-destination form inspected; labels, selectors, secure fields, toggles and modal buttons fit. Empty diagnostics presentation and disabled Edit/Remove without a selection verified |
| Power Settings | Grouped controls, Harness override selector and primary action inspected; disabled-toggle tint corrected and built |
| Activity Profiles and profile editor | Main window and editor inspected; matching controls and visible roots/pricing editors verified. Final empty-state copy and selected-action gating inspected |
| History and Privacy | Capture card, distinct recovery action, readable default size; native encrypted-history state inspected |
| Hook Policy and rule editor | Main empty state and disabled-fixture review inspected. Empty selector has clear copy, unavailable actions are disabled, long review text fits with fixed Cancel/Trust actions. No policy trusted or hook installed |
| tmux Import | Main window, socket dialog and loaded fixture inspected. Readable nested layout outline replaces raw JSON, with directories and separate unchecked startup suggestions; no setup saved |
| Recordings / redaction / export | Main and loaded synthetic recording inspected, including candidates, redaction field, export preview and bottom actions. Single-line context whitespace corrected and built |
| Plugin trust dialogs | Synthetic plugin review inspected; readable source, fixed actions and safe Cancel default verified. No trust granted |
| Remote Host setup | Native sheet inspected: matching fields, labels, disabled actions and Cancel verified; no connection made |
| Mobile pairing / trust | Shared header, connection card, themed fields/buttons; native unavailable state inspected, empty QR space removed; native recheck confirms no empty QR gap and named buttons |
| Saved Setups / Recently Closed / editor | Native library, empty states and setup editor inspected; full-width name, left-aligned actions, visible Save/Cancel and themed controls verified |
| Board / digest / timeline / resources / resume | Main Board, digest, resources and unavailable restore/timeline states inspected. Shared Overview/Board switch inspected. Resume/explain selectors and modal call sites reviewed against the shared components; configured-agent dialogs were not exercised with a live provider during this styling pass |
| Embedded preview and address flow | Native address dialog, toolbar, embedded local page, loading and connection-error presentation verified using a disposable loopback server; server stopped afterward |
| Settings import / iTerm colors | iTerm variant and install preview inspected with actual color swatches and visible actions; canceled without applying. Settings change-selection review inspected with one disposable padding change; review sizes to its contents, was canceled, and original settings were restored |
| New palette actions and Settings entry points | Settings → Tools now exposes 21 grouped entry points; native page, searchable discovery, and AI-summary opening verified. Overview opens correctly from its Settings button using the originating window |
| Existing Settings, main window, overview, search, onboarding, shortcuts and About | Settings/main and Overview inspected. Search All Sessions shared controls and a real result verified; About and shortcut source reviewed as existing reference surfaces; first-run onboarding was not replayed during this tool-screen pass |

## Verification

Affected Harness builds and the signed private preview build passed. `git diff --check`
passed. Native inspection uses `/tmp/hnative-reaping-proof/HarnessPreview.app` and
existing harmless fixtures. No full suite, release, production restart, external
summary submission, hook/plugin trust, or automatic workload was added by this pass.

Shared controls use a 30-point form metric, readable padding, persistent labels,
neutral focus treatment, accessible names and enabled/disabled states. Passwords
retain native secure editing. Tool dialogs keep actions visible below scrolling
content and preserve their original response semantics. Native file pickers and
specialized date controls retain macOS behavior.

The UI consistency pass is complete. This is focused visual and source evidence,
not a claim that every possible data-dependent dialog or backend workflow was
exercised. No new cosmetic tests were added.

Long review dialogs now size to their explanation as well as accessories, bounded by the screen; native disabled-policy review confirms complete readable content and fixed actions. Fan-out and schedules disable selection-dependent actions and unavailable pagination. The latest app build passed. Settings Overview uses an idempotent present action and the originating Settings window; both keyboard Overview/Board navigation and the Settings button are verified.

## First-launch appearance

Fresh installs open with Harness Graphite, 85% window opacity, 60 pt blur, and
25% border opacity, with the bottom status strip hidden. Window material settings are shared across themes; changing
colors does not reset these controls. Saved choices remain unchanged. Another
terminal's configuration is available through explicit Settings import rather
than overriding the first-launch appearance automatically.

## CLI sizing after attach and disconnect

The session host now removes every resize vote when its connection closes, including
control connections that never subscribed to terminal output. Explicit detach and
socket closure both apply the size selected from the remaining clients and update
ownership. Previously, an abandoned small vote could keep a CLI drawing for a smaller
PTY even though its pane had grown. The GUI retains pre-attachment geometry locally
and submits it on its persistent stream instead of opening a temporary resize client.

Verified with `python3 Scripts/check-session-host-geometry.py --bin-dir .build/debug`:
the disposable-host case failed before the fix (stuck at 80×24 instead of 120×40),
and passed afterward for non-stream disconnect, stream detach, stream disconnect,
and subsequent growth. Harness and HarnessSessionHost builds passed. Running user
session hosts were not restarted; the owner-side fix takes effect when a new host
starts after its existing shells close, or in a fresh isolated preview.

## Tab Peek and CLI startup output

Tab Peek is now one compact child panel attached inside the terminal window's
trailing edge. Its height follows the tabs, with scrolling when needed; opening
it never changes the terminal grid. It uses Harness chrome, neutral selection,
short fade/slide transitions with Reduce Motion support, clickable accessible
previews, arrow-key selection, Return, Escape, and a Close button. Selection follows
tab identity through updates. Outside clicks, parent closure/minimization, and app
deactivation dismiss it. Trackpad momentum cannot cycle through multiple views.
The old intermediate peek/centered-overview cycle was removed; Workspace Overview
remains a separate command.

The signed isolated preview was visually inspected with multiple live tabs.
Focused selection-identity, erase-display, and alternate-screen checks passed.
The user was actively operating that preview during inspection, so additional
keyboard/click walkthrough actions were not forced over their interaction.

For Devin CLI 3000.11.3, a disposable PTY probe (no prompt submitted) observed zero
full-screen clears and zero alternate-screen entries during startup, then two
full-screen clears after a size change. The shell prompt and startup warning in
the supplied screenshot are consistent with inline CLI output. Harness must honor
the program's clear-screen requests rather than silently erase previous output
when it detects an agent. A clean takeover at startup requires the CLI to clear
its display or enter the alternate screen; the terminal's existing erase and
alternate-screen checks pass without a window resize.

The main tab row is 46 pt high: 30 pt tabs with 8 pt above and below, matching
the default outer pane gap. Native window buttons and sidebar/title controls share
its 23 pt center; AppKit titlebar updates reapply that alignment. Full-screen
revealable controls retain system placement. The existing tab-spacing check passed,
and the signed reopened preview visually confirms the gaps and control alignment.
