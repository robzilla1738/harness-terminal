#!/usr/bin/env python3
"""GUI-pane probe driver for Harness on a logged-in macOS desktop.

Launches the packaged Harness.app directly (env preserved) with an isolated
HARNESS_HOME, sizes the first window to an exact terminal grid by iterating on
`stty size` read back from inside the pane, then runs a command in that pane via
harness-cli `send` and waits for a done-file/exit marker.

Requires: logged-in windowserver session (devin console user), the app binary
path, and harness-cli in the same bundle. No product code is modified.

Usage:
  gui_probe_driver.py --app Harness.app --home DIR --grid 150x45 \
      --run "python3 Scripts/benchmarks/consumer_ack_runner.py harness out.jsonl" \
      --done out.jsonl --timeout 900
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def run(cmd, **kw):
    kw.setdefault("timeout", 30)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def osa(script):
    r = run(["osascript", "-e", script])
    return r.stdout.strip(), r.returncode, r.stderr.strip()


def window_size(proc_name="Harness"):
    out, rc, err = osa(
        f'tell application "System Events" to tell process "{proc_name}" '
        'to get size of window 1')
    if rc != 0 or not out:
        return None
    try:
        w, h = [int(x.strip()) for x in out.split(",")]
        return w, h
    except ValueError:
        return None


def window_set_size(w, h, proc_name="Harness"):
    out, rc, err = osa(
        f'tell application "System Events" to tell process "{proc_name}" '
        f'to set size of window 1 to {{{w}, {h}}}')
    return rc == 0


def window_count(proc_name="Harness"):
    out, rc, err = osa(
        f'tell application "System Events" to tell process "{proc_name}" to count windows')
    try:
        return int(out)
    except ValueError:
        return 0


def frontmost(proc_name="Harness"):
    osa(f'tell application "System Events" to set frontmost of process "{proc_name}" to true')


class GUIProbe:
    def __init__(self, app: Path, home: Path, cli: Path = None):
        self.app = app.resolve()
        self.home = home.resolve()
        self.cli = cli.resolve() if cli else self.app / "Contents/MacOS/harness-cli"
        self.env = {**os.environ, "HARNESS_HOME": str(self.home)}
        self.proc = None
        self.surface = None

    def launch(self, extra_args=None, settings=None, extra_env=None):
        """Launch detached via `open -n` so the app survives exec-shell reaping
        (~10+ min). Direct binary exec is killed by the harness watchdog."""
        self.home.mkdir(parents=True, exist_ok=True)
        if settings:
            (self.home / "settings.json").write_text(json.dumps(settings))
        argv = ["open", "-n", str(self.app), "--env", f"HARNESS_HOME={self.home}"]
        for k, v in (extra_env or {}).items():
            argv += ["--env", f"{k}={v}"]
        if extra_args:
            argv += ["--args"] + extra_args
        subprocess.run(argv, check=True)
        time.sleep(0.5)
        r = run(["pgrep", "-f", str(self.app / "Contents/MacOS/Harness")])
        self.proc = None  # detached; not our child
        return int(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None

    def wait_ready(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r = run([str(self.cli), "ping"], env=self.env, timeout=10)
            if "pong" in r.stdout:
                return True
            if self.proc and self.proc.poll() is not None:
                raise RuntimeError("Harness app exited early")
            time.sleep(0.5)
        raise TimeoutError("daemon ping timeout")

    def first_surface(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r = run([str(self.cli), "list-surfaces", "--json"], env=self.env, timeout=10)
            try:
                data = json.loads(r.stdout or "{}")
            except json.JSONDecodeError:
                data = {}
            surfaces = data.get("surfaces") or data.get("listSurfaces") or []
            if isinstance(surfaces, list) and surfaces:
                s = surfaces[0]
                self.surface = s.get("surfaceID") or s.get("id") or s.get("_0")
                if self.surface:
                    return self.surface
            time.sleep(0.5)
        raise TimeoutError("no surface appeared")

    def send(self, text):
        r = run([str(self.cli), "send", self.surface, text], env=self.env, timeout=15)
        return r.returncode == 0

    def grid_size(self, timeout=15):
        """Run `stty size` in the pane; read via capture-pane tail. Returns (cols, rows)."""
        self.send("stty size\n")
        time.sleep(0.4)
        r = run([str(self.cli), "capture-pane", self.surface], env=self.env, timeout=timeout)
        import re
        ms = re.findall(r"^\s*(\d+)\s+(\d+)\s*$", r.stdout, re.M)
        if ms:
            rows, cols = ms[-1]
            return int(cols), int(rows)
        return None

    def size_to_grid(self, cols, rows, max_iter=8):
        """Iterate window resize until the pane reports exact cols x rows."""
        last = None
        for _ in range(max_iter):
            frontmost()
            time.sleep(0.6)
            cur = self.grid_size()
            if cur == (cols, rows):
                return True
            win = window_size()
            if not cur or not win:
                time.sleep(1.0)
                continue
            c0, r0 = cur
            w0, h0 = win
            # estimate cell px; chrome ≈ win - cell*grid
            cell_w = w0 / max(1, c0)
            cell_h = h0 / max(1, r0)
            # keep titlebar/chrome delta
            chrome_w = w0 - cell_w * c0
            chrome_h = h0 - cell_h * r0
            new_w = int(chrome_w + cell_w * cols)
            new_h = int(chrome_h + cell_h * rows)
            if (new_w, new_h) == last:
                break
            last = (new_w, new_h)
            window_set_size(new_w, new_h)
            time.sleep(0.8)
        return self.grid_size() == (cols, rows)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--home", type=Path, required=True)
    p.add_argument("--grid", default=None, help="e.g. 150x45; skip sizing when omitted")
    p.add_argument("--run", default=None, help="command to run in the pane")
    p.add_argument("--done", type=Path, default=None)
    p.add_argument("--timeout", type=float, default=900)
    p.add_argument("--settings", type=Path, default=None)
    p.add_argument("--proc-out", type=Path, default=None)
    args = p.parse_args()

    probe = GUIProbe(args.app, args.home)
    settings = json.loads(args.settings.read_text()) if args.settings else None
    pid = probe.launch(settings=settings)
    print(json.dumps({"event": "launched", "pid": pid}))
    probe.wait_ready()
    surf = probe.first_surface()
    print(json.dumps({"event": "surface", "surfaceID": surf}))

    if args.grid:
        cols, rows = [int(x) for x in args.grid.split("x")]
        ok = probe.size_to_grid(cols, rows)
        print(json.dumps({"event": "grid", "target": args.grid, "reached": ok,
                          "actual": probe.grid_size()}))
        if not ok:
            sys.exit(2)

    if args.run:
        probe.send(args.run + "\n")
        if args.done:
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                if args.done.exists():
                    print(json.dumps({"event": "done", "file": str(args.done)}))
                    sys.exit(0)
                if run(["pgrep", "-f", str(probe.app / "Contents/MacOS/Harness")]).returncode != 0:
                    print(json.dumps({"event": "app_exit"}))
                    sys.exit(3)
                time.sleep(2)
            print(json.dumps({"event": "timeout"}))
            sys.exit(4)


if __name__ == "__main__":
    main()
