# Native development acceptance

All observations use disposable Harness preview homes and task-owned Linux VMs. The installed production daemon and its programs remain untouched. The full suite already ran once; these checks use native interactions and affected builds or focused rechecks.

| Flow | Observed evidence |
|---|---|
| First run | Persistent sessions default; optional notification/hook/CLI setup; isolated preview does not modify regular installation or shell profiles; welcome describes the session host accurately. |
| Board | Local and remote rows, preview resource values marked not applicable, unknown usage, filter and keyboard selection/jump, preview peek, snooze, actual process sampling interval and destructive-action confirmation. History availability no longer marks fresh observations stale. |
| Local and remote preview | Real split-pane hosting, preserved URL query/fragment, input focus, non-loopback rejection, restored layout after GUI rebuild, authenticated SSH forward to a remote HTTP server. |
| Remote image paste | Native image clipboard paste creates a valid private PNG on the remote host (0600), inserts a path without Enter, and does not execute it. |
| Recording review | Synthetic timed/resized TUI recording, default candidate masking, added literal masking, unsafe OSC removal, saved asciicast with recorded dimensions, native share chooser reached without sharing. |
| tmux import | Nested stable pane/window IDs previewed; startup suggestions remain unchecked; Saved Setup saved; surface count unchanged and no PTYs acquired. |
| Notifications | External sinks and speech off; explicit content consent; invalid quiet-hour timezone refused; unsigned preview reports macOS UNErrorDomain code 1 rather than silently failing. The provisioned Developer ID preview reports permission Allowed and macOS accepts its local test notification; actual banner visibility remains subject to Focus/system settings. No external sink was invoked. |
| Power | AC on/battery off defaults; explicit On acquired the actual daemon IOPM assertion; returning to Auto released it. Physical battery restriction passes even with override On; switching to AC activates the assertion. The user performed a physical sleep/wake; the daemon observed a 2.06-second interval and resumed its AC assertion. Host, daemon, shell and background fixture retained their PIDs with continuous ordered fixture records. The brief transition produced no measurable gap in the one-second sampler; no claim of continued execution during sleep is made. Auto then released the assertion. |
| AI and schedules | Named cloud/local presets, exact destination/model/content review, external categories off by default, schedule starts disabled, unavailable protected history shown. The signed preview saves and inspects a disabled one-shot definition with exact arguments/directory/profile and America/Chicago timezone; the API confirms no occurrences and no execution. No provider requests or external notifications were sent. |
| Hook policy | Explicit local trust, declarative review/install/audit controls and truthful provider-specific enforcement support. Existing real helper IPC fixture covers native responses and failure behavior. |
| Privacy | Host/pane capture control in palette and Terminal settings, effective inherited policy, unavailable-key status, recovery refusal, precise removal confirmation and cancel preserving capture. Provisioned app/host/daemon/CLI share the exact history access group. Real private-home Keychain invalid-data fixture reports unavailable, captures in bounded memory without persisted text, and recovers through the native UI after only its disposable key is repaired. Same shell/host/daemon PIDs and recovered fixture output; encrypted scrollback/checkpoints contain no fixture plaintext. |
| Signed helper installation | Disposable-home CLI install retains all three helper profiles and valid signatures. Installed CLI with explicit `HARNESS_HOME` accesses the shared Keychain. After atomic app-bundle replacement, real recovery still succeeds with the same shell/host/daemon/background-job identities, using running-task entitlements; global service and shell profiles remain untouched. After the old executable vnode is removed, restart controls verify the real socket peer and process birth: `--if-empty` preserves live shells and an explicit private-fixture stop succeeds. |
| Fan-out and digest | Signed private host launches two harmless fixture providers at the same committed base; an explicit fast test is actually reaped with exit 0, the digest counts one passed test, and cleanup retains both worktrees with their untracked files and clear per-participant reasons. Native Fan-out Inspect/Compare shows the exact process/test outcomes, pinned base, untracked files and cleanup recovery reasons; Board Digest shows exactly one passed explicit test. No AI provider is contacted. |
| Exact resume | Synthetic provider conversation and recorded directory/profile prepare an exact resume command; native Insert leaves it unsubmitted in the verified fresh shell. Used-shell refusal remains explicit. |
| Regex search | Actual matches in current host memory, explicit execution filters, invalid-pattern failure, exact-pane jump. Recorded-span remount and actual presented-frame shading checks pass; native screenshot confirms the exact matched text is visibly highlighted after jumping. |

The walkthrough identified and corrected missing horizontal Board scrolling, conflation of history warnings with stale hosts, preview-toolbar contrast, notification-test failure reporting, remote connection failure presentation and stale palette menu actions. Offline hosts now use empty snapshots rather than fabricated default shells; a typed host-status row provides the recovery message and disables pane actions. The final native recheck confirms typed offline rows, recovery messages and disabled pane actions.

The user-authorized Xcode provisioning operation completed for all four Harness macOS component IDs using the configured Apple Developer team and existing Developer ID identity. Each helper now carries its own profile-capable bundle, with only the exact shared history group in its signed entitlements. No builds were published. Configured billable summary smoke checks remain conditional on supplied credentials.

Signed previews now scope window state, palette recents and applied-mode markers to
their explicit Harness home. The regular installation retains its existing keys.
Persistence-mode markers and displayed values change only after an accepted daemon
response. The affected app builds and signs successfully. The preview launcher uses
the POSIX expression syntax accepted by macOS process tools; an actual rebuild
retires all old GUI instances and leaves one preview, while host 40747 and daemon
40750 continue owning the same two shells. The final `--if-empty` check refuses to
interrupt those shells after the bundle exchange.

The final signed macOS lifecycle/MCP proof also passes after socket descriptors were
retained through all Dispatch cancellation handlers. Both final Linux archives pass
their corresponding runtime/install/lifecycle/MCP proof without Swift. The x86_64
run uses a full Linux kernel VM, with all declared library versions verified; the
disposable VMs are retired after their checks. The [implementation record](DEVELOPMENT-IMPLEMENTATION.md)
contains the completed coverage table and exact archive identities.
