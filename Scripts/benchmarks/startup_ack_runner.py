#!/usr/bin/env python3
"""Record when a fresh terminal can consume output at the agreed 150x45 grid.

Run from a temporary shell wrapper, followed by `exec /bin/sh`:
    python3 startup_ack_runner.py /absolute/path/ready.json
The launcher records time.monotonic_ns() immediately before spawning the app and
subtracts it from ready_ns. Use a fresh isolated app home, one warm-up, and three
samples. This includes shell/Python startup and a cursor-report round trip; it
does not measure GPU presentation or when the user sees a prompt.
"""
import json
import os
import pathlib
import re
import select
import sys
import termios
import time
import tty


def main():
    if len(sys.argv) != 2 or not os.isatty(0) or not os.isatty(1):
        sys.exit("Run inside a terminal: startup_ack_runner.py <ready.json>")
    path = pathlib.Path(sys.argv[1])
    attributes = termios.tcgetattr(0)
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            size = os.get_terminal_size(1)
            if (size.columns, size.lines) == (150, 45):
                break
            time.sleep(0.001)
        else:
            raise RuntimeError("terminal never reached 150x45")
        tty.setraw(0)
        os.write(1, b"READY\r\n\x1b[6n")
        received = b""
        while time.monotonic() < deadline:
            if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
                chunk = os.read(0, 4096)
                if not chunk:
                    break
                received = (received + chunk)[-8192:]
                if re.search(rb"\x1b\[\d+;\d+R", received):
                    path.write_text(json.dumps({
                        "ready_ns": time.monotonic_ns(),
                        "columns": size.columns,
                        "rows": size.lines,
                    }) + "\n", encoding="utf-8")
                    return
        raise RuntimeError("terminal did not acknowledge the ready marker")
    finally:
        termios.tcsetattr(0, termios.TCSANOW, attributes)


if __name__ == "__main__":
    main()
