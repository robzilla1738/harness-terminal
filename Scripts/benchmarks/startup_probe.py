#!/usr/bin/env python3
"""Phase D: GUI launch → first-frame and → ready-prompt timing + idle CPU cost.

Per launch:
  1. `open -n Harness.app --env HARNESS_HOME=<home> --env HARNESS_STARTUP_METRICS=1`
  2. Poll <home>/logs/startup.log until `firstDrawablePresented` appears
     (its +Δms from launchStart is the internal first-frame time). Also record
     wall clock from the `open` call to seeing that line.
  3. Poll `harness-cli ping` for daemon-ready and `capture-pane` until a shell
     prompt is visible (ready-prompt wall clock).
  4. Kill the Harness GUI process (daemon/host persist -> next launch is "warm").

Cold vs warm: pass --cold-wipe to delete <home> and shutdownDaemon before a run
(first launch is cold). Then remaining launches are warm-daemon.

Idle CPU: after the last launch settle --idle-wait s, sample CPU-time deltas of
the GUI + daemon + session-host over --idle-window s via `ps -o time=`, and
optionally `powermetrics` if --powermetrics is set (sudo).

Writes JSONL rows + a summary.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def run(cmd, timeout=30, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def read_phases(log_path: Path):
    """Parse 'phase +N.Nms' lines -> {phase: ms}."""
    out = {}
    try:
        for line in log_path.read_text().splitlines():
            m = re.match(r"(\w+)\s+\+([\d.]+)ms", line.strip())
            if m:
                out[m.group(1)] = float(m.group(2))
    except OSError:
        pass
    return out


def pgrep_app(app_path: Path):
    r = run(["pgrep", "-f", str(app_path / "Contents/MacOS/Harness")])
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def cpu_time_s(pid: int):
    r = run(["ps", "-o", "time=", "-p", str(pid)], timeout=10)
    try:
        parts = r.stdout.strip().split(":")
        parts = [float(x) for x in parts]
        return parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 else parts[0] * 60 + parts[1]
    except (ValueError, IndexError):
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--home", type=Path, required=True)
    p.add_argument("--cli", type=Path, required=True)
    p.add_argument("--launches", type=int, default=30)
    p.add_argument("--cold-wipe", action="store_true", help="fresh home before run")
    p.add_argument("--idle-wait", type=float, default=30)
    p.add_argument("--idle-window", type=float, default=60)
    p.add_argument("--powermetrics", action="store_true")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--settings", type=Path, default=None)
    args = p.parse_args()

    env = {**os.environ, "HARNESS_HOME": str(args.home)}
    startup_log = args.home / "logs/startup.log"
    out = args.out.open("a", encoding="utf-8")

    def emit(row):
        out.write(json.dumps(row) + "\n")
        out.flush()

    def shutdown_daemon():
        # Only kill daemons/hosts spawned from THIS app's helper path so an
        # isolated-probe stack (different binary path) is never touched.
        helper_root = str(args.app / "Contents/Helpers")
        for pat in ("HarnessDaemon", "HarnessSessionHost"):
            for line in run(["pgrep", "-fl", pat], timeout=10).stdout.splitlines():
                if helper_root in line and line.split()[0].isdigit():
                    run(["kill", line.split()[0]], timeout=10)
        time.sleep(1)

    for pid in pgrep_app(args.app):
        run(["kill", str(pid)])
    time.sleep(1)

    if args.cold_wipe:
        shutdown_daemon()
        if args.home.exists():
            import shutil
            shutil.rmtree(args.home)
    args.home.mkdir(parents=True, exist_ok=True)
    if args.settings:
        (args.home / "settings.json").write_text(args.settings.read_text())

    first_cold = args.cold_wipe
    for i in range(args.launches):
        # truncate marker: remove old log so we know when the new launch writes it
        if startup_log.exists():
            startup_log.unlink()
        t0 = time.monotonic()
        run(["open", "-n", str(args.app), "--env", f"HARNESS_HOME={args.home}",
             "--env", "HARNESS_STARTUP_METRICS=1"], timeout=15)

        first_frame_ms = None
        first_frame_wall = None
        daemon_ready_wall = None
        prompt_wall = None
        deadline = t0 + 30
        while time.monotonic() < deadline:
            phases = read_phases(startup_log)
            if "firstDrawablePresented" in phases and first_frame_ms is None:
                first_frame_ms = phases["firstDrawablePresented"]
                first_frame_wall = (time.monotonic() - t0) * 1000
            if daemon_ready_wall is None and "daemonConnected" in phases:
                daemon_ready_wall = (time.monotonic() - t0) * 1000
                break
            time.sleep(0.05)

        # ready-prompt: ping daemon + capture-pane until prompt text appears
        cli_deadline = t0 + 45
        while time.monotonic() < cli_deadline:
            r = run([str(args.cli), "ping"], env=env, timeout=10)
            if "pong" in r.stdout:
                if daemon_ready_wall is None:
                    daemon_ready_wall = (time.monotonic() - t0) * 1000
                r2 = run([str(args.cli), "list-surfaces", "--json"], env=env, timeout=10)
                try:
                    surfaces = json.loads(r2.stdout)
                    sid = surfaces[0]["surfaceID"]
                except Exception:
                    sid = None
                if sid:
                    r3 = run([str(args.cli), "capture-pane", "--surface", sid], env=env, timeout=10)
                    if re.search(r"[~%/]>?\s*$|%\s*$|\$\s*$", r3.stdout.strip().splitlines()[-1] if r3.stdout.strip() else ""):
                        prompt_wall = (time.monotonic() - t0) * 1000
                        break
            time.sleep(0.3)

        row = {
            "type": "launch", "index": i, "daemon_state": "cold" if first_cold and i == 0 else "warm",
            "first_frame_internal_ms": first_frame_ms,
            "first_frame_wall_ms": first_frame_wall,
            "daemon_ready_wall_ms": daemon_ready_wall,
            "prompt_wall_ms": prompt_wall,
        }
        emit(row)
        for pid in pgrep_app(args.app):
            run(["kill", str(pid)])
        # wait for exit
        d = time.monotonic() + 10
        while time.monotonic() < d and pgrep_app(args.app):
            time.sleep(0.3)
        time.sleep(0.5)

    # idle CPU: settle then sample GUI+daemon+host CPU-time deltas
    time.sleep(args.idle_wait)
    targets = {}
    for pid, name in [(pid, "gui") for pid in pgrep_app(args.app)]:
        targets[pid] = name
    # daemon/host belonging to THIS app bundle (helper path), not isolated stacks
    helper_root = str(args.app / "Contents/Helpers")
    for pat, name in [("HarnessDaemon", "daemon"), ("HarnessSessionHost", "session_host")]:
        for line in run(["pgrep", "-fl", pat], timeout=10).stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0].isdigit() and helper_root in parts[1]:
                targets.setdefault(int(parts[0]), name)

    t_start = {pid: cpu_time_s(pid) for pid in targets}
    wall0 = time.monotonic()
    time.sleep(args.idle_window)
    wall1 = time.monotonic()
    ncpu = os.cpu_count()
    rows = []
    for pid, name in targets.items():
        t_end = cpu_time_s(pid)
        if t_start.get(pid) is None or t_end is None:
            continue
        used_s = t_end - t_start[pid]
        rows.append({
            "component": name, "pid": pid, "cpu_s": used_s,
            "window_s": wall1 - wall0,
            "cpu_pct_one_core": used_s / (wall1 - wall0) * 100,
            "cpu_pct_all_cores": used_s / (wall1 - wall0) / ncpu * 100,
        })
    emit({"type": "idle", "window_s": wall1 - wall0, "ncpu": ncpu, "rows": rows})

    # summary
    warm = []
    cold = []
    out.close()
    for line in args.out.read_text().splitlines():
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("type") != "launch":
            continue
        (cold if r["daemon_state"] == "cold" else warm).append(r)

    def med(v):
        v = sorted(v)
        return v[len(v) // 2] if v else None

    summary = {"type": "summary", "launches": {"cold": len(cold), "warm": len(warm)}}
    for key in ("first_frame_internal_ms", "first_frame_wall_ms", "daemon_ready_wall_ms", "prompt_wall_ms"):
        summary[f"{key}_median_warm"] = med([r[key] for r in warm if r.get(key) is not None])
        summary[f"{key}_cold"] = cold[0].get(key) if cold else None
    with args.out.open("a") as f:
        f.write(json.dumps(summary) + "\n")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
