#!/usr/bin/env python3
"""Run a command under a PTY, optionally send keys, report the exit status.

Usage: pty_run.py OUT SEND_AFTER KEY -- COMMAND [ARGS...]

KEY uses Python escape syntax (e.g. '\\x03' for Ctrl+C). The driver sends the
key at SEND_AFTER seconds, then up to three times two seconds apart, and kills
the child 12 seconds after the first send if it is still alive. Raw output is
written to OUT. JSON status is printed to stdout.
"""
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main() -> int:
    if len(sys.argv) < 6 or sys.argv[4] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    out_path = sys.argv[1]
    send_after = float(sys.argv[2])
    key = sys.argv[3].encode().decode("unicode_escape").encode("latin1")
    cmd = sys.argv[5:]

    env = dict(os.environ)
    for var in ("LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "LD_DEBUG"):
        env.pop(var, None)
    env.setdefault("TERM", "xterm-256color")

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(cmd[0], cmd, env)
        except OSError as exc:
            sys.stderr.write(f"pty_run: cannot exec {cmd[0]}: {exc}\n")
            os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    chunks = []
    start = time.time()
    sends = 0
    last_send = 0.0
    while True:
        now = time.time()
        if now - start >= send_after and sends < 3 and now - last_send >= 2:
            try:
                os.write(fd, key)
            except OSError:
                pass
            sends += 1
            last_send = now
        readable, _, _ = select.select([fd], [], [], 0.2)
        if readable:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                break
            chunks.append(data)
        if now - start > send_after + 12:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break

    _, status = os.waitpid(pid, 0)
    with open(out_path, "wb") as handle:
        handle.write(b"".join(chunks))
    print(json.dumps({
        "exit": os.waitstatus_to_exitcode(status),
        "signaled": os.WIFSIGNALED(status),
        "duration_s": round(time.time() - start, 2),
        "bytes": sum(len(chunk) for chunk in chunks),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
