#!/usr/bin/env python3
"""Reusable stdio MCP proof against an explicitly supplied isolated Harness socket.

Never starts or restarts a service, and refuses the normal application-support path.
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time
import threading


def read_line(process, timeout=4):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        byte = os.read(process.stdout.fileno(), 1)
        if not byte:
            raise RuntimeError("MCP stdout closed before its response")
        if byte == b"\n":
            return json.loads(data)
        data.extend(byte)
    raise RuntimeError("MCP response deadline exceeded")


def send(process, method, params=None, identity=None):
    message = {"jsonrpc": "2.0", "method": method}
    if identity is not None:
        message["id"] = identity
    if params is not None:
        message["params"] = params
    process.stdin.write(json.dumps(message).encode() + b"\n")
    process.stdin.flush()


def initialize(process):
    send(process, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "Harness isolated proof", "version": "1"}}, 1)
    initialized = read_line(process)
    assert initialized["result"]["protocolVersion"] == "2025-11-25", initialized
    send(process, "notifications/initialized")


def snapshot(path):
    data = json.dumps({"request": {"getSnapshot": {}}}).encode()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(3)
        channel.connect(path)
        channel.sendall(struct.pack(">I", len(data)) + data)

        def read(count):
            value = bytearray()
            while len(value) < count:
                value.extend(channel.recv(count - len(value)))
            return value

        return json.loads(read(struct.unpack(">I", read(4))[0]))["response"]["snapshot"]["_0"]


def first_leaf(node):
    if "leaf" in node:
        return node["leaf"]["_0"]
    return first_leaf(node["branch"]["first"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    args = parser.parse_args()
    path = str(args.socket.resolve())
    assert path.startswith("/private/tmp/hproof-") or path.startswith("/tmp/hproof-"), "proof requires a fresh hproof- temporary home"
    layout = snapshot(path)
    leaf = first_leaf(layout["workspaces"][0]["sessions"][0]["tabs"][0]["rootPane"])
    environment = {**os.environ, "HARNESS_SERVER": path, "HARNESS_HOME": str(args.socket.parent), "HARNESS_SURFACE": leaf["surfaceID"]}
    processes = []
    try:
        read_only = subprocess.Popen([str(args.cli), "mcp"], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        processes.append(read_only)
        # Strict SDK lifecycle must reject tools before initialize.
        send(read_only, "tools/list", identity=0)
        assert "error" in read_line(read_only)
        initialize(read_only)
        send(read_only, "tools/list", identity=2)
        tools = {tool["name"] for tool in read_line(read_only)["result"]["tools"]}
        assert "agent.list" in tools and "pane.write" not in tools and "pane.kill_tree" not in tools
        send(read_only, "tools/call", {"name": "server.version", "arguments": {}}, 3)
        assert not read_line(read_only)["result"]["isError"]
        send(read_only, "tools/call", {"name": "pane.write", "arguments": {"text": "must not be inserted"}}, 4)
        assert read_line(read_only)["result"]["isError"]
        send(read_only, "resources/list", identity=5)
        resources = read_line(read_only)["result"]["resources"]
        assert resources
        send(read_only, "resources/read", {"uri": resources[0]["uri"]}, 6)
        assert "contents" in read_line(read_only)["result"]
        writable = subprocess.Popen([str(args.cli), "mcp", "--allow-write"], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        processes.append(writable)
        initialize(writable)
        send(writable, "tools/call", {"name": "pane.write", "arguments": {"pane": leaf["id"], "text": "must not be inserted"}}, 7)
        refused = read_line(writable)["result"]
        assert refused["isError"] and "own pane" in refused["content"][0]["text"], refused
        # Hold an isolated fixture IPC connection open until cancellation. This proves
        # cancellation of actual in-flight work, rather than racing a fast capture.
        slow_path = str(args.socket.parent / "slow-mcp-proof.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(slow_path)
        listener.listen(1)
        accepted, cancelled = threading.Event(), threading.Event()

        def slow_daemon():
            channel, _ = listener.accept()
            channel.settimeout(3)
            try:
                header = channel.recv(4)
                length = struct.unpack(">I", header)[0]
                channel.recv(length)
                accepted.set()
                if not channel.recv(1):
                    cancelled.set()
            finally:
                channel.close()
                listener.close()

        fixture = threading.Thread(target=slow_daemon, daemon=True)
        fixture.start()
        slow = subprocess.Popen([str(args.cli), "mcp"], env={**environment, "HARNESS_SERVER": slow_path}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        processes.append(slow)
        initialize(slow)
        send(slow, "tools/call", {"name": "server.version", "arguments": {}}, 8)
        assert accepted.wait(2), "fixture IPC request did not start"
        start = time.monotonic()
        send(slow, "notifications/cancelled", {"requestId": 8, "reason": "isolated proof"})
        send(slow, "ping", identity=9)
        assert read_line(slow)["id"] == 9
        assert time.monotonic() - start < 0.5
        assert cancelled.wait(0.7), "cancelled tool left its IPC connection open"
        print(json.dumps({"initialize_list_call": True, "strict_lifecycle": True, "read_only_write_denied": True,
                          "canonical_self_pane_write_denied": True, "pane_screen_resource": True,
                          "cancellation_keeps_protocol_responsive": True, "scope": "explicit isolated socket"}))
    finally:
        for process in processes:
            process.stdin.close()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=4)
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    main()
