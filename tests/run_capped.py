"""python3 tests/run_capped.py SECONDS COMMAND [ARG...]: run COMMAND with a time cap, for tests/run_all.sh.

The cap must hold on every machine, so it does not depend on an optional binary (GitHub's macOS
runners have no `timeout`). COMMAND starts in its own process group (a new session); when it outlives
SECONDS, the whole group gets SIGTERM, then SIGKILL after a short grace, and this exits 124 as GNU
timeout does. A SIGINT, SIGTERM or SIGHUP sent to this process ends the group the same way, then this
process dies of that signal. Otherwise the exit status is COMMAND's (128 + N when a signal N ended it).
Standard library only, Python 3.9 and later.
"""
import os
import signal
import subprocess
import sys

GRACE_S = 2.0  # between SIGTERM and SIGKILL


def end_group(proc):
    """SIGTERM the group, wait up to GRACE_S for the leader, then SIGKILL whatever is left of the
    group (a child that ignores SIGTERM, or one the leader left behind)."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(GRACE_S)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: run_capped.py SECONDS COMMAND [ARG...]\n")
        return 2
    try:
        cap = float(argv[0])
    except ValueError:
        sys.stderr.write(f"run_capped.py: not a number of seconds: {argv[0]!r}\n")
        return 2
    try:
        proc = subprocess.Popen(argv[1:], start_new_session=True)
    except OSError as e:
        sys.stderr.write(f"run_capped.py: cannot run {argv[1]}: {e.strerror}\n")
        return 127 if isinstance(e, FileNotFoundError) else 126
    forwarded = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def on_signal(signum, _frame):
        for s in forwarded:  # one cleanup, however many signals arrive meanwhile
            signal.signal(s, signal.SIG_IGN)
        end_group(proc)
        # Die of the same signal, so a shell running this (run_all.sh) sees a Ctrl-C and stops too.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)
        os._exit(128 + signum)

    for s in forwarded:
        signal.signal(s, on_signal)
    try:
        rc = proc.wait(cap)
    except subprocess.TimeoutExpired:
        end_group(proc)
        return 124
    return 128 - rc if rc < 0 else rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
