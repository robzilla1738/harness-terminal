#!/usr/bin/env python3
"""Measure PTY admission and consumption acknowledgement separately, inside a terminal.

Usage: consumer_ack_runner.py <terminal-label> <results.jsonl>
Match font, opacity, grid (150x45), and retention policy across terminals. Sample 0
warms up; compare medians of samples 1–3. A cursor report fences terminal parsing,
NOT GPU presentation, display scanout, or physical input-to-photon latency. Python
payload generation and query/reply transport are included in the elapsed time.
"""
import json
import os
import re
import select
import sys
import termios
import time
import tty

import terminal_stress_runner as stress


def acknowledge():
    termios.tcflush(0, termios.TCIFLUSH)
    stress.write_all(b"\x1b[6n")
    received = b""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
            chunk = os.read(0, 4096)
            if not chunk:
                break
            received = (received + chunk)[-8192:]
            if re.search(rb"\x1b\[\d+;\d+R", received):
                return
    raise RuntimeError("cursor report did not acknowledge consumption within 10 seconds")


def workloads():
    return [
        ("plain_ascii", stress.repeated_chunk(b"the quick brown fox jumps over the lazy dog 0123456789\r\n", 1024 * 1024)),
        ("ansi_sgr", stress.sgr_lines(1024 * 1024)),
        ("unicode_mixed", stress.unicode_lines(1024 * 1024)),
        ("attributes", stress.attribute_lines(1024 * 1024)),
        ("truecolor_gradient", stress.truecolor_gradient(300, 150)),
        ("redraw", stress.redraw_frames(120, 150, 45)),
        ("scrollback", (f"history {i:06d} abcdefghijklmnopqrstuvwxyz\r\n".encode() for i in range(20_000))),
    ]


def main():
    if len(sys.argv) != 3 or not os.isatty(0) or not os.isatty(1):
        sys.exit("Run inside a terminal: consumer_ack_runner.py <terminal-label> <results.jsonl>")
    label, path = sys.argv[1:]
    attributes = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        with open(path, "w", encoding="utf-8") as output:
            for sample in range(4):
                for name, chunks in workloads():
                    stress.write_all(b"\x1b[0m\x1b[3J\x1b[2J\x1b[H")
                    acknowledge()
                    start = time.perf_counter_ns()
                    count = sum(stress.write_all(chunk) for chunk in chunks)
                    written = time.perf_counter_ns()
                    acknowledge()
                    end = time.perf_counter_ns()
                    size = os.get_terminal_size(1)
                    output.write(json.dumps({
                        "variant": label, "sample": sample, "case": name, "bytes": count,
                        "columns": size.columns, "rows": size.lines,
                        "write_ms": (written - start) / 1e6, "consumer_ms": (end - start) / 1e6,
                    }) + "\n")
                    output.flush()
    finally:
        termios.tcsetattr(0, termios.TCSANOW, attributes)


if __name__ == "__main__":
    main()
