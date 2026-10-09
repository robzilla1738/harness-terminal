# Harness vs Ghostty — comparative scorecard

The "true Ghostty competitor" claim needs receipts. This document is where they live:
methodology first, then committed results from real owner hardware. The current candidate section records scoped release measurements. Older sections are
historical receipts, not current performance claims. [`Scripts/scorecard.sh`](../Scripts/scorecard.sh)
and the consumer benchmarks measure different parts of the pipeline.

**Numbers are receipts, never CI gates.** A prior 37-agent deep dive measured run-to-run
latency noise at 50–100× above signal; thresholds would gate on weather. Trends across
releases on the *same* hardware are the meaningful comparison.

## Methodology

Run on quiet, plugged-in hardware (no thermals ramping, no background indexing). Match the
terminals before any cross-app section: same font + size (Menlo 14), opacity 1, blur 0,
padding 0, same grid and theme brightness class. Historical scripts default to 160×48;
the October 8 candidate probes below use a verified 150×45 grid.

| Section | Probe | Asymmetries (stated, not hidden) |
|---|---|---|
| Cold start | `HARNESS_STARTUP_METRICS=1`, N=10 launches; per-phase deltas from `logs/startup.log` (first drawable is an internal submission milestone, not a usable prompt or photon measurement) | Ghostty exposes no phase log: its number is wall-clock from `open` to the first on-screen window — a coarser probe that includes AppleScript polling (~50 ms quantization). Harness spawns a separate daemon; `daemonConnected` is reported so the split is visible. |
| Sustained throughput | `Scripts/benchmarks/terminal_stress_runner.py` run **inside** each terminal — first-party byte payloads, MB/s accepted by the PTY, 5 runs, compare medians | Harness can accept bytes ahead of its GUI consumer. Drain rate does not establish rendering throughput. **Re-measure the issue #27 workloads (ansi_sgr / attributes / unicode) first**: that loss predates the #31 parse speedups and #139 UCD width tables. If still behind, the follow-up is measurement-first profiling of the SGR/attr dispatch path — no speculative engine surgery. |
| Internal presentation timing | Event injection + `FrameSignposter` percentiles (`Scripts/measure-fluidity.sh`, p50/p95/p99) | Harness-only: Ghostty has no equivalent probe. Cross-terminal latency needs an external camera/typometer; signposter numbers compare Harness against its own previous releases. |
| Idle power | `powermetrics --samplers tasks --show-process-energy`, 60 s, 4 panes open, one window unfocused | Harness app + HarnessDaemon are **summed** — the two-process architecture is part of the result, never hidden. |
| Long-session memory | 1 M lines scrolled through a pane, then `footprint(1)` of the app (fallback `ps` RSS) | The candidate caps raw output and decoded history independently at 512 MiB, with the configured line cap also applied. Viewport, caches, and transient snapshots are additional. Compare equal retained content and report app plus daemon. |
| Daemon memory (idle cost) | Harness only, in the same `memory harness` run. The daemon's own `phys_footprint` (by pid from `harness-cli daemon-stats --json`, fallback `ps` RSS; `SCORECARD_CLI` picks the CLI) at three points: baseline, after the 1 M-line scroll, and after `SCORECARD_PARK_SECONDS` (default 100) of silence, past the 60 s park threshold and its 30 s check. Each row also has the daemon's live ring bytes (raw) and its parked panes with their ring raw vs held (LZ4 on macOS; a Linux daemon holds it raw, so the two match there) | Report both separately and sum app plus daemon for the total; shared pages can make summed RSS overcount physical memory. The parked row needs the pane left alone through the wait: any output into it wakes it. Parking covers every idle pane, not only the one that scrolled. |

### Running it

```sh
Scripts/scorecard.sh --dry-run          # self-check (also runs on Linux CI)
Scripts/scorecard.sh cold-start         # both apps, N=10 each
Scripts/scorecard.sh throughput harness # inside a Harness pane
Scripts/scorecard.sh throughput ghostty # inside a Ghostty window
Scripts/scorecard.sh idle-power         # sudo; leave both idle
Scripts/scorecard.sh memory harness     # inside each terminal (Harness adds daemon rows; ~2 min)
PREVIEW_SIGNPOSTS=1 make preview && Scripts/scorecard.sh input-latency
Scripts/scorecard.sh report             # markdown to paste below
```

## Candidate results — 2026-10-08, Apple M5 / 32 GiB

**Harness does not meet the Ghostty leadership target in this candidate.** Ghostty leads
all seven measured consumer workloads, startup readiness, and retained-history memory.
The reliability and usability fixes are independently useful; they are not evidence of
being the fastest terminal. The remaining targets stay open in the
[execution ledger](TERMINAL-EXCELLENCE-PLAN.md).

Release candidate source: `7dbebe7`; baseline: `56edc52`. macOS 27.2, Swift 6.4/Xcode beta,
arm64; Ghostty 1.3.1 ReleaseFast with Metal/CoreText. GUI probes use Menlo 14, opacity 1,
blur 0, padding 0, cursor blinking off, and a verified 150×45 grid. Separate homes avoid
user sessions and settings. The baseline app has only launcher isolation patches, to avoid
replacing normal installed binaries or restarting the user's launchd daemon. No local
build ran concurrently with measurements. One warm-up and three measured samples per
performance probe; memory states are single observations. Full numbers and sample ranges
are in the [committed receipt](benchmarks/terminal-excellence-2026-10-08.json).

### Consumed output, rather than PTY admission

The [consumer probe](../Scripts/benchmarks/consumer_ack_runner.py) writes each workload,
then requests a cursor position report. The reply fences terminal parsing; Harness's GUI
size owner replies, so its daemon accepting bytes alone cannot satisfy the probe. Elapsed
time includes Python payload generation and query/reply transport. It does **not** measure
GPU completion, smooth scrolling, scanout, or physical input-to-photon latency. Sample 0
is discarded; all recorded samples reached 150×45. Lower milliseconds are better.

| Workload | Bytes (approximately) | Harness median ms | Ghostty median ms |
|---|---:|---:|---:|
| Plain ASCII | 1 MiB | 120.65 | 43.66 |
| ANSI SGR | 1 MiB | 82.77 | 33.08 |
| Mixed Unicode | 1 MiB | 72.09 | 19.25 |
| Attributes | 1 MiB | 79.03 | 35.96 |
| Truecolor gradient | 844 kB | 31.12 | 19.17 |
| Redraw | 870 kB | 22.61 | 7.44 |
| Scrollback | 860 kB | 127.85 | 50.70 |

Ghostty is approximately 1.6–3.7× faster in this probe. The older drain-only scorecard
cannot be used to contradict this result. Next performance work should profile the
end-to-end producer/daemon/GUI path under these workloads before changing architecture.

### Harness baseline and candidate CPU work

Existing release benchmarks run parser consumption plus frame construction, without a
GPU. A paired repeat resolved an initially noisy ASCII measurement; baseline and candidate
were interleaved. Later search-only changes do not alter these parser/reflow paths.

| CPU workload | Baseline median ms | Candidate median ms |
|---|---:|---:|
| ASCII parse + frame | 99.16 | 100.70 |
| SGR parse + frame | 71.31 | 71.73 |
| Unicode parse + frame | 49.19 | 51.15 |
| Redraw parse + frame | 11.75 | 11.77 |
| Scrollback parse + frame | 104.39 | 104.72 |
| Steady-state history at cap | 7.28 | 7.53 |
| Reflow 10k prose rows | 6.21 | 6.07 |
| Literal Find, 20,001 rows | 14.31 | 23.53 |
| Regex Find, 20,001 rows | 49.60 | 70.08 |

Most parser paths are close to baseline. Unicode cost is about 4% higher in the paired
run and about 12% higher against the original baseline; this remains a possible regression.
Attributes and gradient had large baseline variance, so no speedup is claimed. Find now
runs off the main thread with correct Unicode/cell mappings, cancellation, and limits.
Its CPU cost remains higher than the old, incorrect search: approximately 64% for literal
and 41% for regex. Row span compression, memoized normalization, and the safe ASCII matcher
reduced the first candidate's 79/111 ms to 24/70 ms, but did not meet baseline parity.

### Startup and idle

A separate [readiness probe](../Scripts/benchmarks/startup_ack_runner.py) starts each app directly, waits for its shell to reach 150×45,
prints a `READY` marker, and waits for its cursor-report acknowledgement. Parent and child
use the same monotonic clock. It includes shell/Python startup and IPC, uses a warm
filesystem and a cold Harness daemon per launch, and does not establish when pixels
appeared. Identical probe workloads were interleaved after one warm-up per app.

| Startup readiness | Median ms |
|---|---:|
| Harness baseline | 428.9 |
| Harness candidate | 439.5 |
| Ghostty | 303.7 |

Harness's internal first-window median was 87.5 ms baseline / 86.1 ms candidate; first
snapshot was 210.1 / 205.7 ms. These internal milestones are not usable-startup claims.
In particular, `firstDrawablePresented` currently records a present attempt that can be
blank or unsuccessful, and `firstSurfaceAttached` records view attachment rather than the
IPC handshake. Neither should be labeled input-to-photon or compared with camera timings.

| One-pane idle (~8 seconds) | Baseline Harness | Candidate Harness | Ghostty |
|---|---:|---:|---:|
| App RSS MiB | 108.80 | 108.83 | 119.70 |
| Daemon RSS MiB | 17.66 | 17.70 | — |
| Combined RSS MiB | 126.45 | 126.53 | 119.70 |
| App CPU % | 0.37 | 0.37 | 1.12 |
| Daemon CPU % | 0.25 | 0.25 | — |
| Combined CPU % | 0.62 | 0.62 | 1.12 |

These are coarse `ps` CPU samples, not energy or wakeup measurements. Summed RSS can
count shared pages twice. No idle-power leadership is claimed from an eight-second sample.

### Retained history

Each app received 100,000 identical short rows (about 4.7 MB), at 150×45, followed by a
three-second settle. Both current terminals were configured for a 512 MiB retention
ceiling; their internal representations differ. Harness's line cap was disabled.

| History RSS MiB | Harness baseline | Harness candidate | Ghostty |
|---|---:|---:|---:|
| App | 718.61 | 642.27 | 249.83 |
| Daemon | 23.94 | 23.69 | — |
| Combined | 742.55 | 665.95 | 249.83 |

The baseline daemon retained only 1.05 MB of raw output despite the GUI setting. This
candidate fixes that bug and retained all 4.70 MB. Both GUI histories received the full
workload, but raw retention differs, so the table is not an equal-semantics memory win
against baseline. Candidate app-plus-daemon RSS is approximately 2.7× Ghostty's in this
workload. A 512 MiB decoded-history ceiling is not a 512 MiB process-memory promise.

Physical input-to-photon, sustained scrolling frame pacing, privileged power/wakeup
sampling, external display transitions, and real network recovery remain unmeasured.
The reflow microbenchmark and responsive scrollbar check do not substitute for those.

## Results — 2026-06-10, Apple M1 Pro (v1.10.0 tip `bbe1e44`)

Historical debug-preview receipt. Neither this nor the incomplete 2026-10-06 section establishes release performance leadership.

> Conditions, stated plainly: Harness numbers come from the **Debug preview build**
> (`.harness-preview/HarnessPreview.app` — the release runbook's smoke artifact) vs the
> **release** Ghostty from /Applications — conservative in Ghostty's favor. The machine ran
> a resident background agent workload (~half a core); AC power, `caffeinate`, no builds.
> N=10 launches for cold start; one stress-runner pass per terminal for throughput
> (medians-of-5 remain the gold standard — treat single-pass deltas under ~10% as noise).

### Cold start

| terminal | metric | median |
|---|---|---|
| Harness | launchStart → firstWindow | **127.2 ms** |
| Harness | launchStart → firstDrawablePresented | **117.3 ms** |
| Harness | launchStart → daemonConnected | 249.4 ms |
| Harness | launchStart → firstSnapshot | 250.6 ms |
| Ghostty | open → first window (wall clock — coarser probe) | 288.5 ms |

These unlike startup probes cannot establish a relative startup speed. The daemon handshake
arrives after the first drawable, so that drawable also does not establish a usable terminal.

### Sustained throughput (PTY drain, MB/s — higher is better)

| workload | Harness MB/s | Ghostty MB/s |
|---|---|---|
| plain_ascii_16mib | **45.5** | 40.4 |
| ansi_sgr_16mib | 48.4 | 50.2 |
| attributes_8mib | 47.0 | 48.7 |
| unicode_mixed_8mib | 75.5 | 77.3 |
| truecolor_gradient_1200_frames | **31.0** | 14.0 |
| redraw_160x48_600_frames | **91.6** | 51.0 |
| scrollback_100k_lines | **44.6** | 41.4 |

**Historical interpretation corrected:** these are PTY drain rates. They cannot establish
that parser, rendering, or latency losses are resolved, or that Harness leads Ghostty.

### Idle power (60 s, 4 panes, one window unfocused)

| process | CPU ms/s | wakeups/s |
|---|---|---|
| Harness + HarnessDaemon (summed) | _pending — requires sudo powermetrics_ | _pending_ |
| Ghostty | _pending_ | _pending_ |

Re-run `Scripts/scorecard.sh idle-power` with sudo available and paste here; the PR-26 idle
work (display link parked, occlusion gating, blink timers content-gated) is covered by
structural tests either way.

### Long-session memory (1 M lines)

| terminal | footprint after |
|---|---|
| Harness app | 428 MB (`footprint(1)` phys, debug allocator) |
| HarnessDaemon (preview) | 74 MB dirty, 87 MB reclaimable |
| Ghostty | 161 MB RSS (`ps` fallback) |

**Not like-for-like retention:** on this 2026-06-10 run the GUI kept all 1 M lines. That is no longer the design. GUI history now stops at the same byte ceiling as the daemon ring (`ScrollbackBudget.unlimitedSafetyCapBytes` when scrollback is unlimited). Ghostty's default cap retained only the tail. Do not quote the 428 MB figure against a capped Ghostty.

### Internal presentation timing (Harness-only FrameSignposter percentiles, µs)

| phase | p50 | p95 | p99 |
|---|---|---|---|
| present | 1,203 | 11,622 | 13,418 |
| drawableWait (inside present) | 344 | 7,711 | 12,553 |
| instanceBuild | 23 | 4,606 | — |
| upload | 29 | 57 | — |

Captured during a live 4 s resize drag + 4 s scroll fling: **zero dropped frames** in every
120-frame window; p95 is drawable-wait (vsync pacing) dominated, CPU-side build/upload stays
in the tens-of-µs band.

### Daemon echo RTT (`echo_rtt_daemon`, µs) — measured 2026-06-12

The IPC + PTY half of typing latency: client input frame → daemon → PTY write → kernel tty
echo → daemon read → output frame → client. In-process `DaemonServer` + `/bin/cat` surface,
100 probes after 10 warm-ups (`HARNESS_BENCHMARKS=1 HARNESS_LIVE_DAEMON_TESTS=1 swift test
--filter EchoRTTBenchmark`; the 200µs receive-poll inflates every figure slightly).

| metric | value |
|---|---|
| p50 | 437 |
| p95 | 1,886 |
| p99 | 3,058 |

These medians are from different probes and cannot be added to estimate end-to-end latency.
`HARNESS_FRAME_SIGNPOSTS=1` can report keyDown-to-present-completion internally; even that
excludes display scanout and is not physical input-to-photon latency.

## Results — 2026-10-06

Release-vs-release pass. No throughput, power, memory, or keystroke number was measured. The blocks below are the captured logs. Nothing from the 2026-06-10 table is repeated as this run.

### Dry run

`Scripts/scorecard.sh --dry-run` exited 0. `scorecard/dry-run.txt`:

```
[scorecard] dry run: validating helpers + parsers
[scorecard] dry run OK
```

### Sustained throughput (five-run medians)

Not measured. No release `Harness.app`. `scorecard/throughput-harness.txt`:

```
=== throughput / memory (no release Harness.app) ===
ls: ./Harness.app: No such file or directory
ls: /Applications/Harness.app: No such file or directory
LS_EXIT:1
```

### Idle power (60 s, app + daemon, four panes, one window unfocused)

Not measured. `sudo` needs a password. `scorecard/idle-power.txt`:

```
=== sudo powermetrics (noninteractive) ===
sudo: a password is required
POWER_EXIT:1
```

### Long-session memory (1 M lines, matched caps)

Not measured. No release `Harness.app`. `scorecard/memory-harness.txt`:

```
=== throughput / memory (no release Harness.app) ===
ls: ./Harness.app: No such file or directory
ls: /Applications/Harness.app: No such file or directory
LS_EXIT:1
```

### Internal presentation timing (FrameSignposter)

Not measured. `scorecard/input-latency-harness.txt`:

```
log: Must be admin to run 'stream' command
error: no on-screen Harness window found — launch the preview first.
```

### External keystroke-to-pixel

Not measured. `typometer`, `kst`, and `cliclick` are missing. `scorecard/keystroke-pixel.txt`:

```
=== external keystroke-to-pixel ===
typometer: command not found
kst: command not found
cliclick: command not found
```

## Results — 2026-10-07, Apple M5

Debug preview of the unreleased tree, not a release build. `HarnessVersion.short` is still 1.12.1. The 1.13–1.17 names are feature slices under CHANGELOG Unreleased, not a version bump. No throughput, power, memory, or keystroke number was taken on this pass.

### Cold start

`Scripts/scorecard.sh cold-start`, N=10, `HARNESS_STARTUP_METRICS=1`. App: `.harness-preview/HarnessPreview.app`. Medians are from `Scripts/scorecard.sh report` on that log.

| terminal | metric | median |
|---|---|---|
| Harness | launchStart → firstWindow | 81.4 ms |
| Harness | launchStart → firstDrawablePresented | 67.8 ms |
| Harness | launchStart → daemonConnected | 205.55 ms |
| Harness | launchStart → firstSnapshot | 206.75 ms |
| Ghostty | open → first window (wall clock — coarser probe) | 261 ms |

The installed Ghostty was already running (pid 19398). The script's running-process check did not see it, so it opened ten extra instances and quit those. Pid 19398 was still running after the probe. The Ghostty median is that wall clock only.
