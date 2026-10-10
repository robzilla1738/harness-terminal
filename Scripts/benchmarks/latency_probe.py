#!/usr/bin/env python3
"""Shell command→response latency through the real service/PTY path.

Runs an isolated HarnessDaemon (session host owns the surface), then probes:
  send "printf '\\nMK_<i>\\n'" to a /bin/sh surface and wait until the unique
marker bytes appear on that surface's subscribeSurfaceOutput stream.

Boundary: daemon socket client -> PTY write -> kernel -> shell -> PTY read ->
session host -> output stream. This is the "shell round trip" class of latency
(same event class as Rex's published Oct-7 number) — it does NOT include GUI
parse/render/present and is not input-to-photon latency.

Variants:
  --variant persistent : one client connection drives all probes (send request per probe)
  --variant oneshot    : each probe spawns `harness-cli send` (process exec+connect
                         included; isolates CLI-launch cost)
  --variant echo       : like persistent but sends a single keystroke `e` and waits
                         for the tty echo byte (in-band echo RTT)

Load: --load N spawns N extra surfaces running a `yes`-style flood during probing.

Output: JSONL per probe {probe, variant, send_ns, recv_ns, latency_ns} plus a
summary record {type:"summary", count, p50, p95, p99, errors, timeouts}.

Usage: latency_probe.py --bin-dir .build/release --work-dir DIR --probes 10000
       --variant persistent --load 0 --out results.jsonl
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time


def read_exact(connection, count, deadline):
    result = bytearray()
    while len(result) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("read deadline")
        ready, _, _ = select.select([connection], [], [], remaining)
        if not ready:
            raise TimeoutError("read deadline")
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise RuntimeError("short read")
        result.extend(chunk)
    return bytes(result)


class Client:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def request(self, method, values=None, timeout=20.0):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(timeout)
            connection.connect(str(self.sock_path))
            data = json.dumps({"request": {method: values or {}}}).encode()
            connection.sendall(struct.pack(">I", len(data)) + data)
            reply_len = struct.unpack(">I", read_exact(connection, 4, time.monotonic() + timeout))[0]
            return json.loads(read_exact(connection, reply_len, time.monotonic() + timeout))["response"]


class OutputStream:
    """subscribeSurfaceOutput stream reader: yields (monotonic_ns, payload_bytes)."""

    def __init__(self, sock_path, surface_id):
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(30)
        self.connection.connect(str(sock_path))
        data = json.dumps({"request": {"subscribeSurfaceOutput": {"surfaceID": surface_id, "label": "latency-probe"}}}).encode()
        self.connection.sendall(struct.pack(">I", len(data)) + data)
        # subscription ack frame (JSON)
        reply_len = struct.unpack(">I", read_exact(self.connection, 4, time.monotonic() + 30))[0]
        read_exact(self.connection, reply_len, time.monotonic() + 30)
        self.connection.setblocking(False)
        self.buffer = bytearray()

    def scan_until(self, needle: bytes, deadline: float):
        """Consume frames until `needle` appears in output payloads. Returns mono ns of first
        byte of the matching frame's arrival (approximation: time we read it)."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("marker timeout")
            ready, _, _ = select.select([self.connection], [], [], remaining)
            if not ready:
                raise TimeoutError("marker timeout")
            chunk = self.connection.recv(1 << 20)
            if not chunk:
                raise RuntimeError("stream closed")
            arrived = time.monotonic_ns()
            self.buffer.extend(chunk)
            # parse frames
            while True:
                if len(self.buffer) < 5:
                    break
                magic = self.buffer[0]
                if magic == 0xF5:
                    size = struct.unpack(">I", self.buffer[1:5])[0]
                    if len(self.buffer) < 5 + size:
                        break
                    payload = bytes(self.buffer[13:5 + size])
                    del self.buffer[:5 + size]
                    if needle in payload:
                        return arrived
                    continue
                else:
                    size = struct.unpack(">I", self.buffer[0:4])[0]
                    if len(self.buffer) < 4 + size:
                        break
                    del self.buffer[:4 + size]
                    continue


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    idx = int((len(sorted_vals) - 1) * p + 0.5)
    return sorted_vals[min(max(idx, 0), len(sorted_vals) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--probes", type=int, default=10000)
    parser.add_argument("--variant", choices=["persistent", "oneshot", "echo"], default="persistent")
    parser.add_argument("--load", type=int, default=0)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--batches", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--timeout-ms", type=int, default=10000)
    args = parser.parse_args()

    daemon = args.bin_dir.resolve() / "HarnessDaemon"
    cli = args.bin_dir.resolve() / "harness-cli"
    root = args.work_dir
    root.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "HARNESS_HOME": str(root), "SHELL": "/bin/sh"}
    out = args.out.open("a", encoding="utf-8")

    with (root / "daemon.log").open("ab") as log:
        owner = subprocess.Popen([str(daemon)], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        stream = None
        try:
            client = Client(root / "harness.sock")
            deadline = time.monotonic() + 30
            while True:
                try:
                    if "pong" in client.request("ping", timeout=5):
                        break
                except OSError:
                    pass
                if owner.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("daemon failed to start")
                time.sleep(0.05)

            surface = client.request("createSurface", {"cwd": str(root), "shell": "/bin/sh"})["surfaceID"]["_0"]
            stream = OutputStream(root / "harness.sock", surface)

            loaders = []
            for i in range(args.load):
                lsurf = client.request("createSurface", {"cwd": str(root), "shell": "/bin/sh"})["surfaceID"]["_0"]
                client.request("send", {"surfaceID": lsurf, "text": "while :; do printf 'flood %s\\n' \"$((i++))\"; done\n" % i})
                loaders.append(lsurf)

            def oneshot_send(text):
                t0 = time.monotonic_ns()
                subprocess.run([str(cli), "send", "--surface", surface, "--text", text], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                return t0, time.monotonic_ns()

            timeouts = 0
            errors = 0
            samples = []
            total = args.probes + args.warmup
            for i in range(total):
                marker = f"MK_{i:08d}_END".encode()
                if args.variant == "echo":
                    text = "e"
                    needle = b"e"
                else:
                    text = "printf '\\n%s\\n'\n" % marker.decode()
                    needle = marker
                try:
                    if args.variant == "oneshot":
                        t0, t_send = oneshot_send(text)
                    else:
                        t0 = time.monotonic_ns()
                        client.request("send", {"surfaceID": surface, "text": text})
                        t_send = time.monotonic_ns()
                    t_recv = stream.scan_until(needle, time.monotonic() + args.timeout_ms / 1000.0)
                    lat = t_recv - t0
                    row = {"probe": i, "variant": args.variant, "send_ns": t0,
                           "sent_ns": t_send, "recv_ns": t_recv, "latency_ns": lat}
                    out.write(json.dumps(row) + "\n")
                    if i >= args.warmup:
                        samples.append(lat)
                except (TimeoutError, RuntimeError, OSError) as exc:
                    row = {"probe": i, "variant": args.variant, "error": f"{type(exc).__name__}: {exc}"}
                    out.write(json.dumps(row) + "\n")
                    if isinstance(exc, TimeoutError):
                        timeouts += 1
                    else:
                        errors += 1
                    if errors + timeouts > max(20, total // 10):
                        raise RuntimeError("too many probe failures")
                out.flush()

            samples.sort()
            summary = {
                "type": "summary", "variant": args.variant, "load": args.load,
                "probes_requested": args.probes, "probes_measured": len(samples),
                "timeouts": timeouts, "errors": errors,
                "p50_ns": percentile(samples, 0.50), "p95_ns": percentile(samples, 0.95),
                "p99_ns": percentile(samples, 0.99), "min_ns": samples[0] if samples else None,
                "max_ns": samples[-1] if samples else None,
            }
            out.write(json.dumps(summary) + "\n")
            print(json.dumps(summary))
        finally:
            if stream is not None:
                stream.connection.close()
            try:
                client = Client(root / "harness.sock")
                client.request("shutdownDaemon", {"requireEmpty": False}, timeout=10)
            except Exception:
                pass
            try:
                owner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                owner.terminate()
                owner.wait(timeout=5)
    out.close()


if __name__ == "__main__":
    main()
