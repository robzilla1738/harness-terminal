# Session-service updates

An app or CLI build change reports an available update. It does not authorize
stopping a shell. Launch, onboarding, installation, service configuration changes,
and development starts preserve an existing owner even when it fails a health probe.
Protocol compatibility and explicitly advertised capabilities determine which
operations a client can use. Unknown protocols require recovery; they are not
assumed compatible because their build number is newer.

Executables are copied to verified temporary files in the destination directory,
flushed, and atomically renamed. Running processes retain their original executable
inode. Service changes are staged beside the definition with a `.pending` extension
while an owner is alive or uncertain. Ordinary installation stages changed service
definitions even if the service is stopped. Guarded restart applies them after the
owner exits. Isolated homes never alter the user's managed service. Startup takes
an exclusive home lock before reading stores,
writing its PID, or creating shells; a competing start exits without those effects.

The app menu provides **Replace Application Daemon** and **Restart Session Host…**, with separate choices to restart
only an empty service or explicitly stop its shells and programs. A pending update
appears in that menu. Shells at prompts count as live, including their environment,
working directory and background jobs.

For local administration:

```sh
harness-cli daemon-replace
harness-cli daemon-restart --if-empty
harness-cli daemon-restart --force
harness-cli kill-server --if-empty
```

`--if-empty` is checked atomically by the daemon, alongside a shutdown gate that
prevents further shell creation. A legacy daemon without that capability requires
explicit `--force`. Noninteractive destructive shutdown requires `--force`; an
interactive invocation without flags describes the interruption and asks the user
to type `stop shells`. These commands reject remote targets.

A failed stop or health probe does not authorize a replacement or an additional
instance. Uncertain ownership is reported for recovery, rather than discarding a
socket or signaling an unverified process. A normal stop unlinks only its own socket
and removes only its own PID file.

## Process ownership and survival

New installations run `HarnessSessionHost` as the stable process owner. The existing
`HarnessDaemon` service entry execs that sibling before creating shells. The host
retains the public socket, PTY masters, child reapers, resize ordering, replay buffers,
and stream epoch. It also owns bounded output pipe consumers and prepared one-shot
workload stdin/actual-exit receipts. Application daemons use private sockets and a generation-scoped
mutation lease. The active daemon additionally holds a kernel file lock for mutation
ownership. Warm candidates hold no writer lock. Preparing handover drains accepted
work and flushes stores before releasing it; activation must acquire it before any
activity writes resume. The writer descriptor is close-on-exec, so programs cannot
inherit daemon authority. Each worker verifies its parent host's kernel process
identity before opening stores and exits without flushing stale state if that host
exits. A host restart cannot overlap an orphaned writer. The isolated survival proof
includes host loss followed by successful owner recovery; host failure itself does
not promise process survival.

They adopt the existing shells rather than creating replacements.

A replacement drains the current daemon, captures versioned parser/observation
state, warms the candidate, checks compatibility and bounded replay, switches its
lease, then retires the previous daemon. Validation failure retains the prior daemon;
activation failure restores its lease. Daemon crash recovery uses the last compatible
binary and retained checkpoint. Terminal streams remain in the host throughout.
Control requests may receive a retryable handover error; uncertain input is never
replayed automatically. Mutation retry identities use a bounded sequence window:
expired operations are rejected rather than executed again.

`daemon-stats` reports `sessionHostPID`, `sessionHostVersion`, `sessionHostBuild`,
`daemonPID`, `version`, `build`, and `daemonAvailable` separately. Private owner
protocol/capability changes are reported as pending host updates even when build
numbers match. An unavailable
application daemon does not become a misleading healthy build or an empty layout.
Updating the application daemon preserves shells. Updating the session host itself
waits for every shell, pipe consumer and retiring owned child/daemon to finish, or
requires an explicitly destructive restart. Terminal EOF does not prove process
exit. Explicit close drains the accepted output tail before ending attachments;
actual reaping remains independent. During a delayed shutdown, the host keeps its
exclusive ownership lock and health socket and reports `shutdownPending` and pending
retirement counts instead of allowing a competing owner. Prepared-input workloads
cannot receive terminal input or be respawned as another execution.

An already-running monolithic daemon remains the owner until its shells close or
an explicit forced restart interrupts them. Installation never forces a one-time
migration of those programs.

| Event | Live programs | Restorable state |
| --- | --- | --- |
| Close the app with Keep sessions running (default) | Remain in the session host, or the existing monolithic daemon | Reattach to the same shell and retained output |
| Replace application daemon | Remain in the session host, with the same PID and stream epoch | Parser, alternate screens, observation state and retained replay continue |
| Application daemon crash | Remain in the session host while control services recover | Last checkpoint plus retained replay; errors identify unavailable activity |
| Session-host crash or forced owner restart | Survival is not guaranteed; PTYs close and attached programs can be interrupted | Saved layout creates fresh shells; encrypted history depends on settings and key availability |
| Legacy monolithic daemon crash | Survival is not guaranteed | Saved layout and history can be restored into fresh shells |
| Logout | Survival is not guaranteed during user-session teardown | Saved state can be restored after login |
| Sleep | Programs normally remain, but execution pauses | Wake resumes execution and output; no claim of work during sleep |
| OS reboot | Programs end | Layout/history restoration does not restore live processes |

Run `python3 Scripts/prove-session-survival.py` after building for a disposable-home
proof. It checks an active shell, preserved environment, background job, refused
restart, competing/uncertain owner rejection, failed candidate adoption, successful
replacement with an attached terminal stream, daemon crash recovery, durable run
identity, and an empty owner restart. It never operates on the user's normal home.

## Conversation restore

The Board's **Resume…** reviews an exact supported provider conversation and inserts
its quoted command into an unchanged fresh shell without pressing Enter. The launcher,
recorded directory, supported profile selector and approved environment must still be
available. An old `argv0` alone supplies only informational “Was running” text.

**Restore behavior…** offers separate per-pane automatic execution consent. It is off
in older layouts and never copied into newly created Saved Setup panes. Enabling it
records the selected execution UUID. When that pane's layout is restored into a newly
created shell, Harness waits for a verified untouched shell-integration prompt and
submits the exact conversation command once. Input and Enter share one accepted write.
The host consumes that fresh-shell identity; daemon replacement/adoption cannot run it
again. A refused or uncertain submission is not retried. Missing executables, scripts,
directories, conversations or prompt support leave an actionable activity error and a
manual resume path. Restore work has four concurrent workers and 128 pending slots.

```sh
harness-cli resume-agent --run RUN_UUID --surface SURFACE_UUID --prepare
harness-cli resume-agent --run RUN_UUID --surface SURFACE_UUID
harness-cli resume-agent --run RUN_UUID --surface SURFACE_UUID --auto-restore on
harness-cli resume-agent --surface SURFACE_UUID --auto-restore off
```

The private worker protocol is version 5. A host/candidate mismatch refuses adoption
without interrupting its shells. Closed unavailable-key history remains bounded
memory; if encrypted activity cannot be restored after an OS restart, the recorded
execution is unavailable and automatic resume reports that fact.


## Ordered control and closed-history cleanup

Resize controls share the accepted input order. A large pending paste cannot be
silently overtaken by a resize or later input. Resize acknowledgment reflects the
OS operation and ordered replay record; failure or the one-second application
budget returns an actionable error. Failed size votes and ownership changes retain
the prior voting rules. A multi-pane mode change can report partial resizing, with
actual pane sizes available for inspection; it never claims an unsuccessful change
completed. No uncertain terminal input is automatically retried.

Natural exit and explicit pane closure drain pending PTY output and delivers accepted output frames before
notifying observers of exit. Hosted subscriptions close after bounded output drain;
closed-surface exit receipts have a 14-day/500-surface bound. Process generations
prevent a predecessor's delayed exit callback from closing a replacement shell.

The session host owns a structural closed-history catalog of surface IDs and close
times, separate from encrypted terminal text. Closed disk histories, resize journals
and checkpoints expire after 14 days or 500 closed surfaces. Active/restored layout
surfaces are protected. Existing orphaned history with no trustworthy close date
starts one conservative retention interval at migration. The daemon does not run
its legacy orphan deletion against host-owned histories. Unavailable-key closed
capture has a separate 32 MiB memory bound; eviction is reported. Corrupt or unreadable
retention/layout metadata cannot authorize file deletion and is shown as unavailable.
After repairing metadata, history recovery reloads retention while preserving active
surfaces and bounded memory capture. Files are not securely erased from SSDs.

The host also owns `pipe-pane` consumers. Their subscriptions and process identities
survive daemon replacement and crash recovery. Consuming commands start with default
signals in a separate process group. Bounded nonblocking tee admission cannot stall
terminal delivery; an overflow stops the affected tee and reports the failure in the
pane without printing the supplied command. Natural exit and pipe removal drain
accepted bytes before EOF, with a bounded grace period for stalled consumers. Empty
restart checks include active consumers and pending drains; health reports their count.
Legacy monolithic owners retain their own pipe path until their shells close.

For development replacement with `daemon-replace --binary`, supply a complete atomically staged executable, such as the preview or installed copy. A build system may modify its output inode while macOS retains signing state for it; direct mutable build outputs can fail to start even after a signature check. Failed startup retains the current daemon, and a fresh staged copy can be adopted without stopping shells. Never solve that failure by killing the session owner.

On macOS, deleting the exchanged old app bundle can make the running helper's executable path unavailable. That is not evidence of process death. Ownership checks fall back only to the exact Harness kernel process name and an authenticated local socket peer UID/PID with the same kernel birth identity. Administrative requests verify that identity again on their actual connection before writing. Explicit restart/stop controls continue working after bundle replacement; failed peer verification preserves programs. Shutdown waits for process death/birth change rather than disappearance of an executable path.
