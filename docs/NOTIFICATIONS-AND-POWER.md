# Notifications and power

The application daemon interprets provider transitions, explicit `notify` requests,
OSC 9/777 notifications, terminal bells, and observed OSC 133 command completion.
One policy controls desktop banners, chimes, optional speech, ntfy, Pushover, and a
Harness JSON webhook. External destinations and speech are off until configured.
Sleep and wake notifications are separately off by default.

Open **Settings → Notifications → Configure Delivery…** to review destinations,
content categories, quiet hours, coalescing and expiry. The Board can mute an exact
agent execution or snooze a pane. A pane restriction still applies after an execution
is unmuted. Quiet hours use an IANA timezone and follow its daylight-saving rules;
equal start and end times mean quiet all day. Suppressed notices expire rather than
appearing in a surprise backlog when quiet hours end.

ntfy sends its documented JSON topic payload. Pushover uses its fixed API endpoint
and form fields. A generic webhook sends `harness.notification.v1` JSON; a compatible
receiver must handle it. This does not imply Slack or Telegram compatibility.
Minimal state is the external default. Captured messages and repository paths each
require explicit inclusion. Generic receiver URLs may contain secrets, so they are
stored with credentials rather than in settings. On macOS, signed Harness components
use their shared Keychain entitlement. Unsigned development builds cannot silently
store credentials elsewhere. Linux uses explicitly owner-only credential files;
this storage is not described as encrypted.

Local CLI controls include:

```sh
harness-cli notifications status
harness-cli notifications configure --stdin < reviewed-policy.json
harness-cli notifications mute --surface SURFACE_UUID --run RUN_UUID
harness-cli notifications mute --surface SURFACE_UUID --run RUN_UUID --off
harness-cli notifications snooze --surface SURFACE_UUID --minutes 60
harness-cli notifications credential-set --reference CREDENTIAL_UUID --stdin < private-credentials.json
harness-cli notifications credential-remove --reference CREDENTIAL_UUID
```

Configuration and credential input require redirected, bounded JSON. Secrets are
never accepted as arguments or returned in status responses. Credential references
are UUIDs; delete a reference only after checking that no configured destination
uses it. The app stages a new reference before saving a changed destination and
removes an unused old reference after a successful save. A failed cleanup identifies
the reference and preserves the saved policy for repair.

Accepted pending notices, throttles and provider-independent observation receipts
use the encrypted activity ledger. Delivery has at most 128 pending jobs, four
concurrent external requests, one in-flight request per sink, and three attempts per
notice. Per-sink intervals and delivery expiry remain effective across daemon
handover. Transport errors, HTTP 429 and server errors have bounded jittered retries;
a prior uncertain submission can still cause a duplicate notification. Diagnostics
record result categories and HTTP status, without receiver URLs, payloads or tokens.
Input overflow is reported, not disguised as successful delivery. Desktop diagnostics
say a notice was offered to an attached app; they do not prove an OS banner appeared.
Persistence opt-out strips captured text from queued notices and associated history;
an external request already accepted by its destination cannot be recalled.

Command completion requires a start observed live and the configured duration
threshold. Replayed command starts and older checkpoints without trustworthy timing
do not invent command duration notifications. Agent turn completion does not mean
its provider process has exited. Hook execution identities and terminal sequence
receipts prevent duplicates without suppressing unrelated events in a time window.

Open **Settings → Agents → Configure Power…**, or use:

```sh
harness-cli awake status --json
harness-cli awake on
harness-cli awake off
harness-cli awake auto
```

Automatic idle-sleep prevention is enabled while verified agents work on AC power,
with a default 30-second grace after activity ends. Battery permission is off by
default. Unknown power source follows the battery restriction conservatively.
`on` and `off` last until `auto` or application-daemon restart; battery restrictions
still apply. Power settings reload without restarting the service. Assertions belong
to the daemon and work with the app closed. Explicit macOS sleep is acknowledged
promptly before notification work, and releases the assertion. Sleep push is best
effort. Wake reports observed elapsed sleep when available; local execution paused
while the system slept. Linux reports native power management as unsupported.

The focused fixtures verify consent, timezone boundaries, sink payloads, durable
coalescing/receipts, pane and run restrictions, settings preservation, and daemon
lease recovery. The provisioned native preview verifies shared Keychain access,
Allowed OS notification permission and accepted local delivery, actual AC assertion,
battery restriction and a user-triggered sleep/wake with unchanged process IDs.
External delivery and optional speech remain off; no unperformed sink or audible
check is claimed. See [native acceptance](NATIVE-ACCEPTANCE.md).

Protocol references: [ntfy publishing](https://docs.ntfy.sh/publish/) and
[Pushover Message API](https://pushover.net/api).
