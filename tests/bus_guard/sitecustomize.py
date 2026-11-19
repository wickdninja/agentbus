"""Test-only guard (issue #55): a test never opens a SQLite database outside its own temp folder.

tests/lib.sh puts this folder first on PYTHONPATH and names the allowed folder in TESTS_BUS_ROOT; Python imports this
module at every start. A sqlite3 audit event (raised by sqlite3.connect, nothing is patched) for a path outside
TESTS_BUS_ROOT is refused with an error, and a line goes to TESTS_BUS_GUARD_LOG when that is set, so tests/run_all.sh
fails the file even if the test swallowed the error. Why: from a linked worktree, bus discovery walks to the main
checkout's bus, and a test run with the checkout as its folder read or wrote that live bus.
Off when TESTS_BUS_ROOT is unset. Nothing in bin/agentbus knows about it.

Known limits (the guard is a tripwire, not a sandbox). It does not run under python -I, -E or -S (they ignore PYTHONPATH
or skip sitecustomize), after `env -i`, or where a command clears PYTHONPATH, and it does not see the sqlite3 command-line
tool. The second layer is the empty scratch working folder tests/run_all.sh gives every file: a bus is found by walking up
from the current folder, so a command that skips the guard still starts in a folder with no bus above it to find.
"""
import os
import sys
from urllib.parse import unquote

_ROOT = os.environ.get("TESTS_BUS_ROOT")


def _database_path(database):
    if isinstance(database, bytes):
        database = os.fsdecode(database)
    if not isinstance(database, (str, os.PathLike)):
        return None
    database = os.fspath(database)
    if database in ("", ":memory:") or "mode=memory" in database:
        return None  # nothing on disk
    if database.startswith("file:"):
        # bin/agentbus opens "file:" + quote(path): the path comes back after decoding the percent escapes
        database = unquote(database[5:].split("?", 1)[0])
        if database.startswith("//"):
            database = database[2:]
    return database


def _audit(event, args):
    if event != "sqlite3.connect":
        return
    path = _database_path(args[0])
    if path is None:
        return
    real = os.path.realpath(path)
    root = os.path.realpath(_ROOT)
    if real == root or real.startswith(root.rstrip(os.sep) + os.sep):
        return
    message = "tests/bus_guard: a test opened %s, outside its temp folder %s" % (real, root)
    log = os.environ.get("TESTS_BUS_GUARD_LOG")
    if log:
        try:
            with open(log, "a") as f:
                f.write(message + "\n")
        except OSError:
            pass
    raise RuntimeError(message)


if _ROOT:
    sys.addaudithook(_audit)
