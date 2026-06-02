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
| `plain_ascii_16mib` | printable-ASCII throughput | run fast path (`printASCIIRun`) |
| `ansi_sgr_16mib` | SGR-punctuated text | CSI param parse (allocation-free) |
| `attributes_8mib` | text-style storm | CSI param parse + cell attrs |
| `unicode_mixed_8mib` | mixed-width Unicode | `CharacterWidth` O(1) table |
| `truecolor_gradient_1200_frames` | truecolor + home-cursor redraw | frame coalescing |
| `redraw_160x48_600_frames` | full-screen redraw | cell write + scroll |
| `scrollback_100k_lines` | scroll + history eviction | block-move scroll + ring |

## What it validates

This is the end-to-end gate behind the engine/transport work in
`.cursor`/`docs` perf notes: the in-repo XCTest micro-benchmarks
(`Tests/HarnessBenchmarks`, `HARNESS_BENCHMARKS=1 make bench`) isolate each hot path, while this
script proves the change actually moves the **drain rate** a user sees. Target: the
`unicode_mixed`, `attributes`, `ansi_sgr`, and `redraw` medians beat the comparison terminal, and
the existing wins (`plain_ascii`, `scrollback`, `truecolor`) widen.

Save raw runs under `.benchmark-results/<date>-<desc>/` (git-ignored) alongside a short summary.
