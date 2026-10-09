# Release-readiness review — October 9, 2026

This is the historical Harness 2.0 readiness review. The current 2.1 release and companion
follow-up are documented in [the release runbook](RELEASE.md), [CHANGELOG.md](../CHANGELOG.md)
and [MOBILE-BRIDGE.md](MOBILE-BRIDGE.md). Statements below describe that original audit.


This candidate preserves Harness's existing visual design and improves restoration,
split correctness, reflow performance, updater security, Unicode coverage, color emoji, and build reliability.
It is a tested local candidate, not a published release or a claim that every bug is gone.
The starting revision was `889af7e`; changes are on `codex/release-readiness-20261009`.
The earlier [terminal audit](TERMINAL-EXCELLENCE-PLAN.md) remains historical evidence;
this report supersedes its statement that the reproduced fish replay defect is unfixed.

## Changes and evidence

| Area | Finding and resulting behavior | Evidence |
| --- | --- | --- |
| Reattachment and disk restoration | Raw output replayed entirely at the current width misinterpreted fish cursor redraws. Record geometry at byte boundaries and replay each span at its original size, then reflow to the receiving window. | Captured real fish resize trace, cold/warm parser, parking, GUI restore, and disk restart regressions. Packaged app quit/reopen smoke test. |
| Snapshot cost and ordering | A width change discarded the cached parser and reparsed history; concurrent readers could process stale snapshots out of order. Keep the parser, apply geometry transitions, and copy history under the snapshot serialization lock. | Cached-resize regression verifies bytes are not reparsed; capture/search/live-daemon suites pass. |
| Split layout | Rebuilding a nested split briefly narrowed an unchanged neighbor, then a stale debounce committed that width after its bounds recovered. Cancel obsolete commits and previews. | New hosted regression failed before the fix and passes after it. The packaged app now keeps the neighbor at 48 columns rather than 10 in the reproduced interaction. |
| Reflow | Compact hard-ended history rows were expanded with blank padding before wrapping. Avoid materializing that padding. | Matched release benchmark: median 11.468 ms → 9.034 ms per width change, **21.2% less CPU time**. Reflow, grapheme, CJK, preview and rendering tests pass. |
| Updater | Sparkle 2.9.2 was behind upstream security fixes. Upgrade SwiftPM and Xcode declarations/lockfile to 2.9.6. | Official [2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) and [delta-update advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5); bundled framework version verified. |
| Concurrency and maintenance | AppKit completion handlers and worker captures produced concurrency warnings; a removed toolbar property produced a deprecation warning. Use explicit captures/main-queue UI completion and remove the unsupported assignment. | SwiftPM release/debug and Xcode builds succeed; UI smoke checks preserve appearance. |
| Benchmark gate | A successful comparator could hide a failed Swift benchmark command. Use Bash with `pipefail` for both benchmark pipelines. | Injected Swift failure with a successful comparator makes both Make targets fail. |

The reflow measurements use three measured runs per variant after warm-up on Apple M5,
macOS 27.2, Swift 6.4. Baseline and candidate were sequential, not interleaved.
See the [raw receipt](benchmarks/release-audit-2026-10-09.json) and [scorecard](SCORECARD.md).
This measures CPU reflow, not physical input latency, energy use, or superiority over every terminal.

## Verification

### Unicode and color-glyph continuation

- Replaced hand-maintained Unicode 15.1 width ranges with a reproducible generator for
  [Unicode 18.0.0](https://www.unicode.org/versions/Unicode18.0.0/). Three versioned upstream
  files have pinned SHA-256 hashes. Network and local-data generation produce identical output;
  modified input fails before emitting a table. Exhaustive scalar tests compare packed and
  reference lookups. Unicode's license is retained and copied into the packaged app.
- New combining marks use pinned Grapheme_Extend data even on older hosts. Capture, reflow,
  restore, copy and search retain their text and column mapping. Copy mode no longer truncates
  a cell to the first grapheme recognized by the host's older Unicode implementation.
- Added native CoreText color emoji, including flags, modifiers and joined sequences, with
  a lazy RGBA atlas alongside ordinary R8 text. Independent page eviction preserves text
  cache entries. Growth tests verify all four channels survive texture replacement; LRU
  tests verify hot pages survive after growth and repeated eviction.
- Color glyphs bypass foreground tint, coverage gamma and font thickening while respecting
  conceal, faint and blink. Rasterization uses the pane's sRGB/Display-P3 space, including
  thumbnails. Pixel tests cover both ligated and per-cell paths. Mixed blink states now split
  shaping runs correctly.
- Removed unnecessary LRU writes when only one atlas page is populated. The existing warm
  ASCII cache benchmark is 20.6% faster than `4e260a4` across five interleaved release samples.
  Full-frame encode measurements show no median slowdown but substantial noise; see the
  [scorecard](SCORECARD.md) and [raw receipt](benchmarks/unicode-color-2026-10-09.json).

The final full local macOS suite passed **2,313 tests, 58 skipped, zero failures** in 93.7 seconds.
Optimized release validation passed **161 tests, two skipped, zero failures**. The final
Xcode Debug build succeeded. The packaged candidate passed
ad hoc signature verification and includes the complete third-party notices. A live GUI check
confirmed native emoji, unchanged foreground tint behavior, dim/concealed emoji, ordinary
Latin/CJK/Thai text, drawing characters, bold/italic/underline, and Find (`1 of 5` for a joined
emoji). The window design remains unchanged.

Logs: `/tmp/harness-unicode-color-full-final.log`,
`/tmp/harness-unicode-color-release-verified.log`, `/tmp/harness-unicode-color-xcode.log`,
`/tmp/harness-color-space-tests.log`, and `/tmp/harness-unicode-color-package.log`.
The first continuation CI run passed **1,745 Linux tests, two skipped, zero failures**, plus
both release builds and the Xcode project. Its pinned macOS compiler rejected an overly
complex test assertion that the local beta accepted; the assertion was split into explicit
scalar steps and its 26-test suite passed locally. The [draft PR](https://github.com/robzilla1738/harness-terminal/pull/188)
records the exact final commit's rerun outcome. This upgrade covers width/extender data, not full Unicode 18 grapheme
segmentation or glyph availability on every supported macOS version.

### Follow-up review

The continuation found additional failures with reproducing tests:

- Clearing the raw history left already-warmed capture and search grids holding old text.
  Clear now drops those grids and the parked snapshot, and orders persistence appends against
  the disk reset. Attached clients still receive the existing saved-lines clear command.
- Disabling persistence on an already parked pane deleted its only screen snapshot. The pane
  now retains that screen in memory before removing the file. Persistence changes/deletion and
  parking share the screen lock, preventing a late park write from undoing an opt-out.
- A replaced shell's cancelled read source could drain its last bytes into freshly cleared
  history. Output now carries its shell generation; a clear during replacement rejects older
  generations while ordinary shell exits still drain their final output.
- Lua `package.loadlib` failed to load a system-library symbol through the obsolete macOS dyld
  API. Both supported platforms now use Lua's POSIX `dlopen` path. The macOS regression checks
  symbol resolution without invoking a non-Lua function through Lua's C calling convention.
- On macOS, `FIONREAD` returned zero even when the PTY master had unread child output. A direct
  `openpty` experiment reproduced this, and a gated real-child regression demonstrated lost
  output during read-source cancellation. Resize/cancellation drains now use nonblocking reads
  up to a 256 KiB budget, stopping on EAGAIN/EOF. The bounded work also prevents a child that
  keeps writing from starving resize or teardown.

The review also keeps PTY size/foreground queries under the descriptor lifecycle lock and
aligns the preview bundle's minimum OS with macOS 15. Neither change alters the visual design.
A final lifecycle review moved read-source installation under the lifecycle lock: a superseded
start now returns before touching a potentially reused descriptor, and every created source is
activated. Previously a concurrent close could lead to disposal of an inactive dispatch source.
A no-fork regression verifies a stale start leaves an unrelated pipe's descriptor untouched.
The source-installation follow-up passed **39 live-daemon/lifecycle tests with coverage** and
**50 lifecycle/snapshot/persistence tests under Thread Sanitizer without race reports**.

The full follow-up runs exposed the incorrect FIONREAD assumption through the new respawn
regression. Its fixture now uses child-produced output and file acknowledgements, plus a read
queue gate, to exercise cancellation without depending on terminal input or availability queries.

The full macOS follow-up suite passed **2,302 tests, 58 skipped, zero failures** in 92.6 seconds.
Thread Sanitizer passed **49 lifecycle/snapshot/persistence tests without race reports**.
Optimized release validation passed **68 lifecycle/snapshot/persistence/Lua tests**.
The follow-up Linux suite passed **1,740 tests, 2 skipped, zero failures** before the final
nonblocking-drain change; the draft PR's Linux job validates that change on the shipping toolchain.
The final Xcode build also passed; the obsolete Lua loader warnings are gone. A release CLI smoke
test confirmed `run --wait` propagates exit code 7, captures the command's output, and removes
that output from a warmed capture after `clear-history`, using an isolated daemon home.

Reviewing the latest failed CI run on `main` identified two fixture races. The screen-warmer
test mistook the echoed command's completion marker for actual completed output. It now waits
for the marker on its own output line. The pagination test could expire legitimately when a
prompt or an unrelated shell produced output between pages. It now scopes the search to its
own session and holds its shell at `read` until explicitly releasing the output change.
Both corrected fixtures passed in a four-test run with code coverage enabled.

Follow-up logs: `/tmp/harness-followup-final-sanitizer.log`,
`/tmp/harness-final-release-verified.log`, `/tmp/harness-followup-linux.log`,
`/tmp/harness-followup-final-all.log`, `/tmp/harness-ci-fixtures.log`, and
`/tmp/harness-followup-final-xcode.log`. Source-installation follow-up logs are
`/tmp/harness-source-install-tests.log` and `/tmp/harness-source-install-sanitizer.log`.

### Initial pass

| Check | Result |
| --- | --- |
| Final macOS debug suite with live PTYs/daemon | **2,297 tests, 58 skipped, zero failures**, 92.8 seconds. |
| Linux Swift 6.0 full suite with live PTYs/daemon | **1,737 tests, 2 skipped, zero failures**, approximately 85 seconds. Later production edits were macOS-only. |
| Final focused release resize/replay/persistence suite | **77 tests, zero failures**. |
| Release reflow/text/preview checks | **66 tests, zero failures**. |
| Xcode Debug build, signing disabled | **BUILD SUCCEEDED**, including after the split fix. |
| Packaged release app | Launches, bundles Sparkle 2.9.6, passes `codesign --verify --deep --strict` with an ad hoc local signature. |
| Packaged UI smoke checks | Fish input and Unicode paste/output, horizontal/nested splits, regression reproduction and fix, Find with `1 of 1`, settings search, `less` alternate-screen entry/exit, persistent quit/reopen. |
| Repository hygiene | `git diff --check` passes. Existing unrelated `.supergoal/` files preserved. |

The macOS skips are 54 opt-in benchmarks, two tests requiring an uninstalled Nerd Font,
one theme-generation test, and one test requiring a newer bash than `/bin/bash`.
Selected benchmarks were run separately. A strengthened fish fixture additionally checks
restoration at every recorded boundary, so a later shell redraw cannot hide an earlier error.

Commands for repeatability:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  HARNESS_LIVE_DAEMON_TESTS=1 swift test --build-system native

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --build-system native -c release \
  --filter 'LiveResizeTests|HistoryRestoreTests|SnapshotTests|ReplaySizeTests|ScrollbackFileTests'

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug \
  -derivedDataPath /tmp/harness-audit-xcode CODE_SIGNING_ALLOWED=NO build

docker run --rm --mount type=bind,src="$PWD",target=/src,readonly \
  -e HARNESS_LIVE_DAEMON_TESTS=1 swift:6.0 bash -lc 'set -euo pipefail
mkdir /work
cd /src
tar --exclude=.git --exclude=.build --exclude=dist --exclude=.supergoal \
  --exclude=.harness-preview --exclude=.benchmark-results -cf - . | tar -xf - -C /work
cd /work
swift test --scratch-path /tmp/harness-linux-build --jobs 4'
```

The explicit Xcode developer directory avoids the local CommandLineTools installation's
missing SwiftUI macro plugins. The native SwiftPM backend is deprecated on this beta
toolchain; CI should still run on the project's pinned stable release toolchain.
Existing duplicate-rpath, vendored Lua empty-loop, and Xcode metadata-extraction warnings remain.

Local logs are under `/tmp`: `harness-complete-final-tests.log`, `harness-linux-tests.log`,
`harness-final-resize-tests.log`, `harness-reflow-checks.log`,
`harness-fish-boundaries-final.log`, and `harness-xcode-final-build.log`.
These are session evidence, not durable CI artifacts.

## Restoration compatibility and limits

The optional IPC field lets old clients and daemons continue communicating. New clients
use legacy replay when talking to an older daemon. Historical logs without a size sidecar
cannot recover geometry retroactively and may retain the earlier redraw problem.
Restart/upgrade the daemon to record geometry for new output.

The owner-only `.scroll.sizes` sidecar is validated against the raw log's inode and length,
rebased during compaction, and removed with history clearing, pane deletion or persistence
opt-out. Invalid metadata falls back to legacy replay. Debounced data/metadata writes are
not a transaction across both files: a crash can lose unflushed output or its latest geometry.
Partial writes invalidate the mapping instead of silently reusing stale offsets. Retention
can begin in the middle of an escape sequence; this work does not turn a bounded raw tail
into a complete, indefinitely retained terminal state.

## Remaining release gates

1. Run CI on the exact shipping commit with the pinned stable Xcode and Linux jobs. Local
   beta-toolchain success does not substitute for that release gate.
2. Complete or explicitly scope the physical IME/non-US keyboard, VoiceOver spoken output,
   external display/Spaces, and real SSH sleep/wake/tunnel-loss acceptance work tracked in
   [#187](https://github.com/robzilla1738/harness-terminal/issues/187). These were not verified here.
3. Preserve honest compatibility/performance claims. Native color emoji and Unicode 18 width
   data are now implemented. Full grapheme segmentation/font coverage still depend on the host;
   broader cross-terminal throughput, startup, physical latency and power targets remain open.
4. Follow the [release runbook](RELEASE.md): choose/bump the release version and build,
   regenerate release notes, sign with Developer ID, notarize, smoke-test the DMG, and
   verify the Sparkle update path. No version bump, tag, public release or appcast publication
   was performed in this pass.

The local app is `dist/release-audit/Harness.app`, with a distinct bundle identity and
`HARNESS_HOME=/tmp/harness-qa-20261009`. It is for review; it does not replace the normal
Harness installation or its sessions.
