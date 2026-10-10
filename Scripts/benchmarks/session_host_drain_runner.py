#!/usr/bin/env python3
"""Disposable headless PTY drain comparison using the existing stress writer.

Measures admission and verifies every payload byte reaches an attached stream.
This is not a renderer benchmark and never touches an installed Harness service.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    args = parser.parse_args()
    daemon = args.bin_dir.resolve() / "HarnessDaemon"
    writer = Path(__file__).with_name("terminal_stress_runner.py")
    with tempfile.TemporaryDirectory(prefix="hproof-drain-", dir="/tmp") as directory:
        root = Path(directory)
        environment = {**os.environ, "HARNESS_HOME": directory, "SHELL": "/bin/sh"}
        with (root / "service.log").open("wb") as log:
            owner = subprocess.Popen([str(daemon)], env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            stream = None; worker = None

            def read(connection, count):
                result = bytearray()
                while len(result) < count:
                    chunk = connection.recv(count - len(result))
                    if not chunk:
                        raise RuntimeError("incomplete terminal frame")
                    result.extend(chunk)
                return result

            def request(method, values=None):
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(20); connection.connect(str(root / "harness.sock"))
                    data = json.dumps({"request": {method: values or {}}}).encode()
                    connection.sendall(struct.pack(">I", len(data)) + data)
                    return json.loads(read(connection, struct.unpack(">I", read(connection, 4))[0]))["response"]

            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        if "pong" in request("ping"):
                            break
                    except OSError:
                        pass
                    if owner.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("isolated owner failed startup")
                    time.sleep(0.04)
                worker = request("daemonStats")["daemonStats"]["_0"].get("daemonPID")
                surface = request("createSurface", {"cwd": directory, "shell": "/bin/sh"})["surfaceID"]["_0"]
                stream = socket.socket(socket.AF_UNIX); stream.settimeout(20); stream.connect(str(root / "harness.sock"))
                data = json.dumps({"request": {"subscribeSurfaceOutput": {"surfaceID": surface, "label": "drain-proof"}}}).encode()
                stream.sendall(struct.pack(">I", len(data)) + data)
                read(stream, struct.unpack(">I", read(stream, 4))[0])
                workload = root / "workload.py"
                workload.write_text("import importlib.util\n"
                    + "s=importlib.util.spec_from_file_location('stress', " + repr(str(writer)) + ")\n"
                    + "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
                    + "m.write_all(b'harness_drain_start\\n')\n"
                    + "m.run_case('plain_ascii_48mib', [b'X'*65536]*768, " + repr(str(root / "result.jsonl")) + ", 'isolated-host')\n"
                    + "m.write_all(b'\\r\\nharness_drain_done\\r\\n')\n")
                command = "python3 " + shlex.quote(str(workload)) + "\n"
                assert "ok" in request("send", {"surfaceID": surface, "text": command})
                delivered = 0; previous = None; done = False; started = False; tail = b""
                while not done:
                    first = read(stream, 1)
                    if first == b"\xf5":
                        size = struct.unpack(">I", read(stream, 4))[0]
                        frame = read(stream, size)
                        sequence = struct.unpack(">Q", frame[:8])[0]; payload = bytes(frame[8:])
                        if previous is not None:
                            assert sequence == previous, "dropped, duplicated or reordered terminal bytes"
                        previous = sequence + len(payload)
                        if not started:
                            beginning = tail + payload
                            marker = b"harness_drain_start"
                            position = beginning.find(marker)
                            if position >= 0:
                                started = True
                                delivered += beginning[position + len(marker):].count(b"X")
                        else:
                            delivered += payload.count(b"X")
                        tail = (tail + payload)[-128:]
                        done = b"harness_drain_done" in tail
                    else:
                        size = struct.unpack(">I", first + read(stream, 3))[0]; read(stream, size)
                row = json.loads((root / "result.jsonl").read_text().splitlines()[0])
                assert delivered == row["bytes"] == 48 * 1024 * 1024, (delivered, row)
                assert "error" not in row
                row["delivered_bytes"] = delivered; row["ordered_stream"] = True
                print(json.dumps(row, sort_keys=True))
            finally:
                if stream is not None:
                    stream.close()
                try:
                    response = request("shutdownDaemon", {"requireEmpty": False})
                    if "ok" not in response:
                        raise RuntimeError("isolated shutdown was refused: " + str(response))
                except (OSError, RuntimeError):
                    pass
                try:
                    owner.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    owner.terminate(); owner.wait(timeout=5)
                if worker:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            os.kill(worker, 0)
                        except ProcessLookupError:
                            break
                        if time.monotonic() >= deadline:
                            log.flush()
                            raise RuntimeError("isolated worker survived owner shutdown: " + (root / "service.log").read_text(errors="replace")[-4000:])
                        time.sleep(0.05)


if __name__ == "__main__":
    main()
