#!/bin/bash
set -euo pipefail
# `agentbus demo`: a hands-off tour on a temporary bus. It prints each command as it runs, shows a claim refused,
# never touches the bus of the folder it runs in, and leaves nothing behind, whether it finishes, is stopped, or fails.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
W="$T/work"; mkdir -p "$W"
# A folder with a bus of its own, holding a message, that the demo must not touch.
export AGENTBUS_DB="$W/.agentbus/bus.db"; mkdir -p "$W/.agentbus"
agentbus --as real join >/dev/null
agentbus --as real post "do not touch" --to nobody >/dev/null
unset AGENTBUS_DB
export AGENTBUS_AGENT=forbidden        # the demo must discard every inherited bus setting
snap() { (cd "$W" && find . -type f -print0 | sort -z | xargs -0 cksum; sqlite3 .agentbus/bus.db 'select * from messages; select * from agents' 2>/dev/null || true); }
snap >/dev/null   # reading the bus with sqlite3 folds its -wal into bus.db: settle that before the baseline
BEFORE=$(snap)
TMPD="$T/tmpdir"; mkdir -p "$TMPD"
empty_tmp() { [ -z "$(ls -A "$TMPD")" ] || fail "$1: the demo left files behind: $(ls -A "$TMPD")"; }

echo "TEST 1: the tour runs, prints each command, shows the refusal, and ends clean"
# The folder's own bus and a test hook are poisoned in the environment: the steps must see neither.
out=$(cd "$W" && TMPDIR="$TMPD" AGENTBUS_DB="$W/.agentbus/bus.db" AGENTBUS_TEST_FAIL=internal "${AB[@]}" demo --no-pause 2>"$T/err") \
  || fail "a test hook or the inherited bus reached the demo's steps: $(cat "$T/err")"
printf '%s\n' "$out" >"$T/out"
"$PY" - "$T/out" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
cmds = re.findall(r'^\$ (agentbus .*)$', text, re.M)
want = ["--as lead join", "--as worker join", "--as lead goal", "--as lead post", "--as worker claim src/auth/",
        "--as lead claim src/auth/login.py", "--as worker post", "--as lead brief", "--as worker release src/auth/"]
at = -1
for w in want:
    nxt = next((i for i, c in enumerate(cmds) if i > at and c.startswith("agentbus " + w)), None)
    if nxt is None:
        print("FAIL: the tour has no `agentbus %s` after step %d; it ran: %s" % (w, at, cmds))
        sys.exit(1)
    at = nxt
if "--kind handoff" not in next(c for c in cmds if c.startswith("agentbus --as worker post")):
    print("FAIL: the worker's post is not a handoff: %s" % cmds)
    sys.exit(1)
if not re.search(r"^agentbus: src/auth/login\.py overlaps src/auth/, claimed by worker", text, re.M):
    print("FAIL: the conflicting claim's refusal is not shown:\n" + text)
    sys.exit(1)
if not re.search(r"^# .*refused", text, re.M | re.I):
    print("FAIL: nothing tells the reader the refusal is the point:\n" + text)
    sys.exit(1)
if "goal: " not in text or "unread" not in text:
    print("FAIL: the tour never shows the goal or brief's unread section:\n" + text)
    sys.exit(1)
if "agentbus watch" not in text:
    print("FAIL: the tour does not say how to watch the bus:\n" + text)
    sys.exit(1)
print(len(cmds), "commands, in order")
PY
empty_tmp "tour"
[ "$(snap)" = "$BEFORE" ] || fail "the demo changed the bus or the files of the folder it ran in"
grep -q 'forbidden' "$T/out" && fail "the demo used the inherited AGENTBUS_AGENT" || true
ok "the tour prints its commands in order, shows the refusal, and leaves the folder and TMPDIR as they were"

echo "TEST 2: --json runs the same tour silently and reports each step"
o=$(cd "$W" && TMPDIR="$TMPD" outof "${AB[@]}" --json demo)
printf '%s' "$o" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["cleaned"] is True, d
steps = d["steps"]
assert [s["exit"] for s in steps].count(1) == 1, ("exactly the conflicting claim is refused", steps)
assert all(s["command"].startswith("agentbus ") for s in steps) and len(steps) >= 9, steps
refused = [s for s in steps if s["exit"] == 1][0]
assert "claim src/auth/login.py" in refused["command"], refused
' || fail "demo --json result"
empty_tmp "json"
[ "$(snap)" = "$BEFORE" ] || fail "demo --json changed the folder it ran in"
ok "--json: one object, the one refusal, cleaned true"

echo "TEST 3: stopped with Ctrl-C (SIGINT) or SIGTERM mid-tour, it cleans up and exits 130"
# A background job starts with SIGINT ignored and Python then leaves it ignored: start it as a terminal would.
"$PY" - "$W" "$TMPD" "$T" <<'PY'
import os, signal, subprocess, sys, time
sys.path.insert(0, os.environ["TESTS_DIR"])
from agentbus_cmd import agentbus_argv
work, tmpd, t = sys.argv[1:]
for name in ("SIGINT", "SIGTERM"):
    pause = os.path.join(t, "pause-" + name); os.makedirs(pause)
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBUS_")}
    env.update(TMPDIR=tmpd, AGENTBUS_TEST_PAUSE="demo-step=" + pause)
    p = subprocess.Popen([*agentbus_argv(), "demo"], cwd=work, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    end = time.time() + 30
    while not os.path.exists(os.path.join(pause, "demo-step.reached")):
        if p.poll() is not None or time.time() > end:
            p.kill()
            print("FAIL: %s: the demo never reached its first step: %s" % (name, p.communicate()))
            sys.exit(1)
        time.sleep(0.02)
    if not os.listdir(tmpd):
        p.kill()
        print("FAIL: fixture: the demo had made no directory when it was stopped")
        sys.exit(1)
    p.send_signal(getattr(signal, name))
    try:
        out, err = p.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        p.kill()
        print("FAIL: %s: the demo was still running 20 s after the signal" % name)
        sys.exit(1)
    if p.returncode != 130 or "interrupted" not in err:
        print("FAIL: %s: exit %s, stderr %r (want 130 and an interrupted message)" % (name, p.returncode, err))
        sys.exit(1)
    if os.listdir(tmpd):
        print("FAIL: %s: the demo left files behind: %s" % (name, os.listdir(tmpd)))
        sys.exit(1)
PY
[ "$(snap)" = "$BEFORE" ] || fail "the folder changed"
ok "SIGINT and SIGTERM: exit 130, directory removed, nothing left in TMPDIR"

echo "TEST 4: a step that fails unexpectedly stops the tour with an error and still cleans up"
rc=0; (cd "$W" && TMPDIR="$TMPD" AGENTBUS_TEST_FAIL=demo "${AB[@]}" demo --no-pause >"$T/f-out" 2>"$T/f-err") || rc=$?
[ "$rc" = 4 ] || fail "an injected failure exited $rc, not 4: $(cat "$T/f-err")"
grep -q 'agentbus: ' "$T/f-err" || fail "no diagnostic for the failure: $(cat "$T/f-err")"
empty_tmp "failure"
ok "an unexpected failure exits 4 and removes the directory"

echo "TEST 5: --watch without a terminal says so and still finishes"
out=$(cd "$W" && TMPDIR="$TMPD" outof "${AB[@]}" demo --no-pause --watch </dev/null 2>&1)
grep -qi 'watch needs a terminal' <<<"$out" || fail "--watch without a terminal did not say so: $out"
empty_tmp "watch"
ok "--watch off a terminal is a note, not a hang or a failure"

echo "TEST 6: the demo is outside any repo: its directory is under TMPDIR and holds the whole bus"
out=$(cd "$W" && TMPDIR="$TMPD" "${AB[@]}" demo --no-pause)
dir=$(sed -n 's/^.*on \(\/[^ ]*\)\/bus\.db.*$/\1/p' <<<"$out" | head -n 1)
case "$dir" in "$TMPD"/*) ;; *) fail "the demo bus is not under TMPDIR ($TMPD): '$dir'" ;; esac
ok "the demo bus lives under TMPDIR"
echo "All demo tests passed"
