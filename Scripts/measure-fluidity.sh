#!/usr/bin/env bash
set -euo pipefail

# On-hardware fluidity measurement: drives a real resize drag and a scroll fling over the running
# Harness preview window with CGEvents while tailing the FrameSignposter percentile lines from the
# unified log. The headless analogue (no real window/GPU contention) is
# `HARNESS_BENCHMARKS=1 swift test --filter FluidityBenchmarks`.
#
# Usage:
#   PREVIEW_SIGNPOSTS=1 make preview        # launch the preview with signposts on
#   Scripts/measure-fluidity.sh [seconds]   # seconds per phase, default 4
#
# Requires Accessibility permission for the terminal running this script (CGEvent posting).
# Read the output: one "present µs p50/p95 …" line per 120 frames; the `schedule` column is the
# transaction-synchronized wait (live resize only), `drawableWait` the vsync/pool stall.

DUR="${1:-4}"
# BSD mktemp requires the X run at the END of the template.
LOG="$(mktemp /tmp/harness-fluidity.XXXXXX)"

log stream --predicate 'subsystem == "com.robert.harness"' --style compact > "$LOG" &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT
sleep 1

swift - "$DUR" <<'SWIFT'
import AppKit
import CoreGraphics

let dur = Double(CommandLine.arguments.dropFirst().first ?? "4") ?? 4

// Find the frontmost Harness window (preview or release) via the window list.
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
      let win = info.first(where: { dict in
          (dict[kCGWindowOwnerName as String] as? String)?.contains("Harness") == true
              && (dict[kCGWindowLayer as String] as? Int) == 0
      }),
      let boundsDict = win[kCGWindowBounds as String] as? [String: CGFloat],
      let pid = win[kCGWindowOwnerPID as String] as? pid_t
else {
    FileHandle.standardError.write(Data("error: no on-screen Harness window found — launch the preview first.\n".utf8))
    exit(1)
}
let bounds = CGRect(
    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
)
NSRunningApplication(processIdentifier: pid)?.activate()
usleep(300_000)

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

// Phase 1 — resize drag: grab the right edge and sweep the width with a sine, ~120 steps/s.
let edge = CGPoint(x: bounds.maxX - 2, y: bounds.midY)
print("resize drag (\(Int(dur))s) on window \(Int(bounds.width))x\(Int(bounds.height))…")
post(.leftMouseDown, at: edge)
usleep(50_000)
let steps = Int(dur * 120)
for i in 0 ..< steps {
    let phase = Double(i) / 120.0
    let dx = CGFloat(150 * sin(phase * 2 * .pi / 1.5)) // ±150px sweep, 1.5s period
    post(.leftMouseDragged, at: CGPoint(x: edge.x + dx, y: edge.y))
    usleep(8_300) // ~120Hz
}
post(.leftMouseUp, at: edge)
usleep(500_000)

// Phase 2 — scroll fling: pixel-precise wheel deltas with momentum-style decay over the content.
let center = CGPoint(x: bounds.midX, y: bounds.midY)
post(.mouseMoved, at: center)
usleep(100_000)
print("scroll fling (\(Int(dur))s)…")
let scrollSteps = Int(dur * 120)
for i in 0 ..< scrollSteps {
    let t = Double(i) / Double(scrollSteps)
    let burst = sin(t * 6 * .pi) // alternate direction a few times across the phase
    let magnitude = 40.0 * (1.0 - t) + 4.0 // decaying fling
    let delta = Int32((burst >= 0 ? 1.0 : -1.0) * magnitude)
    if let ev = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
        wheel1: delta, wheel2: 0, wheel3: 0
    ) {
        ev.location = center
        ev.post(tap: .cghidEventTap)
    }
    usleep(8_300)
}
print("done")
SWIFT

sleep 2
kill "$LOG_PID" 2>/dev/null || true
trap - EXIT

echo
echo "=== FrameSignposter percentile lines ==="
grep -E "present µs" "$LOG" || echo "(none captured — is the app running with signposts on? PREVIEW_SIGNPOSTS=1 make preview)"
echo
echo "Full log: $LOG"
