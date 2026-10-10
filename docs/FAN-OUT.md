# Fan-out and explicit tests

Open **Fan-out…** from the command palette. Choose participant counts, their Harness
profile labels and optional executable/configuration directories, enter a prompt,
and choose a repository. A blank base requires a clean checkout. An explicit base
selects a committed Git ref; uncommitted changes are never copied. Every managed
worktree starts at the same resolved commit. Worktrees are outside the repository
by default and keep the management protections described in
[managed worktrees](MANAGED-WORKTREES.md).

The shared-checkout option is explicit. Its comparisons describe shared repository
state, not changes attributed to one agent. The base commit is checked before each
shared launch. A participant's process outcome remains independent of the others.

Provider presets use argument arrays and prepared stdin, followed by EOF. The prompt
is not appended to the command line or echoed by the terminal driver. Output stays
in a real terminal pane. No approval bypass, forced writing or sandbox override is
added. Headless execution can therefore propose changes or refuse tools that require
interaction, according to the provider's own settings:

- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode):
  `codex exec --json -` reads the prompt from stdin.
- [Claude programmatic mode](https://code.claude.com/docs/en/headless):
  `claude --print --output-format stream-json --verbose` reads the prompt from stdin.
  A completed turn can leave the process alive while background work continues.
- [Cursor output formats](https://cursor.com/docs/cli/reference/output-format) and
  [headless mode](https://cursor.com/docs/cli/headless): the installed `agent` or
  `cursor-agent` uses `--print --output-format stream-json` with piped input. Harness
  does not add `--force`.

Profile labels identify observations, not accounts. An optional Claude or Codex
configuration directory sets `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Cursor uses its
normal installed configuration. Harness does not inspect credentials to identify
an account. Custom transcript roots remain an explicit, separate profile setting.

## Ownership, recovery and privacy

Fan-out requires durable activity storage and a session host advertising both
`workload-stdin-v1` and `workload-outcomes-v1`. Unlock or repair the history key first
on macOS. An older or monolithic owner returns an actionable compatibility error;
existing programs are preserved until an explicit owner update is safe.

The encrypted activity ledger stores the group ID, prompt, pinned base, participant
IDs, worktree IDs and exact launch specifications before accepting launches. The
stable host stores structural workload receipts independently of layout and terminal
history: workload/surface/stream/process identities, kernel birth identity, state,
exit code, cancellation flag and observation times. Receipts contain no prompts,
arguments, repository names or provider messages. Receipt files are owner-only and
atomically replaced; this structural catalog is not advertised as encrypted text.

A real `waitpid` outcome completes a process. Terminal EOF, provider Stop events and
turn-complete output do not. The app says **Process exited N**, which does not claim
that generated changes are correct or that every descendant process has ended.
Explicit test results are separate. Cleanup still checks live processes using each
worktree, changed files and unpushed commits.

**Inspect** refreshes receipts and shows partial failures. Background observation
also refreshes active groups through a bounded, rotating worker. A failed launch
batch preserves already running participants and partial worktrees. Repeating an
accepted group ID returns its record; it never repeats launches. Interrupted or
expired receipts remain unknown rather than becoming success. After a host
interruption, previously reserved/running receipts become unknown. There is no
surprise resume after daemon recovery, owner restart or reboot. Inspect existing
work, preserve or repair partial worktrees, and start new work explicitly when needed.

**Cancel workloads…** requests cancellation only for matching stream, process and
kernel identities. It cannot stop a fresh shell that reused a pane. Cancellation is
not reported as completion until the process is reaped. A failure for one identity
is reported independently while other participants are still handled. Closing the
configuration window stops its pending launch request at cancellation boundaries;
workloads already launched remain independently owned.

**Compare** includes committed changes, working-tree changes and untracked paths
against the pinned base. **Copy difftool command** prepares a quoted command for the
recorded host; it does not submit it. **Clean up…** removes only verified managed
worktrees, preserving dirty, active and unpushed work. Close any fresh shells still
using a worktree before cleanup. A failed cleanup retains its management record for
inspection and retry. Shared checkouts are never removed.

Closed captured detail expires after 14 days or 500 closed records. Management
identity can outlive captured text while protected worktrees still need cleanup.
Active or unknown workloads are never automatically evicted. Persistence opt-out
for an associated agent or test pane removes the group's captured prompt, launch
arguments and failures and associated test/repository detail from digests and
caches. Structural outcome and management identities remain distinct. A batch
interrupted by opt-out does not launch remaining participants from removed text.

## Explicit tests and digest results

Select an exited participant and choose **Run explicit test…**. Provide an absolute
executable and a JSON array of separate arguments, such as `/usr/bin/env` with
`["swift", "test"]`. This command runs once in the recorded working directory using
the same stable owner. Its operation ID prevents accidental repeated execution.
No test command is inferred from a tool name, arbitrary terminal command or provider
exit code, and no test runs automatically because files changed.

Actual test receipts update the encrypted test ledger and group record in one
transaction. Digest and repository reports use complete retained test records,
independent of their 200-event display timeline. Only an explicit test process exit
code of zero counts as passing. Pending and unknown outcomes are displayed separately.
Closed test detail follows the 14-day/500-record boundary; active/unknown tests remain.

## CLI and API

Example `providers.json`:

```json
[{"provider":"codex"},{"provider":"claude-code","profile":"work","providerHome":"/absolute/claude-config"}]
```

```sh
harness-cli fanout start --repository /path/to/repo --providers-file providers.json --prompt-file prompt.txt
harness-cli fanout inspect --id GROUP_UUID
harness-cli fanout compare --id GROUP_UUID
harness-cli fanout cancel --id GROUP_UUID --confirm
harness-cli fanout cleanup --id GROUP_UUID --confirm
harness-cli fanout test --id GROUP_UUID --participant PARTICIPANT_UUID --executable /usr/bin/env --arguments-file args.json
```

Start reads bounded UTF-8 stdin when `--prompt-file` is omitted. `--base REF` selects
an explicit committed base; `--shared-checkout` disables managed worktrees. Retain
the printed operation ID after an uncertain request. `--id` and test `--operation`
accept explicit UUIDs for safe inspection and retry. `list --offset N` paginates
history. Requests and stored objects have bounded payloads; oversized batches are
refused before accepting the affected process launch.

Local APIs are `fanout.list`, `fanout.start`, `fanout.inspect`, `fanout.cancel`,
`fanout.compare`, `fanout.cleanup` and `fanout.test`. Effects, schemas and the
`fanout-v1` capability are explicit. These APIs are not automatically exposed through
Lua, mobile or MCP. Installation does not launch providers or change vendor trust.

Root absence is recorded separately from an exit result. After an interruption, a different kernel birth identity or ESRCH can prove that the recorded root is gone while its exit code remains unknown. Such a receipt permits protected cleanup only after the existing managed-worktree checks also reject active descendants, dirty files and unpushed work. Unknown receipts whose roots may remain live are not evicted. A transient receipt write failure retains truthful memory state and retries only against the unchanged owned catalog; corrupt or externally changed catalogs are not overwritten.

A preflight refusal before any host request is recorded as not started, rather than an uncertain accepted workload. Explicit test intents refused before launch remain deduplicated but do not count as executed, passed or failed tests. Their separate not-started count does not block subsequent testing or protected cleanup. Provider profile labels are exported to observation hooks for structured fan-out and scheduled launches.
