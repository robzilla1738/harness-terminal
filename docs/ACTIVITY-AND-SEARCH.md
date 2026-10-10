# Recorded activity, usage and search

The Overview's Board mode queries connected hosts concurrently, retains stale rows
when a host is offline, and keeps keyboard selection by host and surface identity.
Jump, Peek, Resources, Usage, Tool timeline, mute/snooze, Digest, exact Resume and
command-output actions operate on the selected host and pane.

## Usage and optional costs

Usage is observed profile-wide transcript data. Missing counters are unknown.
Approved profile roots confine reads; Harness does not read provider credentials to
identify accounts. File identity, committed offsets, partial-line handling and
persistent cumulative watermarks prevent repeated observations from adding tokens
again. Coverage warnings persist with cursors when malformed records are skipped.
Rotation and truncation preserve deduplication, with unavailable or corrupt ledger
records failing the read instead of advancing the cursor silently. Limit percentages
are independent observations, not tokens to sum across executions. Reset timestamps
remain predictions; a later provider window with lower observed usage supplies
separate reset evidence.

Activity profiles accept optional explicit pricing, through the profile editor or
`activity-profile set --pricing-json`. Each price declares an observed model ID,
ISO currency, `per_million_tokens` units, and nonnegative decimal input/output rates;
cache-read and cache-creation rates are optional. Harness does not infer prices or
models. Costs are labeled estimates for the observed priced subset; unknown/unpriced
models, missing counters and missing cache rates make coverage incomplete. Different
currencies remain separate. Legacy buckets keep unknown model coverage when the first
attributed record arrives. Claude cache counts are separate from ordinary input;
Codex cache counts are included in its input total. Reasoning is not added to output a
second time. The Board's Usage action and `harness-cli usage` expose these labels,
freshness, warnings and estimates. These observations are not a billing statement.

## Repository reports and execution attribution

The Board's **Repository reports** action and `digest --repositories --days 1 --offset 0`
show paginated reports; `digest.repositories` exposes the same explicitly declared read
API. Recorded worktrees group by their verified Git common directory. Unknown identity
has its own labeled group. Totals use the same deterministic event-count builder as
the host digest; the 200-event display timeline never limits them. Reports contain no
inferred test results. Managed-worktree comparison separately labels checkout diffs as
repository state, without attributing shared modifications to a particular execution.

Directory capture uses a provider's verified launch or hook directory, with process
working-directory observation as a provisional source. Git identity discovery uses a
bounded background queue outside registry locks and terminal delivery. Directory,
repository metadata and associated usage attribution are encrypted sensitive ledger
payloads on macOS. An authoritative profile conflict is refused instead of creating a
second active execution; persistence opt-out keeps the execution ID while removing
captured profile, conversation, directory and repository text.

Profile totals may include observed historical conversation usage. Repository totals
include only usage attributable inside an execution's recorded time bounds. A Codex
cumulative baseline, or a delta across an execution boundary, cannot be assigned to the
new execution or priced as if all its tokens used the current model. Subsequent observed
baselines within that execution permit attribution of later deltas. Legacy watermarks
start with unknown attribution and establish a new baseline. Cursors, profile counters,
per-execution counters and watermarks commit together. Missing counters remain unknown;
account-wide limit observations are displayed once in host profile usage.

Usage aggregates and their minimal attribution metadata survive for 90 days; closed
execution detail and event totals follow the 14-day/500-closed-execution limit. Reports
state that their event totals include retained records. Attribution metadata contains
no launch arguments, conversation IDs or event text. Opt-out purges associated
attribution and per-execution usage, including aggregates whose closed execution detail
already expired. Profile-wide numeric aggregates remain. Repository queries have a
four-second work budget, bounded queued requests, cancellation and SQLite interruption;
a budget error never advertises partial counts as complete.

## Tool timeline

The Board's Tool timeline action pages through recorded events for the selected
execution. `harness-cli agents --run <execution UUID> --offset 0 --limit 100 --json`
and `agent.session` expose the same event pages. Event sequence anchors identify
where the observation reached Harness; they do not attribute precise output ranges
to concurrent tools. Each new anchored event also records its stream identity.
Queries label an anchor retained, evicted, stream replaced, terminal closed, or
unavailable. Older events lacking stream identity remain unavailable rather than
being attached to a different shell that reuses the pane ID.

## Filtered output search

Search All Sessions retains the existing 100-result pagination and validates output
locators before opening a pane. Literal searches work with older daemons. Regex and
recorded agent/time filters require `filtered-output-search-v1`; unsupported hosts
show an update error without restarting shells. A new query or changed filter
cancels outstanding work. Host requests are bounded to four concurrent workers.

Agent/time filters select panes whose recorded executions overlap the selected
range. They do not assign exact timestamps or attribution to mutable terminal
lines. The UI states this limitation. Output search examines retained output in open
panes, including the terminal screen; closed output is not reconstructed into a
replacement terminal.

Regex uses ICU syntax in an isolated daemon worker, with no history files or daemon
startup. Batches are limited to 128 logical lines and 2 MiB of text; stdin and output
are bounded. Each regex batch has a one-second parent-enforced deadline; each search
page has a ten-second work budget. Cancellation or budget failure returns an error,
not a partial page presented as complete. Regex matching never runs under the registry
lock or on the PTY reader. Narrow the session/execution scope if a query exceeds its
budget. The API `output.search_filtered` accepts `query`, `regex`, `case_sensitive`,
`session`, `agent`, execution `from`/`to` in Unix seconds, `offset`, and `generation`.
Its metadata enforces the explicit capability and read exposure. New tools do not
join MCP's approved tool set automatically.


Explicit fan-out test commands now have their own durable execution records. Actual
host receipts update their results; provider exit codes and arbitrary shell commands
never become test results. Global and repository digests display passing, failed,
pending and unknown retained observations independently of the 200-event timeline.
See [fan-out](FAN-OUT.md) for launch, recovery, privacy and retention behavior.
