#!/usr/bin/env python3
"""
compare_benchmarks.py — regression gate for the HarnessBenchmarks JSON-line output.

The benchmark suite (Tests/HarnessBenchmarks, HARNESS_BENCHMARKS=1) prints one JSON object
per measurement: {"benchmark": "<name>", "nanos": <int>, ...extra fields}. This script turns
those lines into an enforceable gate:

  # Record a baseline (run on the hardware class you gate on; commit the file):
  make bench 2>&1 | python3 Scripts/benchmarks/compare_benchmarks.py --record benchmark-baselines.json

  # Compare a run against the committed baseline (exit 1 on regression):
  make bench 2>&1 | python3 Scripts/benchmarks/compare_benchmarks.py --baseline benchmark-baselines.json

Policy:
  - A benchmark regresses when nanos > baseline * (1 + --tolerance) (default 15%, generous
    enough for CI-runner noise; tighten per-benchmark later if variance allows).
  - New benchmarks (no baseline entry) are reported, never fail — record them deliberately.
  - Benchmarks missing from the run (filtered/skipped) are reported, never fail.
  - Improvements beyond the tolerance are flagged as "update the baseline" hints.

The baseline file maps name → {"nanos": int, plus any informational fields from the run}.
Re-record on intentional performance changes in the same PR, so the diff documents the new
expectation alongside the change that caused it.
"""
import argparse
import json
import sys


def parse_benchmark_lines(stream):
    """Extract {"benchmark": ...} JSON objects from mixed test output."""
    results = {}
    for line in stream:
        line = line.strip()
        # Benchmark lines are bare JSON objects; everything else (xctest chatter) is skipped.
        if not (line.startswith("{") and '"benchmark"' in line):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = obj.get("benchmark")
        nanos = obj.get("nanos")
        if isinstance(name, str) and isinstance(nanos, (int, float)):
            # Last result wins if a benchmark prints multiple times (e.g. warm/cold variants
            # should use distinct names; the suite already does).
            results[name] = obj
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--record", metavar="FILE", help="write the run's results as the new baseline")
    mode.add_argument("--baseline", metavar="FILE", help="compare the run against this baseline")
    ap.add_argument("--tolerance", type=float, default=0.15,
                    help="allowed fractional slowdown before failing (default 0.15 = 15%%)")
    ap.add_argument("--input", metavar="FILE", default="-",
                    help="benchmark output to parse (default: stdin)")
    args = ap.parse_args()

    stream = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    results = parse_benchmark_lines(stream)
    if not results:
        print("compare_benchmarks: no benchmark JSON lines found in input", file=sys.stderr)
        print("(did the run set HARNESS_BENCHMARKS=1?)", file=sys.stderr)
        return 2

    if args.record:
        with open(args.record, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"recorded {len(results)} benchmark baselines → {args.record}")
        return 0

    try:
        with open(args.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
    except FileNotFoundError:
        print(f"compare_benchmarks: baseline {args.baseline} not found — run --record first "
              "(treating as advisory, exit 0)", file=sys.stderr)
        for name, obj in sorted(results.items()):
            print(f"  NEW  {name}: {obj['nanos']:,} ns")
        return 0

    regressions, improvements, new, missing = [], [], [], []
    for name, obj in sorted(results.items()):
        base = baseline.get(name)
        if base is None:
            new.append(name)
            continue
        base_nanos = base["nanos"]
        ratio = obj["nanos"] / max(base_nanos, 1)
        if ratio > 1 + args.tolerance:
            regressions.append((name, base_nanos, obj["nanos"], ratio))
        elif ratio < 1 - args.tolerance:
            improvements.append((name, base_nanos, obj["nanos"], ratio))
    for name in sorted(baseline):
        if name not in results:
            missing.append(name)

    print(f"compared {len(results)} benchmarks against {args.baseline} (tolerance ±{args.tolerance:.0%})")
    for name, base, now, ratio in regressions:
        print(f"  REGRESSION  {name}: {base:,} → {now:,} ns ({ratio:.2f}x)")
    for name, base, now, ratio in improvements:
        print(f"  improved    {name}: {base:,} → {now:,} ns ({ratio:.2f}x) — consider re-recording the baseline")
    for name in new:
        print(f"  new         {name}: {results[name]['nanos']:,} ns (not in baseline — record to start gating)")
    for name in missing:
        print(f"  missing     {name}: in baseline but not in this run (filtered or skipped)")
    if not (regressions or improvements or new or missing):
        print("  all benchmarks within tolerance")

    if regressions:
        print(f"\n{len(regressions)} regression(s) beyond {args.tolerance:.0%} — failing", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
