#!/usr/bin/env python3
"""Run a command with some of its standard streams on a pseudo-terminal, for the update tests.

  python3 tests/pty_run.py [--tty in,out,err] [--timeout S] -- CMD [ARG...]

--tty names the streams that are a terminal (default in,out,err: a person at a terminal); the others are
/dev/null (stdin) or pipes (stdout, stderr). Prints everything the command wrote (the terminal's text, then
any piped text) and, as the last line, RC=<exit status>. The command runs in its own session, so its
terminal is its own and a stray signal never reaches the test.
"""
import os
import pty
import select
import subprocess
import sys


def main():
    args = sys.argv[1:]
    tty, timeout = {"in", "out", "err"}, 120.0
    while args and args[0] != "--":
        flag = args.pop(0)
        if flag == "--tty":
            tty = set(filter(None, args.pop(0).split(",")))
        elif flag == "--timeout":
            timeout = float(args.pop(0))
        else:
            sys.exit("pty_run.py: unknown option " + flag)
    cmd = args[1:]
    master, slave = pty.openpty()
    kw = {}
    kw["stdin"] = slave if "in" in tty else subprocess.DEVNULL
    kw["stdout"] = slave if "out" in tty else subprocess.PIPE
    kw["stderr"] = slave if "err" in tty else subprocess.PIPE
    p = subprocess.Popen(cmd, close_fds=True, start_new_session=True, **kw)
    os.close(slave)
    chunks = []
    import time
    end = time.time() + timeout
    status = None
    while True:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if not data:
                break
            chunks.append(data)
        if p.poll() is not None and not r:
            break
        if time.time() > end:
            p.kill()
            chunks.append(b"\n(pty_run: timed out)\n")
            break
    try:
        out, err = p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    status = p.returncode
    text = b"".join(chunks).decode("utf-8", "replace").replace("\r\n", "\n")
    sys.stdout.write(text)
    for piped in (out, err):
        if piped:
            sys.stdout.write(piped.decode("utf-8", "replace"))
    sys.stdout.write("RC=%d\n" % status)


if __name__ == "__main__":
    main()
