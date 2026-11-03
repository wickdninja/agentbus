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
import time

GRACE_S = 2.0  # between SIGTERM and SIGKILL
POLL_S = 0.05  # how often the wait looks for a signal that arrived
FORWARDED = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def killpg(pgid, sig):
    """Signal the group. Gone (ESRCH) is fine, and so is EPERM: macOS returns it for a group whose
    only members are zombies, which have ended already."""
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def end_group(proc):
    """SIGTERM the group, wait up to GRACE_S for the leader, then SIGKILL whatever is left of the
    group (a child that ignores SIGTERM, or one the leader left behind), and reap the leader."""
    killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(GRACE_S)
    except subprocess.TimeoutExpired:
        pass
    killpg(proc.pid, signal.SIGKILL)
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
    # The handlers only note the signal, and they are in place before COMMAND starts, so a signal that
    # arrives at any point is seen; all the work happens below, in order, never inside a handler.
    got = []
    for s in FORWARDED:
        signal.signal(s, lambda signum, _frame: got.append(signum))
    try:
        proc = subprocess.Popen(argv[1:], start_new_session=True)
    except OSError as e:
        sys.stderr.write(f"run_capped.py: cannot run {argv[1]}: {e.strerror}\n")
        return 127 if isinstance(e, FileNotFoundError) else 126
    deadline = time.monotonic() + cap
    while not got:
        left = deadline - time.monotonic()
        if left <= 0:
            end_group(proc)
            return 124
        try:
            rc = proc.wait(min(left, POLL_S))
        except subprocess.TimeoutExpired:
            continue
        if not got:
            return 128 - rc if rc < 0 else rc
    # A signal arrived: end the group (whatever else arrives meanwhile is only noted), then, once the
    # leader is reaped, die of the first signal, so a shell running this (run_all.sh) sees the Ctrl-C and stops too.
    end_group(proc)
    signum = got[0]
    for s in FORWARDED:
        signal.signal(s, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
    time.sleep(1)  # the signal is delivered before this returns; never reached
    return 128 + signum


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
