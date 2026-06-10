# Benchmarks

## Baseline gate methodology (`make bench-check` / `bench-record`)

The gate numbers are **single-shot** timings: sensitive to CPU frequency ramp, cold caches, and
background load. Field-measured on the gating machine: the same bench reads 1.5–2× its
steady-state on a first run after idle, and back-to-back `bench-check` runs under background
load produce **non-overlapping** "regression" sets — that's machine variance, not code. Protocol:

- **Judge nothing from one run.** Run `bench-check` twice back-to-back (the first run heats the
  machine); judge the second. A real regression reproduces across consecutive runs — a flapping
  set is noise.
- Conditions: AC power, `caffeinate -i`, no builds/agents/benchmarks running concurrently.
- **Record** = median of three back-to-back warm runs (capture three `make bench` outputs, take
  the per-bench median, feed that through `--record`). Re-record only deliberately, in the same
  PR as an intentional performance or methodology change, on the hardware class you gate on.
- CI's "Benchmarks" job is **non-blocking** by design — runner hardware differs; the local gate
  on owner hardware is the one that counts.

# Cross-terminal output-stress benchmark

`terminal_stress_runner.py` measures how fast a terminal **drains the PTY** — it runs *inside* any
terminal, writes first-party byte payloads to stdout, and times each `write` loop. Higher MB/s =
faster. It is implementation-independent (works in Harness, Ghostty, Terminal.app, …) and is **never
linked or shelled-out from product code** — a measurement tool only.

## Run

Matched settings in each terminal (so the comparison is fair): same font (e.g. Menlo 14), black
background, opacity 1, blur 0, padding 0, window sized to **160 × 48**.

```bash
# In a Harness pane:
python3 Scripts/benchmarks/terminal_stress_runner.py harness harness.jsonl harness.done
# In a Ghostty window (or any other terminal), same payloads:
python3 Scripts/benchmarks/terminal_stress_runner.py ghostty ghostty.jsonl ghostty.done
```

Run **5×** per terminal and compare **medians** (`mbps` per `benchmark`). Each line is one workload:

| Workload | What it stresses | Harness hot path |
| --- | --- | --- |
| `plain_ascii_16mib` | printable-ASCII throughput | SIMD16 run scan → `printASCIIRun` |
| `ansi_sgr_16mib` | SGR-punctuated text | CSI param parse (allocation-free) + run fast path |
| `attributes_8mib` | text-style storm | CSI param parse + cell attrs |
| `unicode_mixed_8mib` | mixed-width Unicode | bulk UTF-8 decode → `printCodepointRun`, `CharacterWidth` O(1) table |
| `truecolor_gradient_1200_frames` | truecolor + home-cursor redraw | frame coalescing |
| `redraw_160x48_600_frames` | full-screen redraw | cell write + block-move scroll |
| `scrollback_100k_lines` | scroll + history eviction | block-move scroll + ring |

## What it measures — and what it does NOT

⚠️ **This drain rate is not a faithful measure of the VT engine.** Harness decouples the writer
from the consumer (the daemon is a dumb PTY-read pipe with no consumer→writer backpressure), so
`os.write` finishes as fast as the **daemon drains the master fd**, and the GUI's parse/render runs
asynchronously, merely *competing for CPU*. Consequences observed in practice:

- Running the **same binary** with the window **foregrounded** (rendering harder) drains **~25–33%
  slower** than backgrounded — focus alone swings the number more than any code change.
- A faster VT engine can leave this number flat or even *lower* (it does more rendering with the CPU
  it frees), because the number is gated by daemon-read-rate + leftover CPU, not parse speed.

So treat the cross-terminal table as a rough, environment-sensitive sanity check, **not** a gate for
engine work. Always pin conditions (quiescent machine, identical window focus/visibility, no other
Harness daemons running) and compare medians of ≥5 runs.

## The faithful scoreboard

For the engine hot paths, use the in-process **consumer scoreboard**
(`PerformanceBenchmarks.testConsumerScoreboard`, `HARNESS_BENCHMARKS=1 make bench`). It runs these
same seven payloads through the real consumer pipeline — parse → `readGrid` → damage →
`FrameBuilder.build` — deterministically, with no daemon, contention, or window-focus confound, and
reports `consumer_<workload>` MB/s. Higher = the terminal turns bytes into a renderable frame
faster. That number tracks the parse/width/cell/scroll work directly; the drain table above does not.

`testConsumerScoreboard` reports `feedNanos` (parse) and `frameBuildNanos` (build) separately — the
parse half is the gate for engine work (frame build is ~0.1 ms vs ~90–140 ms of parse on a 1 MiB
payload). To confirm an engine win survives the real daemon path, `testIPCInclusiveScoreboard` runs the
same payloads chunked at 64 KiB / 4 KiB through the real binary output frame (`IPCCodec.encodeOutputFrame`
→ `decodeReplyOrData`) before the engine; comparing `ipc_consumer_<workload>` to `consumer_<workload>`
shows the framing/chunking tax (in practice: negligible — within noise, and chunk size doesn't move it).

The bulk-UTF-8 codepoint fast path can be disabled at runtime with `HARNESS_DISABLE_BULK_UTF8=1`
(falls back to the per-byte scalar decode), e.g. to A/B its effect on `unicode_mixed`.

Save raw cross-terminal runs under `.benchmark-results/<date>-<desc>/` (git-ignored) with a summary.
