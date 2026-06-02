#!/usr/bin/env python3
"""Cross-terminal PTY output-stress runner (implementation-independent).

Runs inside ANY terminal (Harness, Ghostty, Terminal.app, …): it writes first-party byte
payloads to stdout (the PTY slave) and times how long each `write` loop takes to drain — i.e.
how fast the host terminal consumes/draws the stream end to end. Higher MB/s = faster.

This script is deliberately self-contained and never imported, linked, or shelled-out from
Harness product code — it is a measurement tool only. Run the same payloads in each terminal,
five runs each, and compare medians.

    # in a Harness pane, then in a Ghostty window (matched: Menlo 14, black bg, opacity 1,
    # blur 0, padding 0, 160x48):
    python3 Scripts/benchmarks/terminal_stress_runner.py harness out.jsonl out.done

Results append one JSON line per workload to <result.jsonl>. See README.md.
"""
import json
import os
import sys
import time


def write_all(payload: bytes) -> int:
    total = 0
    view = memoryview(payload)
    while total < len(payload):
        total += os.write(1, view[total:])
    return total


def run_case(name: str, chunks, result_path: str, terminal: str) -> None:
    started = time.perf_counter_ns()
    byte_count = 0
    for chunk in chunks:
        byte_count += write_all(chunk)
    sys.stdout.flush()
    ended = time.perf_counter_ns()
    nanos = ended - started
    row = {
        "suite": "terminal_output_stress",
        "terminal": terminal,
        "benchmark": name,
        "nanos": nanos,
        "bytes": byte_count,
        "mbps": round((byte_count / 1_000_000) / (nanos / 1_000_000_000), 3) if nanos else None,
    }
    with open(result_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")


def repeated_chunk(chunk: bytes, target_bytes: int):
    count = max(1, target_bytes // len(chunk))
    for _ in range(count):
        yield chunk


def sgr_lines(target_bytes: int):
    colors = [31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97]
    made = 0
    i = 0
    while made < target_bytes:
        line = f"\x1b[{colors[i % len(colors)]};1mline {i:06d}\x1b[0m build output with SGR color and ASCII payload 0123456789\r\n".encode()
        made += len(line)
        yield line
        i += 1


def truecolor_gradient(frames: int, cols: int = 160):
    for frame in range(frames):
        row = [b"\x1b[H"]
        for col in range(cols):
            r = (col * 255) // max(1, cols - 1)
            g = (frame * 7) % 256
            b = 255 - r
            row.append(f"\x1b[48;2;{r};{g};{b}m ".encode())
        row.append(b"\x1b[0m\r\n")
        yield b"".join(row)


def redraw_frames(frames: int, cols: int = 160, rows: int = 48):
    base = ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" * 4)[:cols]
    for frame in range(frames):
        lines = [b"\x1b[H"]
        for row in range(rows):
            lines.append(f"\x1b[{31 + ((row + frame) % 7)}m{base}\x1b[0m\r\n".encode())
        yield b"".join(lines)


def unicode_lines(target_bytes: int):
    sample = "é Ω 世 Ж 中 λ ✓ café résumé 漢字 emoji-free wide text "
    made = 0
    i = 0
    while made < target_bytes:
        line = f"{i:06d} {sample}{sample}\r\n".encode()
        made += len(line)
        yield line
        i += 1


def attribute_lines(target_bytes: int):
    attrs = [b"\x1b[1m", b"\x1b[2m", b"\x1b[3m", b"\x1b[4m", b"\x1b[7m", b"\x1b[9m", b"\x1b[53m"]
    made = 0
    i = 0
    while made < target_bytes:
        line = attrs[i % len(attrs)] + f"attribute row {i:06d} underline bold faint inverse strike overline\x1b[0m\r\n".encode()
        made += len(line)
        yield line
        i += 1


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: terminal_stress_runner.py <terminal> <result.jsonl> <done-file>", file=sys.stderr)
        return 64
    terminal, result_path, done_path = sys.argv[1:]
    open(result_path, "w", encoding="utf-8").close()

    write_all(b"\x1b[2J\x1b[H")
    run_case("plain_ascii_16mib", repeated_chunk(b"the quick brown fox jumps over the lazy dog 0123456789\r\n", 16 * 1024 * 1024), result_path, terminal)
    run_case("ansi_sgr_16mib", sgr_lines(16 * 1024 * 1024), result_path, terminal)
    run_case("unicode_mixed_8mib", unicode_lines(8 * 1024 * 1024), result_path, terminal)
    run_case("attributes_8mib", attribute_lines(8 * 1024 * 1024), result_path, terminal)
    run_case("truecolor_gradient_1200_frames", truecolor_gradient(1200), result_path, terminal)
    run_case("redraw_160x48_600_frames", redraw_frames(600), result_path, terminal)
    run_case("scrollback_100k_lines", (f"scrollback row {i:06d} xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r\n".encode() for i in range(100_000)), result_path, terminal)
    write_all(b"\x1b[0m\r\nDONE\r\n")
    with open(done_path, "w", encoding="utf-8") as f:
        f.write("done\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
