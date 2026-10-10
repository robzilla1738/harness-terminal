#!/usr/bin/env python3
"""Session scaling memory probe for Harness.

Mirrors the Rex Sep-2 / Oct-7 reference shapes, measured against the real daemon:

  * Server-side components measured separately: HarnessSessionHost (PTY masters,
    shells, parser/observation state, retained replay), HarnessDaemon (app services),
    shells (one per surface), and optional attached clients (subscribe stream / GUI).
    phys_footprint and RSS are recorded as DISTINCT metrics (sudo-free footprint
    falls back to RSS-only rows, labeled).
  * Fill shape: 80x24 surfaces filled with 10,000 numbered 72-column prose lines
    (Rex Sep-2 shape). The C4 attempt uses 1,000-line fills (Rex Oct-7 shape).
  * States: connected (live output subscriber), disconnected, and idle>60 s
    (session host parks idle panes; park verified via stats where reported).

Sampling: per count, `recreate` independent daemon recreations; each recreation
settles `settle` seconds, then `samples` footprint snapshots spaced 5 s apart.
Memory rows are per-component sums; the "server_total" field is
sessionhost + daemon + shells with the shared-page caveat noted in the report.

Stop conditions (C4): footprint(sum) > --mem-ceiling-gib, any createSurface stall
>300 s, or a fork/exec failure -> stop and report largest completed count.

Usage:
  memory_scaling_probe.py --bin-dir .build/release --work-dir DIR \
      --counts 1,10,50,100 --fill-lines 10000 --recreate 5 --out mem.jsonl
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shlex
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from latency_probe import Client, OutputStream, read_exact  # noqa: E402

FILL_SENTINEL = "FILL_DONE"


def fill_command(lines: int, cols: int = 72) -> str:
    """10,000 numbered ~72-column prose lines via awk (deterministic, portable)."""
    # "nnnnnn the quick brown fox jumps over the lazy dog packs my five dozen q" ≈72 cols
    return (
        "awk 'BEGIN{for(i=1;i<=%d;i++) printf \"%%06d the quick brown fox jumps over the lazy dog packs five dozen%%03d\\n\", i, i%%1000}'"
        " ; printf '%%s\\n' " % lines + shlex.quote(FILL_SENTINEL) + "\n"
    )


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def footprint_bytes(pid: int):
    """Return (phys_footprint_bytes_or_None, rss_bytes_or_None)."""
    phys = None
    try:
        r = run(["sudo", "-n", "footprint", "-p", str(pid)], timeout=15)
        if r.returncode == 0:
            # Auxiliary data line: "    phys_footprint: 5681 KB" (unit varies: B/KB/MB/GB).
            # Skip *_peak and related keys by anchoring at line start.
            for line in (r.stdout + r.stderr).splitlines():
                mm = re.search(r"^\s*phys_footprint:\s*(\d[\d,]*(?:\.\d+)?)\s*(B|KB|MB|GB)\s*$", line)
                if mm:
                    v, u = float(mm.group(1).replace(",", "")), mm.group(2)
                    phys = int(v * {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[u])
    except Exception:
        pass
    rss = None
    r = run(["ps", "-o", "rss=", "-p", str(pid)], timeout=10)
    try:
        rss = int(r.stdout.strip()) * 1024
    except ValueError:
        pass
    return phys, rss


def find_pids(pattern: str):
    r = run(["pgrep", "-fl", pattern], timeout=10)
    out = []
    for line in r.stdout.splitlines():
        parts = line.split(None, 1)
        if parts and parts[0].isdigit():
            out.append((int(parts[0]), parts[1] if len(parts) > 1 else ""))
    return out


def children_of(pid: int):
    r = run(["pgrep", "-P", str(pid)], timeout=10)
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def component_pids(owner_pid: int):
    """Classify the isolated stack by ancestry from the spawned supervisor PID.

    The spawned `HarnessDaemon` binary execs as HarnessSessionHost (the stable
    supervisor owning PTYs/shells); its children are the app-services
    HarnessDaemon plus one shell per surface. A concurrently running GUI stack
    is never mixed in because only this owner's children are classified."""
    comps = {"session_host": [owner_pid], "daemon": [], "shells": [], "other": []}
    for pid in children_of(owner_pid):
        cmd = run(["ps", "-o", "comm=", "-p", str(pid)], timeout=10).stdout.strip()
        if "HarnessDaemon" in cmd:
            comps["daemon"].append(pid)
        elif "HarnessSessionHost" in cmd:
            comps["session_host"].append(pid)
        else:
            comps["shells"].append(pid)
    return comps


def sample_memory(comps, extra_clients=None, footprint_limit=500):
    """Sum per-component memory. phys_footprint (sudo footprint) and RSS are
    distinct metrics; at pid totals above `footprint_limit`, footprint calls are
    skipped for speed and phys_bytes is left null (labeled)."""
    row = {}
    total = 0
    total_pids = sum(len(p) for p in comps.values()) + sum(len(p) for p in (extra_clients or {}).values())
    use_footprint = total_pids <= footprint_limit
    def sum_mem(pids):
        phys_sum = rss_sum = 0
        if use_footprint:
            for pid in pids:
                phys, rss = footprint_bytes(pid)
                phys_sum += phys or 0
                rss_sum += rss or 0
        else:
            for pid in pids:
                r = run(["ps", "-o", "rss=", "-p", str(pid)], timeout=10)
                try:
                    rss_sum += int(r.stdout.strip()) * 1024
                except ValueError:
                    pass
        return phys_sum, rss_sum

    for name, pids in comps.items():
        phys_sum, rss_sum = sum_mem(pids)
        row[name] = {"pids": len(pids), "phys_bytes": phys_sum or None, "rss_bytes": rss_sum or None}
        total += rss_sum
    if extra_clients:
        for name, pids in extra_clients.items():
            phys_sum, rss_sum = sum_mem(pids)
            row[name] = {"pids": len(pids), "phys_bytes": phys_sum or None, "rss_bytes": rss_sum or None}
    row["phys_footprint_sampled"] = use_footprint
    row["server_total_rss_bytes"] = (
        (row.get("session_host", {}).get("rss_bytes") or 0)
        + (row.get("daemon", {}).get("rss_bytes") or 0)
        + (row.get("shells", {}).get("rss_bytes") or 0)
    )
    row["server_total_phys_bytes"] = (
        (row.get("session_host", {}).get("phys_bytes") or 0)
        + (row.get("daemon", {}).get("phys_bytes") or 0)
        + (row.get("shells", {}).get("phys_bytes") or 0)
    ) or None
    if not use_footprint:
        row["server_total_phys_bytes"] = None
    return row


def wait_quiet(client, surface_ids, timeout=600):
    """Wait until every surface has printed FILL_SENTINEL (verified via capturePane)."""
    deadline = time.monotonic() + timeout
    pending = set(surface_ids)
    while pending and time.monotonic() < deadline:
        for sid in list(pending):
            try:
                resp = client.request("capturePane", {"surfaceID": sid, "includeScrollback": False}, timeout=20)
                text = json.dumps(resp)
                if FILL_SENTINEL in text:
                    pending.discard(sid)
            except Exception:
                pass
        if pending:
            time.sleep(0.5)
    return sorted(pending)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin-dir", type=Path, required=True)
    p.add_argument("--work-dir", type=Path, required=True)
    p.add_argument("--counts", default="1,10,50,100")
    p.add_argument("--fill-lines", type=int, default=10000)
    p.add_argument("--recreate", type=int, default=5)
    p.add_argument("--settle", type=float, default=60.0)
    p.add_argument("--samples", type=int, default=5)
    p.add_argument("--sample-interval", type=float, default=5.0)
    p.add_argument("--mem-ceiling-gib", type=float, default=12.0)
    p.add_argument("--park-wait", type=float, default=100.0)
    p.add_argument("--attempt-1000", action="store_true")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    daemon = args.bin_dir.resolve() / "HarnessDaemon"
    counts = [int(c) for c in args.counts.split(",") if c]
    if args.attempt_1000:
        counts.append(1000)
    out = args.out.open("a", encoding="utf-8")

    def emit(row):
        out.write(json.dumps(row) + "\n")
        out.flush()
        print(json.dumps(row)[:400], flush=True)

    env = {**os.environ, "SHELL": "/bin/sh"}

    for count in counts:
        for recreation in range(args.recreate if count < 1000 else 1):
            root = Path(args.work_dir) / f"mem-{count}-{recreation}"
            root.mkdir(parents=True, exist_ok=True)
            env_i = {**env, "HARNESS_HOME": str(root)}
            with (root / "daemon.log").open("ab") as log:
                owner = subprocess.Popen([str(daemon)], env=env_i, stdin=subprocess.DEVNULL,
                                         stdout=log, stderr=log)
                client = Client(root / "harness.sock")
                try:
                    deadline = time.monotonic() + 60
                    while True:
                        try:
                            if "pong" in client.request("ping", timeout=5):
                                break
                        except OSError:
                            pass
                        if owner.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError("daemon failed to start")
                        time.sleep(0.05)

                    baseline = sample_memory(component_pids(owner.pid))
                    emit({"type": "baseline", "count": count, "recreation": recreation, **baseline})

                    create_start = time.monotonic_ns()
                    surfaces = []
                    stalled = False
                    for i in range(count):
                        try:
                            sid = client.request("createSurface",
                                                 {"cwd": str(root), "shell": "/bin/sh"},
                                                 timeout=60)["surfaceID"]["_0"]
                            surfaces.append(sid)
                        except Exception as exc:
                            emit({"type": "create_failure", "count": count,
                                  "recreation": recreation, "at": i, "error": str(exc)})
                            stalled = True
                            break
                    create_ns = time.monotonic_ns() - create_start
                    emit({"type": "created", "count": count, "recreation": recreation,
                          "created": len(surfaces), "create_ns": create_ns, "stalled": stalled})
                    if stalled:
                        break

                    # Empty-state sample before fill
                    comps = component_pids(owner.pid)
                    emit({"type": "empty", "count": count, "recreation": recreation,
                          **sample_memory(comps)})

                    # Fill
                    fill_start = time.monotonic_ns()
                    fill_lines = args.fill_lines if count < 1000 else 1000
                    for sid in surfaces:
                        client.request("send", {"surfaceID": sid, "text": fill_command(fill_lines)})
                    pending = wait_quiet(client, surfaces)
                    fill_ns = time.monotonic_ns() - fill_start
                    emit({"type": "filled", "count": count, "recreation": recreation,
                          "fill_ns": fill_ns, "unverified_surfaces": len(pending),
                          "fill_lines_each": fill_lines})

                    # Connected state (one live subscriber on first surface)
                    conn_stream = OutputStream(root / "harness.sock", surfaces[0])
                    time.sleep(args.settle)
                    conn_rows = []
                    for s in range(args.samples):
                        conn_rows.append(sample_memory(component_pids(owner.pid)))
                        if s < args.samples - 1:
                            time.sleep(args.sample_interval)
                    emit({"type": "connected", "count": count, "recreation": recreation,
                          "settle_s": args.settle, "samples": conn_rows})
                    conn_stream.connection.close()

                    # Disconnected
                    disc_rows = [sample_memory(component_pids(owner.pid))]
                    emit({"type": "disconnected", "count": count, "recreation": recreation,
                          "samples": disc_rows})

                    # Idle>60s park state
                    if count <= 100:
                        time.sleep(args.park_wait)
                        park_row = sample_memory(component_pids(owner.pid))
                        stats = {}
                        try:
                            stats = client.request("daemonStats", timeout=20)
                        except Exception:
                            pass
                        emit({"type": "parked", "count": count, "recreation": recreation,
                              "wait_s": args.park_wait, **park_row,
                              "daemonStats_present": bool(stats)})

                    # memory ceiling check for big counts
                    st = sample_memory(component_pids(owner.pid))["server_total_rss_bytes"] or 0
                    if st > args.mem_ceiling_gib * (1024 ** 3):
                        emit({"type": "mem_ceiling_stop", "count": count,
                              "recreation": recreation, "server_total_rss_bytes": st})
                        break
                finally:
                    try:
                        client.request("shutdownDaemon", {"requireEmpty": False}, timeout=15)
                    except Exception:
                        pass
                    try:
                        owner.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        owner.terminate()
                        owner.wait(timeout=5)

            # 1000 only attempts once
            if count == 1000:
                break
    out.close()


if __name__ == "__main__":
    main()
