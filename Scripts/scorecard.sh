#!/usr/bin/env bash
set -euo pipefail

# Harness vs Ghostty comparative scorecard — orchestration + reporting over instrumentation
# that already exists (StartupMetrics' startup.log, Scripts/benchmarks/terminal_stress_runner.py,
# FrameSignposter via Scripts/measure-fluidity.sh, powermetrics, footprint(1)).
#
# Numbers are RECEIPTS, never CI gates (a prior deep dive killed latency thresholds as gates:
# run-to-run noise is 50-100x above signal). Run every section on quiet, plugged-in owner
# hardware and commit the results to docs/SCORECARD.md.
#
# Sections (run independently; `all` runs the non-interactive ones):
#   cold-start     N launches of the app; per-phase deltas from logs/startup.log.
#                  Ghostty side: wall-clock to first on-screen window (asymmetry documented).
#   throughput     PTY drain MB/s via terminal_stress_runner.py. Run INSIDE each terminal:
#                    Scripts/scorecard.sh throughput harness    # inside a Harness pane
#                    Scripts/scorecard.sh throughput ghostty    # inside a Ghostty window
#   idle-power     60s powermetrics: CPU ms/s + wakeups. Harness app + HarnessDaemon are
#                  summed (two-process architecture stated, never hidden). Needs sudo.
#   memory         RSS/footprint after a scripted 1M-line scroll session. Run INSIDE each
#                  terminal:  Scripts/scorecard.sh memory harness
#   input-latency  Harness-only FrameSignposter percentiles via Scripts/measure-fluidity.sh
#                  (comparative across Harness builds; Ghostty has no signposts — use an
#                  external camera/typometer for a cross-terminal number).
#   report         Collate $SCORECARD_OUT/*.jsonl + *.txt into a markdown table.
#   --dry-run      Self-check: validates helper presence + the startup.log parser against a
#                  synthetic fixture. Runs on Linux CI too (no macOS-only calls).
#
# Output dir: $SCORECARD_OUT (default /tmp/harness-scorecard). Results are plain text/JSONL
# so `report` (and humans) can diff them.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SCORECARD_OUT:-/tmp/harness-scorecard}"
RUNNER="$REPO_ROOT/Scripts/benchmarks/terminal_stress_runner.py"
LAUNCHES="${SCORECARD_LAUNCHES:-10}"
POWER_SECONDS="${SCORECARD_POWER_SECONDS:-60}"
MEMORY_LINES="${SCORECARD_MEMORY_LINES:-1000000}"

usage() { sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

note() { printf '\033[1m[scorecard]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[scorecard] error:\033[0m %s\n' "$*" >&2; exit 1; }

# Parse a startup.log ("phase +12.3ms" per line, truncated per launch) and print
# "phase<TAB>ms" rows. Pure text processing so the --dry-run fixture exercises the exact
# code path the real cold-start section uses.
parse_startup_log() {
    awk '/^[A-Za-z]+ \+[0-9.]+ms$/ { phase=$1; ms=$2; sub(/^\+/, "", ms); sub(/ms$/, "", ms); print phase "\t" ms }' "$1"
}

self_check() {
    note "dry run: validating helpers + parsers"
    [ -f "$RUNNER" ] || die "missing $RUNNER"
    command -v python3 >/dev/null || die "python3 not on PATH"
    [ -x "$REPO_ROOT/Scripts/measure-fluidity.sh" ] || die "Scripts/measure-fluidity.sh missing or not executable"

    local fixture parsed
    fixture="$(mktemp)"
    cat > "$fixture" <<'EOF'
launchStart +0.0ms
firstWindow +18.2ms
firstSurfaceAttached +24.9ms
firstDrawablePresented +41.5ms
daemonConnected +88.0ms
firstSnapshot +93.4ms
EOF
    parsed="$(parse_startup_log "$fixture" | awk -F'\t' '$1 == "firstDrawablePresented" { print $2 }')"
    rm -f "$fixture"
    [ "$parsed" = "41.5" ] || die "startup.log parser self-check failed (got '$parsed', want '41.5')"

    if [ "$(uname)" = "Darwin" ]; then
        command -v powermetrics >/dev/null || note "warning: powermetrics not found (idle-power needs it)"
        command -v footprint >/dev/null || note "warning: footprint not found (memory falls back to ps RSS)"
        [ -d "/Applications/Ghostty.app" ] || command -v ghostty >/dev/null \
            || note "warning: Ghostty not installed — sections degrade to Harness-only"
    else
        note "non-macOS host: only --dry-run and report are usable here"
    fi
    note "dry run OK"
}

harness_home() { echo "${HARNESS_HOME:-$HOME/Library/Application Support/Harness}"; }

find_harness_app() {
    local candidates=(
        "$REPO_ROOT/.harness-preview/HarnessPreview.app"
        "/Applications/Harness.app"
    )
    for c in "${candidates[@]}"; do
        [ -d "$c" ] && { echo "$c"; return; }
    done
    die "no Harness app found (run 'make preview' or install the release app)"
}

# The app and its HARNESS_HOME must be derived together: the preview's Info.plist points it
# at .harness-preview/, so its startup.log lives there — watching the release home for a
# preview launch (or vice versa) reads the wrong log.
home_for_app() {
    case "$1" in
        "$REPO_ROOT/.harness-preview/"*) echo "$REPO_ROOT/.harness-preview" ;;
        *) harness_home ;;
    esac
}

# Target processes by bundle path, never by app name: `tell application "Harness" to quit`
# resolves by NAME and can kill the user's live terminal instead of the launched instance.
app_running() { pgrep -f "$1/Contents/MacOS/" >/dev/null 2>&1; }
quit_app() { pkill -f "$1/Contents/MacOS/" 2>/dev/null || true; }

cold_start() {
    [ "$(uname)" = "Darwin" ] || die "cold-start runs on macOS only"
    mkdir -p "$OUT_DIR"
    local app log result
    app="$(find_harness_app)"
    log="$(home_for_app "$app")/logs/startup.log"
    result="$OUT_DIR/cold-start-harness.txt"
    # Never launch-and-quit a bundle that already has a live instance — quitting would take
    # the user's terminal sessions with it.
    app_running "$app" && die "cold-start: $app is already running — quit it first (refusing to kill live sessions)"
    : > "$result"
    note "cold start: $LAUNCHES launches of $app (phase deltas from $log)"
    for i in $(seq 1 "$LAUNCHES"); do
        rm -f "$log"
        # `open` strips the caller's environment (see Scripts/preview.sh) — the flag must
        # travel via --env or StartupMetrics never arms and the log never appears.
        open -n "$app" --env HARNESS_STARTUP_METRICS=1
        # Wait for the LAST phase (firstSnapshot) so the daemonConnected/firstSnapshot
        # medians aren't dropped by parsing right after the first present.
        for _ in $(seq 1 100); do
            [ -f "$log" ] && grep -q firstSnapshot "$log" && break
            sleep 0.1
        done
        if [ -f "$log" ]; then
            parse_startup_log "$log" | sed "s/^/run$i\t/" >> "$result"
        else
            echo "run$i	MISSING	startup.log never appeared" >> "$result"
        fi
        quit_app "$app"
        sleep 1
    done
    note "harness cold-start phases -> $result"

    # Ghostty: no phase instrumentation we can read — measure wall clock from `open` to the
    # first on-screen window (a DIFFERENT, coarser clock; the asymmetry is part of the report).
    if [ -d "/Applications/Ghostty.app" ] && app_running "/Applications/Ghostty.app"; then
        note "Ghostty is already running — skipping its cold-start half (refusing to quit your live instance)"
    elif [ -d "/Applications/Ghostty.app" ]; then
        local gresult="$OUT_DIR/cold-start-ghostty.txt"
        : > "$gresult"
        note "cold start: $LAUNCHES launches of Ghostty (wall clock to first window)"
        for i in $(seq 1 "$LAUNCHES"); do
            local t0 t1
            t0=$(python3 -c 'import time; print(time.time_ns())')
            open -n "/Applications/Ghostty.app"
            for _ in $(seq 1 200); do
                if python3 - <<'PY'
import subprocess, sys
out = subprocess.run(["osascript", "-e",
    'tell application "System Events" to count windows of process "Ghostty"'],
    capture_output=True, text=True)
sys.exit(0 if out.stdout.strip().isdigit() and int(out.stdout.strip()) > 0 else 1)
PY
                then break; fi
                sleep 0.05
            done
            t1=$(python3 -c 'import time; print(time.time_ns())')
            echo "run$i	wallToWindow	$(( (t1 - t0) / 1000000 ))ms" >> "$gresult"
            osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
            sleep 1
        done
        note "ghostty cold-start wall clock -> $gresult"
    else
        note "Ghostty not installed — skipping its cold-start half"
    fi
}

throughput() {
    local terminal="${1:-}"
    [ -n "$terminal" ] || die "usage: scorecard.sh throughput <harness|ghostty|...> (run INSIDE that terminal)"
    mkdir -p "$OUT_DIR"
    local result="$OUT_DIR/throughput-$terminal.jsonl" done_file="$OUT_DIR/throughput-$terminal.done"
    rm -f "$result" "$done_file"
    note "throughput: drain workloads into THIS terminal ($terminal) -> $result"
    note "match the terminals first: same font/size, opacity 1, no blur, 0 padding, 160x48"
    python3 "$RUNNER" "$terminal" "$result" "$done_file"
    note "done. Re-run inside the other terminal, then: scorecard.sh report"
}

idle_power() {
    [ "$(uname)" = "Darwin" ] || die "idle-power runs on macOS only"
    mkdir -p "$OUT_DIR"
    local result="$OUT_DIR/idle-power.txt"
    note "idle power: ${POWER_SECONDS}s powermetrics sample (needs sudo). Leave both apps idle:"
    note "  Harness: 4 panes open, one window unfocused. Ghostty: a comparable window."
    sudo powermetrics --samplers tasks --show-process-energy \
        -i $(( POWER_SECONDS * 1000 )) -n 1 2>/dev/null \
        | grep -E "Name|Harness|HarnessDaemon|Ghostty|ALL_TASKS" > "$result" || true
    note "idle power (sum Harness + HarnessDaemon — the two-process split is the architecture) -> $result"
    cat "$result" >&2
}

memory() {
    local terminal="${1:-}"
    [ -n "$terminal" ] || die "usage: scorecard.sh memory <harness|ghostty> (run INSIDE that terminal)"
    mkdir -p "$OUT_DIR"
    local result="$OUT_DIR/memory-$terminal.txt"
    note "memory: scrolling $MEMORY_LINES lines through this terminal, then sampling the host app"
    python3 - "$MEMORY_LINES" <<'PY'
import sys
n = int(sys.argv[1])
line = ("x" * 118) + "\n"
out = sys.stdout
for i in range(n):
    out.write(f"{i:08d} {line}")
out.flush()
PY
    sleep 2
    {
        echo "terminal: $terminal  lines: $MEMORY_LINES  date: $(date -u +%FT%TZ)"
        if command -v footprint >/dev/null; then
            case "$terminal" in
                harness) footprint Harness HarnessDaemon 2>/dev/null || true ;;
                *) footprint Ghostty 2>/dev/null || true ;;
            esac
        fi
        ps axo rss,comm | grep -Ei "harness|ghostty" | grep -v grep || true
    } > "$result"
    note "memory sample -> $result"
    cat "$result" >&2
}

input_latency() {
    [ "$(uname)" = "Darwin" ] || die "input-latency runs on macOS only"
    mkdir -p "$OUT_DIR"
    note "input-to-photon: Harness-side FrameSignposter percentiles (PREVIEW_SIGNPOSTS=1 make preview first)"
    note "Ghostty exposes no equivalent probe — use a camera/typometer for a cross-terminal number."
    "$REPO_ROOT/Scripts/measure-fluidity.sh" "${1:-4}" | tee "$OUT_DIR/input-latency-harness.txt"
}

median_of() { sort -n | awk '{ a[NR] = $1 } END { if (NR) print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }'; }

report() {
    [ -d "$OUT_DIR" ] || die "no results at $OUT_DIR — run some sections first"
    echo "## Scorecard results ($(date -u +%F), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m))"
    echo
    if [ -f "$OUT_DIR/cold-start-harness.txt" ]; then
        echo "### Cold start"
        echo
        echo "| terminal | metric | median |"
        echo "|---|---|---|"
        local phases="firstWindow firstDrawablePresented daemonConnected firstSnapshot"
        for phase in $phases; do
            local med
            med="$(awk -F'\t' -v p="$phase" '$2 == p { print $3 }' "$OUT_DIR/cold-start-harness.txt" | median_of)"
            [ -n "$med" ] && echo "| Harness | launchStart -> $phase | ${med}ms |"
        done
        if [ -f "$OUT_DIR/cold-start-ghostty.txt" ]; then
            local gmed
            gmed="$(awk -F'\t' '$2 == "wallToWindow" { gsub(/ms/, "", $3); print $3 }' "$OUT_DIR/cold-start-ghostty.txt" | median_of)"
            [ -n "$gmed" ] && echo "| Ghostty | open -> first window (wall clock — coarser probe) | ${gmed}ms |"
        fi
        echo
    fi
    local f
    for f in "$OUT_DIR"/throughput-*.jsonl; do
        [ -e "$f" ] || continue
        echo "### Throughput ($(basename "$f" .jsonl | sed 's/throughput-//'))"
        echo
        echo "| workload | MB/s |"
        echo "|---|---|"
        python3 - "$f" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for r in rows:
    if r.get("error"):
        print(f"| {r['benchmark']} | ERROR: {r['error']} |")
    else:
        print(f"| {r['benchmark']} | {r['mbps']} |")
PY
        echo
    done
    for f in "$OUT_DIR"/idle-power.txt "$OUT_DIR"/memory-*.txt "$OUT_DIR"/input-latency-harness.txt; do
        [ -e "$f" ] || continue
        echo "### $(basename "$f" .txt)"
        echo
        echo '```'
        cat "$f"
        echo '```'
        echo
    done
    echo "_Generated by Scripts/scorecard.sh — paste into docs/SCORECARD.md and commit._"
}

cmd="${1:-}"
case "$cmd" in
    --dry-run) self_check ;;
    cold-start) cold_start ;;
    throughput) shift; throughput "${1:-}" ;;
    idle-power) idle_power ;;
    memory) shift; memory "${1:-}" ;;
    input-latency) shift; input_latency "${1:-4}" ;;
    report) report ;;
    all)
        cold_start
        idle_power
        note "now run 'throughput'/'memory' inside each terminal, 'input-latency' with the preview up, then 'report'"
        ;;
    *) usage; exit 1 ;;
esac
