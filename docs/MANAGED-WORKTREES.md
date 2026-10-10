# Managed worktrees

Choose **Managed Worktrees…** in the command palette to create, inspect, compare and
clean up a recorded worktree on the selected host. The form selects a repository and
optional committed base. Empty base requires a clean current checkout, including
staged, working-tree and untracked changes. An explicit base allows a dirty checkout
but includes only that resolved commit. Every record keeps its pinned commit and
operation UUID. Keep that ID after a timeout or interruption; inspect the existing
record rather than blindly creating a second operation.

Worktrees default to a private repository-specific directory under Harness application
support, outside the repository. **Location…** configures an absolute parent. Existing
worktrees retain their recorded locations. If the configured directory is inside a
repository, only the generated repository-specific directory is added to `info/exclude`,
with a backup. Unrelated exclusions are preserved. Paths, refs, repository common
identity and management markers are validated. No directory is adopted or removed
because its name resembles a Harness directory.

Durable activity history and stable host identity must be available before creating or removing
managed worktrees. macOS uses signed-component Keychain encryption; Linux keeps explicitly documented owner-only plaintext storage. Failure leaves live programs and existing work intact. Creation
records its intent before running Git. Mutations run in an isolated process group and
inherit a repository-specific exclusive lease as a descriptor. The job and Git retain
that same lease if the daemon crashes. A replacement cannot perform another mutation
or reconcile state until the job has finished; it never automatically repeats an
uncertain operation. Inspect also retries failed marker cleanup. Inspect reconciles a verified partial creation
or an already removed directory. Git commands use argument arrays, bounded output and
deadlines, with external diff/text-conversion, hook and filesystem-monitor commands
disabled for inspection. Ambient Git overrides cannot redirect the repository target.

Compare shows committed changes from the pinned base, current tracked changes from
HEAD, untracked paths and a bounded patch against the base. Binary files are counted
separately; missing or over-budget values are unavailable. These are repository-state
observations, not attribution of all checkout changes to an agent. Tests are never
inferred from a diff. The difftool action prepares and copies a quoted command for
explicit execution in a shell on the recorded host; it does not submit input or start
an external tool automatically.

Cleanup confirms intent, verifies the managed identity again, checks Git dirtiness,
checks live process working directories by kernel directory identity, and refuses new
commits after the pinned base that are not reachable from an observed remote ref. Git
checks dirtiness again during removal. Cleanup never uses `--force` or recursively
deletes arbitrary paths. Branches are retained so committed work stays addressable.
Active management records are never evicted; removed records follow 14-day/500-record
retention. Failed operations retain their paths and an actionable status for inspection.

```sh
harness-cli worktree create --repository /absolute/repo
harness-cli worktree create --repository /absolute/repo --base main --id <UUID>
harness-cli worktree list
harness-cli worktree inspect --id <UUID>
harness-cli worktree compare --id <UUID>
harness-cli worktree difftool --id <UUID>
harness-cli worktree remove --id <UUID> --confirm
harness-cli worktree configure --directory /absolute/parent
```

The corresponding `worktree.*` API methods carry explicit effects, local CLI exposure
and `managed-worktrees-v1`. A new method does not silently join mobile, Lua or MCP
write tools. Configuration and trust stay on the host. The app reports an older-daemon
capability failure rather than restarting shells.

Git's primary contracts are documented in [worktree](https://git-scm.com/docs/git-worktree),
[rev-parse](https://git-scm.com/docs/git-rev-parse) and [diff](https://git-scm.com/docs/git-diff).
Fan-out launch, workload completion, cancellation and comparison remain separate
implementation work; this document describes the managed-worktree flow only.
