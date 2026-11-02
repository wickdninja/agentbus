#!/bin/bash
set -euo pipefail
# The failure contract by phase (WS07), under --json, with faults injected by AGENTBUS_TEST_FAIL:
#   1. before any output (parse, open, before-emit): stdout is empty, stderr holds one JSON error;
#   2. during output (emit): code output_failed, committed effects stand;
#   3. after complete output, in inbox's acknowledgement (ack): stdout holds the complete messages,
#      the cursor did not move, stderr holds ack_failed (delivered true).
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
"$PY" - "$BIN" "$T" <<'PY'
import json, os, signal, sqlite3, subprocess, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
bin_, tmp = sys.argv[1:]
BASE = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
BASE.update(COLUMNS="4096", PYTHONDONTWRITEBYTECODE="1", HOME=tmp)

def fresh(name):
    d = os.path.join(tmp, name); os.makedirs(d)
    return os.path.join(d, "bus.db")

def run(db, *args, fail=None):
    env = dict(BASE, AGENTBUS_DB=db)
    if fail:
        env["AGENTBUS_TEST_FAIL"] = fail
    return subprocess.run([*agentbus_argv(), "--json", *args], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)

def ok(db, *args):
    p = run(db, *args)
    assert p.returncode == 0, (args, p.stderr)
    return json.loads(p.stdout)

BASE_RETRYABLE = None   # set below from schema: the code's own retryable value

def rule(e, token):
    """retryable is false whenever the change was saved, unless the command carried --request-id (then
    a retry returns the first result with duplicate true). Otherwise it is the code's own value."""
    own = BASE_RETRYABLE[e["code"]]
    expected = own and (not e["committed"] or token)
    assert e["retryable"] is bool(expected), ("retryable must be false after a saved write without a token", e, token)
    return e

def one_error(p):
    lines = p.stderr.splitlines()
    assert len(lines) == 1, ("stderr must hold exactly one JSON object", p.stderr)
    return json.loads(lines[0])["error"]

db = fresh("phases")
BASE_RETRYABLE = {c: v["retryable"] for c, v in json.loads(run(db, "schema").stdout)["errors"].items()}
ok(db, "--as", "a", "join"); ok(db, "--as", "b", "join")
COMMANDS = [("who",), ("read",), ("status",), ("claims",), ("--as", "a", "post", "x"), ("--as", "a", "claim", "r1"),
            ("--as", "a", "ctx", "set", "k", "v"), ("--as", "b", "inbox"), ("--as", "a", "goal", "g")]

# 1. before any output
for fail, code, status in (("parse", "bad_input", 2), ("open", "bus_unavailable", 3), ("before-emit", "bus_unavailable", 3)):
    for args in COMMANDS:
        p = run(db, *args, fail=fail)
        assert p.returncode == status, (fail, args, p.returncode, p.stderr)
        assert p.stdout == "", (fail, args, "stdout must be empty", p.stdout)
        e = one_error(p)
        assert e["code"] == code, (fail, args, e)
        # a failure after the command's change was saved must say so, so nobody repeats the write
        words = list(args)[2:] if args[0] == "--as" else list(args)
        writes = words[:1] in (["post"], ["claim"], ["goal"]) or words[:2] == ["ctx", "set"]
        assert e["committed"] is (writes and fail == "before-emit"), (fail, args, e)
        rule(e, False)
print("PASS: parse, open and before-emit failures leave stdout empty with one JSON error on stderr and the documented exit")

# the message really is stored when before-emit says committed, and not when it says it is not
dbc = fresh("commit")
ok(dbc, "--as", "a", "join")
p = run(dbc, "--as", "a", "post", "saved", "--request-id", "tok0", fail="before-emit")
assert p.returncode == 3 and one_error(p)["committed"] is True, p.stderr
assert [m["body"] for m in ok(dbc, "read")["items"]] == ["saved"], "the post was stored"
assert ok(dbc, "--as", "a", "post", "saved", "--request-id", "tok0")["duplicate"] is True, "and the token makes the retry safe"
p = run(dbc, "--as", "a", "who", fail="before-emit")
assert one_error(p)["committed"] is False, "a read saved nothing"
p = run(dbc, "--as", "a", "post", "unsaved", fail="open")
assert one_error(p)["committed"] is False and len(ok(dbc, "read")["items"]) == 1, "a failure to open saved nothing"
print("PASS: a failure after the change was saved says committed true, and the message is stored")

# human text: the saved-change sentence is a sentence of its own
dbh = fresh("human")
ok(dbh, "--as", "a", "join")
h = subprocess.run([*agentbus_argv(), "--as", "a", "post", "human", "--request-id", "tokH"], cwd=tmp, text=True, capture_output=True,
                   env=dict(BASE, AGENTBUS_DB=dbh, AGENTBUS_TEST_FAIL="before-emit"), timeout=60)
assert h.returncode == 3 and "before output. The command's change was saved before this." in h.stderr, h.stderr

# refreshing last-seen is best effort: its failure never fails a command that has already succeeded
p = run(dbc, "--as", "a", "post", "after touch", fail="touch")
assert p.returncode == 0 and "id" in json.loads(p.stdout), (p.returncode, p.stdout, p.stderr)
assert [m["body"] for m in ok(dbc, "read")["items"]] == ["saved", "after touch"]
print("PASS: a database error while refreshing last-seen does not fail the command")

# 2. emit: output_failed, and the post is stored once; a retry with the same token returns it
before = len(ok(db, "read", "--limit", "-1")["items"])
p = run(db, "--as", "a", "post", "once", "--request-id", "tok1", fail="emit")
assert p.returncode == 1 and one_error(p)["code"] == "output_failed" and rule(one_error(p), True)["retryable"] is True, p
assert p.stdout == "", p.stdout
assert len(ok(db, "read", "--limit", "-1")["items"]) == before + 1, "the post committed before the output failed"
# the same failure without a token: the post is saved, and retrying it would post twice
p2 = run(db, "--as", "a", "post", "untokened", fail="emit")
e2 = rule(one_error(p2), False)
assert e2["code"] == "output_failed" and e2["committed"] is True and e2["retryable"] is False, e2
# a read that fails to print saved nothing, so it can simply be run again
e3 = rule(one_error(run(db, "read", fail="emit")), False)
assert e3["code"] == "output_failed" and e3["committed"] is False and e3["retryable"] is True, e3
retry = ok(db, "--as", "a", "post", "once", "--request-id", "tok1")
assert retry["duplicate"] is True, retry
msgs = [m for m in ok(db, "read", "--limit", "-1")["items"] if m["body"] == "once"]
assert len(msgs) == 1 and msgs[0]["id"] == retry["id"], msgs
print("PASS: a closed stdout (emit) gives output_failed; the message is stored once and a retry with the same token returns it with duplicate true")

# 3. ack: the output is complete, the exit is non-zero, the cursor did not move
db2 = fresh("ack")
ok(db2, "--as", "a", "join"); ok(db2, "--as", "b", "join")
for i in range(3):
    ok(db2, "--as", "a", "post", "m%d" % i, "--to", "b")
p = run(db2, "--as", "b", "inbox", fail="ack")
assert p.returncode == 3, p
first = json.loads(p.stdout)
assert [m["body"] for m in first["items"]] == ["m0", "m1", "m2"] and first["has_more"] is False, first
e = one_error(p)
assert e["code"] == "ack_failed" and e["delivered"] is True and e["retryable"] is True, e
rule(e, False)
assert "above" not in e["message"], ("stdout, not 'above', holds the messages under --json", e["message"])
again = ok(db2, "--as", "b", "inbox")
assert [m["id"] for m in again["items"]] == [m["id"] for m in first["items"]], (again, first)
assert ok(db2, "--as", "b", "inbox")["items"] == [], "the second inbox did consume them"
p = subprocess.run([*agentbus_argv(), "--as", "b", "inbox"], cwd=tmp, env=dict(BASE, AGENTBUS_DB=db2, AGENTBUS_TEST_FAIL="ack"),
                   capture_output=True, text=True, timeout=60)
assert p.returncode == 0 and "inbox empty" in p.stdout, "nothing to acknowledge, nothing to fail"
print("PASS: ack: inbox exits non-zero with ack_failed, stdout holds the complete messages, the cursor is unchanged, and the next inbox returns the same ids")

# interrupted: ^C is a documented failure, with JSON on stderr and the commit state
def interrupt(args):
    d = os.path.join(tmp, "pause%d" % time.monotonic_ns()); os.makedirs(d)
    open(os.path.join(d, "after-open.go"), "w").close()   # mark the point, never stop there
    env = dict(BASE, AGENTBUS_DB=dbi, AGENTBUS_TEST_SLOW="5", AGENTBUS_TEST_PAUSE="after-open=" + d)
    # a background job starts with SIGINT ignored, and Python then leaves it ignored: start it as a terminal would
    p = subprocess.Popen([*agentbus_argv(), "--json", *args], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    deadline = time.time() + 20
    while not os.path.exists(os.path.join(d, "after-open.reached")):
        assert time.time() < deadline and p.poll() is None, "never reached the slow point"
        time.sleep(0.02)
    time.sleep(0.7)   # the command is instant once the bus is open; it is asleep in AGENTBUS_TEST_SLOW by now
    assert p.poll() is None, "it should still be asleep"
    p.send_signal(signal.SIGINT)
    out, err = p.communicate(timeout=20)
    return p.returncode, out, err
dbi = fresh("sigint")
ok(dbi, "--as", "a", "join")
def stored():
    con = sqlite3.connect(dbi)
    try:
        return con.execute("SELECT COUNT(*) FROM messages WHERE body='interrupted post'").fetchone()[0] == 1
    finally:
        con.close()
rc, out, err = interrupt(["--as", "a", "post", "interrupted post"])
e = json.loads(err)["error"]
assert (rc, out) == (130, ""), (rc, out, err)
assert len(err.splitlines()) == 1 and "Traceback" not in err, err
assert e["code"] == "interrupted" and e["retryable"] is False and e["committed"] is True, e   # no token: not safe to repeat
rule(e, False)
assert stored(), "committed: true is true, the post is on the bus"
rc, out, err = interrupt(["--as", "a", "who"])
e = json.loads(err)["error"]
assert (rc, out) == (130, "") and e["code"] == "interrupted" and e["committed"] is False and "Traceback" not in err, (rc, out, err)
assert rule(e, False)["retryable"] is True, "nothing was saved, so running it again is fine"
rc, out, err = interrupt(["--as", "a", "post", "tokened post", "--request-id", "tokI"])
e = rule(json.loads(err)["error"], True)
assert rc == 130 and e["committed"] is True and e["retryable"] is True, (rc, e)
assert ok(dbi, "--as", "a", "post", "tokened post", "--request-id", "tokI")["duplicate"] is True, "with the token the retry returns the saved post"
print("PASS: a real SIGINT during AGENTBUS_TEST_SLOW exits 130 with one JSON interrupted error, empty stdout, the commit state, and retryable false after a saved write without a token")

# a SIGINT that lands while the commit is happening must not hide the commit: it is held until the
# commit and the flag are done, then raised
dbw = fresh("window")
ok(dbw, "--as", "a", "join")
d = os.path.join(tmp, "commitpause"); os.makedirs(d)
env = dict(BASE, AGENTBUS_DB=dbw, AGENTBUS_TEST_PAUSE="commit=" + d)
w = subprocess.Popen([*agentbus_argv(), "--json", "--as", "a", "post", "in the window"], cwd=tmp, env=env, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
deadline = time.time() + 20
while not os.path.exists(os.path.join(d, "commit.reached")):
    assert time.time() < deadline and w.poll() is None, "never reached the commit"
    time.sleep(0.02)
w.send_signal(signal.SIGINT)      # the commit is next
time.sleep(0.3)
open(os.path.join(d, "commit.go"), "w").close()
out, err = w.communicate(timeout=20)
e = json.loads(err)["error"]
assert w.returncode == 130 and out == "" and e["code"] == "interrupted", (w.returncode, out, err)
assert e["committed"] is True and e["retryable"] is False, ("the commit happened, and the error must say so", e)
assert [m["body"] for m in ok(dbw, "read")["items"]] == ["in the window"], "the post is on the bus"
print("PASS: a SIGINT during the commit is held until the commit is recorded: committed true, the post stored")

# no other failure leaves stdout non-empty
for fail in ("parse", "open", "before-emit", "internal"):
    for args in COMMANDS:
        assert run(db, *args, fail=fail).stdout == "", (fail, args)
print("PASS: no other failure leaves stdout non-empty")
PY
echo "All failure phase tests passed"
