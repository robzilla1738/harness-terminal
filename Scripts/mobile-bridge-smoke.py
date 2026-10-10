#!/usr/bin/env python3
"""Exercise a real bridge/daemon in an isolated HARNESS_HOME, never the user's sessions."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import select
import struct
import subprocess
import tempfile
import time


def read_exact(pipe, count, timeout=10):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < count:
        wait = deadline - time.monotonic()
        if wait <= 0 or not select.select([pipe], [], [], wait)[0]:
            raise TimeoutError("Bridge did not complete its frame")
        chunk = os.read(pipe.fileno(), count - len(data))
        if not chunk:
            raise RuntimeError("Bridge disconnected")
        data.extend(chunk)
    return bytes(data)


def receive(bridge):
    length = struct.unpack(">I", read_exact(bridge.stdout, 4))[0]
    assert 0 < length <= 12 * 1024 * 1024
    frame = read_exact(bridge.stdout, length)
    if frame[0] == 0:
        return json.loads(frame[1:])
    assert frame[0] == 1
    size = struct.unpack(">H", frame[1:3])[0]
    sequence = struct.unpack(">Q", frame[3 + size:11 + size])[0]
    return {"output": {"surfaceID": frame[3:3 + size].decode(), "sequence": sequence, "data": frame[11 + size:]}}


def send(bridge, message):
    frame = b"\0" + json.dumps(message, separators=(",", ":")).encode()
    bridge.stdin.write(struct.pack(">I", len(frame)) + frame)
    bridge.stdin.flush()


def rpc(bridge, method, arguments=None):
    identity = "smoke-" + str(time.monotonic_ns())
    send(bridge, {"request": {"_0": {"id": identity, "method": method, "arguments": arguments or {}}}})
    while True:
        message = receive(bridge)
        if "error" in message:
            raise RuntimeError(message["error"])
        if "response" in message and message["response"]["_0"]["id"] == identity:
            response = message["response"]["_0"]
            assert not response.get("failure"), response
            return response.get("result")


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--products", type=Path, default=Path(".build/out/Products/Debug"))
    options = args.parse_args()
    cli = options.products.resolve() / "harness-cli"
    daemon_path = options.products.resolve() / "HarnessDaemon"
    with tempfile.TemporaryDirectory(prefix="harness-mobile-", dir="/tmp") as directory:
        env = dict(os.environ, HARNESS_HOME=directory)
        daemon = subprocess.Popen([str(daemon_path)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        bridge = None
        try:
            deadline = time.monotonic() + 10
            while not (Path(directory) / "control.sock").exists():
                # Discover the configured socket through the CLI (platform-independent path).
                socket = subprocess.check_output([str(cli), "socket-path"], env=env, text=True).strip()
                if Path(socket).exists():
                    break
                assert daemon.poll() is None, "Test daemon failed to start"
                if time.monotonic() >= deadline:
                    raise TimeoutError("Test daemon startup")
                time.sleep(0.05)
            bridge = subprocess.Popen([str(cli), "mobile-bridge", "--stdio", "--protocol", "1"], env=env,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            hello = receive(bridge)["hello"]["_0"]
            assert "terminal-checkpoint-v1" in hello["capabilities"]
            assert hello["daemonEpoch"]
            snapshot = rpc(bridge, "snapshot.get")
            pane = snapshot["workspaces"][0]["sessions"][0]["tabs"][0]["panes"][0]
            assert isinstance(rpc(bridge, "attention.get"), list)
            appearance = rpc(bridge, "appearance.get")
            assert len(appearance["palette"]) == 16
            address = pane["address"]
            attachment = {"address": address, "readOnly": False, "cols": 70, "rows": 20}
            send(bridge, {"attach": {"_0": attachment}})
            while True:
                message = receive(bridge)
                if "error" in message:
                    raise RuntimeError(message["error"])
                if "attached" in message:
                    attached = message["attached"]["_0"]
                    break
            assert attached["resync"]
            checkpoint = plistlib.loads(base64.b64decode(attached["checkpoint"]))
            assert checkpoint["version"] == 1 and checkpoint["payload"]
            surface = address["surfaceID"].encode()
            input_bytes = b"printf 'MOBILE_SMOKE_OK\\n'\r"
            frame = b"\2" + struct.pack(">H", len(surface)) + surface + input_bytes
            bridge.stdin.write(struct.pack(">I", len(frame)) + frame)
            bridge.stdin.flush()
            received = bytearray()
            sequence = attached["endSequence"]
            deadline = time.monotonic() + 10
            while b"MOBILE_SMOKE_OK" not in received:
                assert time.monotonic() < deadline
                message = receive(bridge)
                if "error" in message:
                    raise RuntimeError(message["error"])
                if "output" in message:
                    output = message["output"]
                    received.extend(output["data"])
                    sequence = output["sequence"] + len(output["data"])
            page = rpc(bridge, "pane.history", {"pane": address["surfaceID"], "count": 20})
            assert page["epoch"] == hello["daemonEpoch"] and page["token"] and len(page["rows"]) <= 20
            results = rpc(bridge, "output.search", {"query": "MOBILE_SMOKE_OK", "session": address["sessionID"]})
            assert results["matches"], results
            match = results["matches"][0]
            opened = rpc(bridge, "output.openMatch", {"match": match, "epoch": results["epoch"], "revision": results["revision"]})
            assert opened["targetRow"] == match["line"]
            assert opened["startRow"] <= match["line"] < opened["startRow"] + len(opened["rows"])
            send(bridge, {"detach": {}})
            attachment.update(epoch=attached["epoch"], fromSequence=sequence)
            send(bridge, {"attach": {"_0": attachment}})
            while True:
                message = receive(bridge)
                if "attached" in message:
                    assert not message["attached"]["_0"]["resync"], message
                    break
                if "error" in message:
                    raise RuntimeError(message["error"])
            print("PASS: real daemon hello, snapshot, attention, resolved appearance, aligned checkpoint, binary input/output, styled history, validated output match, resume")
        finally:
            if bridge:
                bridge.stdin.close()
                try:
                    bridge.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    bridge.kill()
                    bridge.wait()
            # Ask the disposable owner to close its shells and retire the worker;
            # acknowledgement precedes completion, so wait before removing its home.
            if daemon.poll() is None:
                try:
                    import socket
                    payload = json.dumps({"request": {"shutdownDaemon": {"requireEmpty": False}}}).encode()
                    with socket.socket(socket.AF_UNIX) as control:
                        control.settimeout(5); control.connect(str(Path(directory) / "harness.sock"))
                        control.sendall(struct.pack(">I", len(payload)) + payload)
                        control.recv(4096)
                except OSError:
                    daemon.terminate()
                try:
                    daemon.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    daemon.terminate()
                    daemon.wait(timeout=12)


if __name__ == "__main__":
    main()
