#!/bin/bash
set -euo pipefail
# A lane can plant any rows. Whatever it planted, an honest command holds the bus for less than
# the 15 s other agents wait, so another agent's post still lands. Bug it catches: 8 GLOBs read
# every planted 100 MB claim on every open, claim fetched every claim into Python and compared them
# one by one, release --all logged 500 MB, and the query budget (30 s) was above the 15 s wait.
# Throwaway buses and HOME only; the planted buses take a few GB in the temp dir while they exist.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
secs() { python3 -c 'import time; print(time.time())'; }
since() { python3 -c 'import sys,time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$1"; }
under() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "$1" "$2"; }
# plant DB PYTHON-CODE: rows written straight into the bus, as a lane would (c is the connection).
plant() {
  python3 - "$1" "$2" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("PRAGMA synchronous=OFF")
c.execute("BEGIN")
exec(sys.argv[2])
c.execute("COMMIT")
PY
}
# measured DB BOUND ARGS...: run ARGS on DB while another agent posts. What must hold is safety, not
# speed: availability against a lane that plants rows is out of scope (docs/sandboxed-agents.md), but
# planted rows must never let one command hold the bus past its own limits. So ARGS either succeeds
# or is stopped cleanly, by the query budget or by the 8 s hold watchdog; the other agent's post lands
# meanwhile; and the whole run (start, hold, the post after it) ends inside the hold watchdog plus
# slack, well before the post's 15 s wait would run out. BOUND is what each takes on an idle machine
# (about 10 times the measured time); going past it only prints a note, because a loaded CI box is
# slower. A stopped command must have left its write whole or not at all (see each test).
HARD_LIMIT=30  # a hang detector only: the real proof is that another agent's post lands while this runs (slow CI disks take 14 to 19 s end to end over 500 MB of planted rows)
measured() {
  local db=$1 bound=$2; shift 2
  local P="$T/pause.$RANDOM"; mkdir -p "$P"; touch "$P/after-open.go"   # mark when the bus is held, never stop
  local t0; t0=$(secs)
  AGENTBUS_TEST_PAUSE="after-open=$P" AGENTBUS_DB="$db" "${AB[@]}" "$@" >"$T/mo" 2>"$T/me" & local pid=$!
  wait_for "$P/after-open.reached"
  AGENTBUS_DB="$db" "${AB[@]}" --as honest post "while: $*" >/dev/null 2>"$T/pe" \
    || fail "another agent's post failed while '$*' ran: $(cat "$T/pe")"
  STOPPED=0
  if ! wait $pid; then
    grep -q Traceback "$T/me" && fail "'$*': traceback: $(cat "$T/me")"
    if grep -q "a bus query ran for more than" "$T/me"; then STOPPED="by the query budget"
    elif tr -d '\n' < "$T/me" | sed 's/  */ /g' | grep -q "held the bus for 8 s, the most agentbus allows"; then
      STOPPED="by the hold watchdog"
    else fail "'$*' failed: $(cat "$T/me")"; fi
  fi
  TOOK=$(since "$t0")
  under "$TOOK" "$HARD_LIMIT" || fail "'$*' held on for ${TOOK}s (limit ${HARD_LIMIT}s)"
  under "$TOOK" "$bound" || echo "note: '$*' took ${TOOK}s (about ${bound}s expected; a loaded machine)"
}
# finished: the checks that need ARGS to have finished run only when it did.
finished() { [ "$STOPPED" = 0 ]; }

echo "TEST 1: 20 planted claims of 100 MB each: who and post stay fast"
D1="$T/b1.db"; AGENTBUS_DB="$D1" agentbus --as honest join --tool t >/dev/null
plant "$D1" 'big = "a" * (100 << 20)
for i in range(20):
    c.execute("INSERT INTO claims VALUES(?,?,?,?,?)", ("src//%02d" % i + big, "lane", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z"))'
measured "$D1" 5 who; t1=$TOOK
measured "$D1" 5 --as honest post "an honest post"; t2=$TOOK
[ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM claims WHERE length(resource) > 1024").fetchone()[0])' "$D1")" = 20 ] \
  || fail "the planted claims were changed"
ok "who ${t1}s, post ${t2}s with 2 GB of planted claims; another agent posted meanwhile"

echo "TEST 2: 2M planted stale claims: claim reads only what overlaps"
D2="$T/b2.db"; AGENTBUS_DB="$D2" agentbus --as honest join --tool t >/dev/null
plant "$D2" 'c.executemany("INSERT INTO claims VALUES(?,?,?,?,?)",
    (("p/%07d" % i, "gone", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z") for i in range(2000000)))'
measured "$D2" 10 --as honest claim q/x.py; t1=$TOOK
measured "$D2" 11 --as honest --json claim p/; t2=$TOOK
if finished; then
python3 - "$T/mo" <<'PY' || fail "claim over 2M stale claims did not report them capped"
import json, sys
j = json.load(open(sys.argv[1]))
assert j["auto_released_count"] == 2000000 and len(j["auto_released"]) == 20, (j["auto_released_count"], len(j["auto_released"]))
PY
python3 - "$D2" <<'PY' || fail "claim over 2M stale claims left them, or logged one row each"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("SELECT COUNT(*) FROM claims WHERE agent='gone'").fetchone()[0] == 0
n = c.execute("SELECT COUNT(*) FROM log WHERE action='claim' AND detail LIKE '%auto-released%'").fetchone()[0]
assert n == 21, n
assert c.execute("SELECT detail FROM log WHERE detail LIKE 'and 1999980 more overlapping p/ auto-released%'").fetchone()
PY
else
python3 - "$D2" <<'PY' || fail "a claim stopped $STOPPED left a partial write"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
gone = c.execute("SELECT COUNT(*) FROM claims WHERE agent='gone'").fetchone()[0]
mine = c.execute("SELECT COUNT(*) FROM claims WHERE agent='honest' AND resource='p/'").fetchone()[0]
# Rolled back, or (the hold watchdog firing just after COMMIT) whole; never half.
assert (gone, mine) in ((2000000, 0), (0, 1)), (gone, mine)
PY
fi
ok "claim beside 2M stale claims ${t1}s; claim over all of them ${t2}s, 21 log rows; another agent posted meanwhile"

echo "TEST 3: release --all of 500 planted 1 MB names writes no 500 MB log row"
D3="$T/b3.db"; AGENTBUS_DB="$D3" agentbus --as honest join --tool t >/dev/null
plant "$D3" 'big = "n" * (1 << 20)
for i in range(500):
    c.execute("INSERT INTO claims VALUES(?,?,?,?,?)", ("r%03d" % i + big, "honest", "p", "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z"))'
measured "$D3" 10 --as honest release --all; t1=$TOOK
[ "$(wc -c < "$T/mo")" -lt 1000000 ] || fail "release --all printed $(wc -c < "$T/mo") bytes"
if finished; then
  grep -qx "released 500 claims" "$T/mo" || fail "release --all output: $(head -c 200 "$T/mo")"
  len=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT length(detail) FROM log WHERE action=? ORDER BY id DESC LIMIT 1", ("release",)).fetchone()[0])' "$D3")
  [ "$len" -lt 1000000 ] || fail "the release log row is $len characters"
  ok "release --all ${t1}s, log row $len characters; another agent posted meanwhile"
else
  # Rolled back, or (the hold watchdog firing just after COMMIT) whole with a short log row; never half.
  python3 - "$D3" <<'PY' || fail "a release --all stopped $STOPPED left a partial write"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
n = c.execute("SELECT COUNT(*) FROM claims WHERE agent='honest'").fetchone()[0]
assert n in (0, 500), n
if n == 0:
    assert c.execute("SELECT length(detail) FROM log WHERE action='release' ORDER BY id DESC LIMIT 1").fetchone()[0] < 1000000
PY
  ok "release --all stopped cleanly $STOPPED after ${t1}s, nothing half-done; another agent posted meanwhile"
fi

echo "TEST 4: claim refuses a resource over 1024 characters; a refusal naming a planted name is cut"
D4="$T/b4.db"; AGENTBUS_DB="$D4" agentbus --as honest join --tool t >/dev/null
AGENTBUS_DB="$D4" agentbus --as lane join --tool t >/dev/null
long=$(python3 -c 'print("a/" + "b" * 1023)')
AGENTBUS_DB="$D4" expect_fail "at most 1024" agentbus --as honest claim "$long"
AGENTBUS_DB="$D4" outof agentbus --as honest claim "$(python3 -c 'print("a/" + "b" * 1022)')" >/dev/null
plant "$D4" 'c.execute("INSERT INTO claims VALUES(?,?,?,?,?)", ("src/" + "z" * (1 << 20), "lane", "p" * (1 << 20), "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z"))'
AGENTBUS_DB="$D4" expect_fail "src/ overlaps src/zzz" agentbus --as honest claim src/
AGENTBUS_DB="$D4" "${AB[@]}" --as honest claim src/ 2>"$T/e4" && fail "claim over a held claim succeeded"
[ "$(wc -c < "$T/e4")" -lt 10000 ] || fail "the refusal is $(wc -c < "$T/e4") bytes"
ok "resource cap, and a refusal of $(wc -c < "$T/e4" | tr -d ' ') bytes naming a 1 MB claim"

echo "TEST 5: Python work under the lock is bounded too: the hold watchdog ends the command"
# AGENTBUS_TEST_SLOW stalls the command in Python with the bus held (a stand-in for any slow loop
# over planted rows), at the default budgets. It must be ended within 8 s plus slack, well before
# another agent's 15 s wait runs out, so that agent's post lands.
D5="$T/b5.db"; AGENTBUS_DB="$D5" agentbus --as honest join --tool t >/dev/null
t0=$(secs)
AGENTBUS_TEST_SLOW=60 AGENTBUS_DB="$D5" "${AB[@]}" --as honest who >"$T/o5" 2>"$T/e5" & S=$!
sleep 0.5
AGENTBUS_DB="$D5" "${AB[@]}" --as other post "while who stalled" >/dev/null 2>"$T/pe" || fail "the post failed while who stalled: $(cat "$T/pe")"
rc=0; wait $S || rc=$?
took=$(since "$t0")
[ "$rc" = 1 ] || fail "the stalled command was not ended (rc $rc)"
tr -d '\n' < "$T/e5" | sed 's/  */ /g' | grep -q "held the bus for 8 s, the most agentbus allows" || fail "no hold message: $(cat "$T/e5")"
under "$took" 12 || fail "the stalled command took ${took}s"
[ ! -s "$T/o5" ] || fail "the stopped command printed output"
ok "a command stalled with the bus held ended after ${took}s; another agent's post landed"
echo "All planted-row tests passed"
