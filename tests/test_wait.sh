#!/bin/bash
set -euo pipefail
# agentbus wait: blocks until the name has unread messages or the timeout ends. Bugs it catches: wait marking messages
# read, holding the bus while it sleeps, counting a name's own or older broadcast messages, waiting on a name that never
# joined, a timeout that looks like success, and Ctrl-C that does not exit 130. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
export AGENTBUS_DB="$T/bus.db"
export AGENTBUS_TEST_WAIT_POLL=0.05   # the test hook that shortens the 2 s poll
for n in w s; do agentbus --as $n join --tool t >/dev/null; done
unread() { njson agentbus --json --as "${1:-w}" inbox --peek --limit -1; }

echo "TEST 1: messages already waiting end the wait at once; nothing is marked read"
agentbus --as s post "one" --to w >/dev/null
agentbus --as s post "two" >/dev/null
agentbus --as w post "mine" >/dev/null   # a name's own message never counts
out=$(outof agentbus --as w wait --timeout 5)
[ "$out" = "you have 2 unread messages. Read them with: agentbus --as w inbox" ] || fail "wait said: $out"
[ "$(unread)" = 2 ] || fail "wait changed what is unread: $(unread)"
o=$(json_ok agentbus --json --as w wait --timeout 5)
"$PY" - "$o" <<'PY' || fail "JSON result shape"
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"contract", "name", "unread", "waited_s", "next"}, d
assert d["name"] == "w" and d["unread"] == 2 and d["waited_s"] == 0 and d["next"] == "agentbus --as w inbox", d
PY
agentbus --as w inbox >/dev/null
ok "one line with the count and the next command, JSON the same, inbox still has them"

echo "TEST 2: no messages: the timeout ends with exit 124, a documented error, and says what to do"
err=$(mktemp); rc=0; start=$SECONDS
agentbus --as w wait --timeout 1 >/dev/null 2>"$err" || rc=$?
[ "$rc" = 124 ] || fail "timeout exit was $rc"
grep -qF "no unread messages for w after 1 s. To keep waiting: agentbus --as w wait" "$err" || { cat "$err"; fail "timeout message"; }
[ $((SECONDS - start)) -le 10 ] || fail "wait --timeout 1 took $((SECONDS - start)) s"
rc=0; agentbus --json --as w wait --timeout 1 >/dev/null 2>"$err" || rc=$?
[ "$rc" = 124 ] || fail "json timeout exit was $rc"
"$PY" - "$err" <<'PY' || fail "JSON timeout error"
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "wait_timeout" and e["retryable"] is True and e["committed"] is False, e
assert e["waited"] == 1 and e["next"] == "agentbus --as w wait", e
PY
agentbus --json schema | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["errors"]["wait_timeout"]["exit"]==124 and d["exit_codes"]["124"]' || fail "schema does not document exit 124"
rm -f "$err"
ok "exit 124, wait_timeout, retryable, documented in schema"

echo "TEST 3: a message that arrives during the wait ends it; the sender is not held up"
(agentbus --as w wait --timeout 30 >"$T/w3.out" 2>"$T/w3.err"; echo $? >"$T/w3.rc") &
pid=$!
sleep 0.5
s0=$SECONDS
agentbus --as s post "now" --to w >/dev/null
[ $((SECONDS - s0)) -le 3 ] || fail "a post waited $((SECONDS - s0)) s behind wait"
wait_exit "$pid" 20 "wait after a post"
[ "$(cat "$T/w3.rc")" = 0 ] || fail "wait exited $(cat "$T/w3.rc"): $(cat "$T/w3.err")"
grep -qF "you have 1 unread message. Read them with: agentbus --as w inbox" "$T/w3.out" || fail "wait said: $(cat "$T/w3.out")"
[ "$(unread)" = 1 ] || fail "wait marked the message read"
agentbus --as w inbox >/dev/null
ok "woken by a post, which was not blocked"

echo "TEST 3b: at its normal pace it sleeps with the bus free"
# Bug it catches: sleeping between looks with the bus open, so every writer queued behind wait for the whole sleep.
(env -u AGENTBUS_TEST_WAIT_POLL "${AB[@]}" --as w wait --timeout 30 >"$T/w3b.out" 2>&1; echo $? >"$T/w3b.rc") &
pid=$!
sleep 0.6
took=$("$PY" - "${AB[@]}" <<'PY'
import subprocess, sys, time
t = time.monotonic()
subprocess.run([*sys.argv[1:], "--as", "s", "post", "sleeping?", "--to", "w"], check=True, capture_output=True)
print(round(time.monotonic() - t, 2))
PY
)
"$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.2 else 1)' "$took" || fail "a post took $took s while wait slept"
wait_exit "$pid" 20 "wait at its normal pace"
[ "$(cat "$T/w3b.rc")" = 0 ] || fail "wait exited $(cat "$T/w3b.rc"): $(cat "$T/w3b.out")"
agentbus --as w inbox >/dev/null
ok "a post was not held up by the 2 s sleep"

echo "TEST 4: its own messages and broadcasts from before it joined do not wake it"
agentbus --as s post "before x joined" >/dev/null
agentbus --as x join --tool t >/dev/null
agentbus --as x post "mine" >/dev/null
agentbus --as x post "also mine" --to x >/dev/null
rc=0; agentbus --as x wait --timeout 1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 124 ] || fail "wait counted a message x should not see (exit $rc)"
ok "only what inbox would show counts"

echo "TEST 5: a name that never joined, and a timeout out of range, fail at once"
rc=0; start=$SECONDS; agentbus --as ghost wait --timeout 3 >/dev/null 2>"$T/g.err" || rc=$?
[ "$rc" = 1 ] && grep -qF "ghost is not on the roster" "$T/g.err" || fail "ghost: exit $rc: $(cat "$T/g.err")"
[ $((SECONDS - start)) -le 5 ] || fail "wait for an unjoined name waited"
for t in 0 -1 1801; do expect_fail "--timeout must be at least 1 and at most 1800 seconds" agentbus --as w wait --timeout "$t"; done
expect_fail "say who you are" agentbus wait
ok "refused before waiting"

echo "TEST 6: Ctrl-C exits 130 with one interrupted error"
agentbus --as w inbox >/dev/null   # nothing unread, so wait keeps waiting
"$PY" - "${AB[@]}" <<'PY' || fail "Ctrl-C did not exit 130 with one interrupted error"
import json, os, signal, subprocess, sys, time
argv = sys.argv[1:]
env = dict(os.environ, AGENTBUS_TEST_WAIT_POLL="0.05")
# a background job starts with SIGINT ignored, and Python then leaves it ignored: start it as a terminal would
p = subprocess.Popen([*argv, "--json", "--as", "w", "wait", "--timeout", "60"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
time.sleep(1.0)
assert p.poll() is None, "wait ended before it was interrupted"
p.send_signal(signal.SIGINT)
out, err = p.communicate(timeout=20)
e = json.loads(err)["error"]
assert (p.returncode, out) == (130, ""), (p.returncode, out, err)
assert e["code"] == "interrupted" and e["committed"] is False and "Traceback" not in err, err
PY
ok "SIGINT: 130, stdout empty, interrupted"

echo "TEST 7: wait counts as being seen"
"$PY" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE agents SET last_seen='2000-01-01T00:00:00Z' WHERE name='s'\"); c.commit()" "$AGENTBUS_DB"
agentbus --as s post "for s" --to w >/dev/null
agentbus --as w post "for s" --to s >/dev/null
agentbus --as s wait --timeout 5 >/dev/null
seen=$(agentbus --json who | "$PY" -c 'import json,sys; print([r["last_seen"] for r in json.load(sys.stdin)["items"] if r["name"]=="s"][0])')
[ "$seen" != "2000-01-01T00:00:00Z" ] || fail "wait did not refresh last_seen"
ok "last_seen refreshed"
echo "TEST 8: after a long wait it is seen again when it ends"
agentbus --as w inbox >/dev/null
(agentbus --as w wait --timeout 30 >"$T/w8.out" 2>&1; echo $? >"$T/w8.rc") &
pid=$!
sleep 0.5
"$PY" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1], timeout=20); c.execute(\"UPDATE agents SET last_seen='2000-01-01T00:00:00Z' WHERE name='w'\"); c.commit()" "$AGENTBUS_DB"
agentbus --as s post "wake" --to w >/dev/null
wait_exit "$pid" 20 "wait for the wake message"
[ "$(cat "$T/w8.rc")" = 0 ] || fail "wait exited $(cat "$T/w8.rc"): $(cat "$T/w8.out")"
seen=$(agentbus --json who | "$PY" -c 'import json,sys; print([r["last_seen"] for r in json.load(sys.stdin)["items"] if r["name"]=="w"][0])')
[ "$seen" != "2000-01-01T00:00:00Z" ] || fail "wait left last_seen at its old value after waiting"
ok "last_seen refreshed at the end"
echo "All tests passed!"
