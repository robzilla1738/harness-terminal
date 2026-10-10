# Explicit local scheduling

Scheduling is off until a reviewed definition has `enabled: true`. **Schedules…** in the palette creates disabled one-shot/cron agent tasks, previews exact arguments, directory, stdin, profile and timezone, and provides enable/disable, definition import/edit, occurrence history, cancellation and guarded deletion. Advanced definitions also support agent-event and explicitly opted-in predicted limit-reset triggers. The window is local to the recorded host, loads all bounded schedule rows and preserves selection by UUID. It shows refresh time; occurrence timestamps remain available in detail. A monolithic daemon or unavailable encrypted ledger reports scheduling unavailable instead of silently launching work.

Definitions and occurrence/cursor state live in the daemon-owned encrypted activity store. Configurations have a stable UUID and reviewed revision; replacements require the current revision. Save commits intent before a host workload can be accepted. Only the active daemon's mutation lease permits automatic work. Programs use the stable PTY owner, structured argument arrays and bounded stdin, with normal provider approval settings. Runtime observations never convert a completed conversational turn into a program exit.

Each occurrence records identity, due/observed times, optional predicted-reset labeling, exact host workload identity and actual process outcome. Duplicate provider events are consumed through committed ledger sequences. No uncertain submission is retried. A previous launching/running/unresolved workload prevents overlap; skipped overlaps remain explicit history. A proven absent root can release that ownership restriction while its exit result stays unknown. Cancellation validates the recorded process identity; acceptance of a cancellation request is not completion.

One-shot timestamps are absolute ISO 8601 times. Cron uses an IANA timezone and five numeric fields (`minute hour month-day month weekday`), with wildcards, lists, ranges and positive steps; 0/7 mean Sunday. Restricted month-day and weekday fields use OR. A nonexistent DST wall time is skipped, and a repeated wall time occurs once at its first UTC instance. This documented behavior is deliberately explicit rather than inheriting a machine's cron daemon or silently changing timezone.

Occurrences already due when a service starts, or more than 30 seconds late, are missed. Cron's missed interval is coalesced into a labeled history record through the observation time, and its next occurrence moves into the future. There is no surprise catch-up after sleep, downtime or a failed upgrade. Events use committed run-event IDs and optional surface/provider/profile filters; historical events from before configuration are not replayed. Reset triggers require `acceptPredictedTime: true`; the recorded prediction is not evidence that allowance reset. Unavailable or stale observations do not launch reset work.

CLI and local APIs are available independently of the app:

```sh
harness-cli schedule preview --input schedule.json
harness-cli schedule save --input schedule.json --reviewed
harness-cli schedule save --input schedule.json --reviewed --revision 1
harness-cli schedule list
harness-cli schedule occurrences --id UUID --offset 0
harness-cli schedule cancel --id OCCURRENCE-UUID --confirm
harness-cli schedule delete --id UUID --revision 2
```

`preview` and `--dry-run` perform no writes. `save --stdin` accepts a bounded definition without putting prompt text in command arguments. Public methods are `schedule.list`, `schedule.save`, `schedule.occurrences`, `schedule.cancel` and `schedule.delete`; required capabilities, effects and local exposure are declared in the generated catalog. Administrative controls remain local at both daemon and session-host forwarding boundaries. They are not automatically exposed to MCP, mobile or Lua.

A definition's trigger is one of:

```json
{"once":{"at":"2026-11-02T15:00:00Z"}}
{"cron":{"expression":"0 9 * * 1-5"}}
{"agentEvent":{"kind":"turnCompleted","provider":"codex"}}
{"limitReset":{"profileID":"PROFILE-UUID","window":"primary","acceptPredictedTime":true}}
```

The other fields are `id`, `name`, `enabled`, `timezone`, `workspaceID`, `provider`, `launch` (`executable`, `arguments`, `directory`, `profile`, optional profile/locale `environment`) and optional `input`. Provider/profile identity is separate from account identity. Keys belong in the credential store; the schedule accepts no credential environment overrides. Definitions are limited to 128, input to 32 KiB, and arguments to 64 KiB. Closed occurrence detail is retained for 14 days or 500 records; active/unresolved work is protected. Deletion refuses a schedule with active accepted work and leaves retained history subject to normal retention.

Focused evidence covers timezone/DST behavior, malformed/impossible cron expressions, duplicate event prevention, overlapping workload protection, missed occurrences, replacement without re-execution, actual PTY exit status, encrypted ledger bytes and unavailable-key refusal. The provisioned native walkthrough saves and inspects a disabled one-shot definition with its exact launch/directory/profile and IANA timezone; no provider is executed. Unavailable-history presentation also passes. See [native acceptance](NATIVE-ACCEPTANCE.md).
