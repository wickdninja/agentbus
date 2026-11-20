#!/bin/bash
set -euo pipefail
# The fact, goal, atomicity, error, limit and version requirements of docs/protocol.md (P-FACT-1 to P-FACT-9, P-ATOM-1 to
# P-ATOM-3, P-ERR-1, P-LIM-1, P-VER-1), one section each, every check printing its own FAIL line. tests/test_workflows.sh,
# tests/test_failure_phases.sh and tests/test_inputs.sh pin the paths and the wording around them; this file pins the
# rules, so a mutation of one rule (tests/mutations.json, field "must") fails here for that rule's reason.
# A fault in the middle of an operation is a table that has run out of ids (a row planted with the largest id SQLite
# allows): the insert into it fails after the earlier writes of the same operation. Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cd "$T"
N=0
# fresh: a new empty bus, named by a counter.
fresh() { N=$((N + 1)); export AGENTBUS_DB="$T/bus$N.db"; }
# sql STATEMENT [ARG...]: one write straight into the bus, as a tool that planted rows would.
sql() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$AGENTBUS_DB" "$@"; }
# rows STATEMENT [ARG...]: the first column of every row, one per line.
rows() { python3 -c 'import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2], sys.argv[3:])]' "$AGENTBUS_DB" "$@"; }
one() { rows "$@" | head -1; }
count() { one "SELECT COUNT(*) FROM $1"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
# fillids TABLE: the table's next insert fails ("database or disk is full"): a row with the largest id is already there.
fillids() {
  case "$1" in
    log) sql "INSERT INTO log(id,ts,agent,action,detail) VALUES(9223372036854775807,'2020-01-01T00:00:00Z','x','y','z')" ;;
    context_history) sql "INSERT INTO context_history(id,key,value,updated_by,updated_at) VALUES(9223372036854775807,'zz','v','x','2020-01-01T00:00:00Z')" ;;
  esac
}
# snap: every table of the bus, one text, to compare before and after.
snap() {
  python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for t in ("agents", "messages", "cursors", "context", "context_history", "claims", "log"):
    print(t, sorted(map(tuple, c.execute("SELECT * FROM " + t))))
PY
}
# snapdata: the same without the roster, whose last_seen any command under a name refreshes (P-ID-4).
snapdata() { snap | grep -v '^agents '; }
# jfail CODE cmd...: the command exits non-zero with this JSON error code on stderr.
jfail() {
  local want=$1; shift
  local e; e=$(mktemp)
  local line="$*"; line=${line:0:200}
  if "$@" >/dev/null 2>"$e"; then fail "expected $want but succeeded: $line"; fi
  python3 - "$want" "$e" <<'PY' || fail "wrong error from: $line ($(head -c 300 "$e"))"
import json, sys
assert json.load(open(sys.argv[2]))["error"]["code"] == sys.argv[1]
PY
}

fresh
for n in fa fb; do agentbus --as $n join --tool t >/dev/null; done

echo "TEST P-FACT-1: ctx set is last-writer-wins, with no compare-and-set and no delete"
# Bug it catches (mutation): the first value kept, the setter not updated, or a delete.
agentbus --as fa ctx set lww "first" >/dev/null
agentbus --as fb ctx set lww "second" >/dev/null
[ "$(agentbus ctx get lww | tr -d ' ')" = "second" ] || fail "the second writer did not win: $(agentbus ctx get lww)"
[ "$(one "SELECT updated_by FROM context WHERE key='lww'")" = fb ] || fail "the fact was not credited to the last writer: $(one "SELECT updated_by FROM context WHERE key='lww'")"
if agentbus --as fa ctx delete lww >/dev/null 2>&1 || agentbus --as fa ctx unset lww >/dev/null 2>&1; then fail "ctx has a delete"; fi
if agentbus --as fa ctx set lww "third" --if-value first >/dev/null 2>&1; then fail "ctx set has a compare-and-set"; fi
[ "$(one "SELECT value FROM context WHERE key='lww'")" = second ] || fail "a refused ctx variant changed the fact"
ok "the last writer wins, no delete, no compare-and-set"

echo "TEST P-FACT-2: setting the value a fact holds writes no fact, history or log row and says unchanged"
# Bug it catches (mutation): a repeat that writes a history row, takes over the setter or the time, or does not say unchanged.
sql "UPDATE context SET updated_at='2020-05-05T05:05:05Z' WHERE key='lww'"
h=$(count context_history); l=$(count log)
r=$(json_ok agentbus --json --as fa ctx set lww "second")
[ "$(field "$r" unchanged)" = True ] || fail "a repeat of the same value was not reported unchanged: $r"
[ "$(field "$r" updated_by)" = fb ] && [ "$(field "$r" updated_at)" = 2020-05-05T05:05:05Z ] || fail "a repeat of the same value did not keep the previous setter and time: $r"
[ "$(one "SELECT updated_by||updated_at FROM context WHERE key='lww'")" = "fb2020-05-05T05:05:05Z" ] || fail "a repeat of the same value changed the stored fact"
[ "$(count context_history)" = "$h" ] || fail "a repeat of the same value wrote a history row"
[ "$(count log)" = "$l" ] || fail "a repeat of the same value wrote a log row"
r=$(json_ok agentbus --json --as fa ctx set lww "third")
[ "$(field "$r" unchanged)" = False ] || fail "a new value was reported unchanged: $r"
ok "a repeat writes nothing and keeps the setter and time"

echo "TEST P-FACT-3: a change writes the fact and one history row in the same atomic step"
# Bug it catches (mutation): two history rows, none, or the fact kept when the history row fails.
h=$(count context_history)
agentbus --as fa ctx set one-row "v1" >/dev/null
[ "$(count context_history)" = $((h + 1)) ] || fail "one change wrote $(( $(count context_history) - h )) history rows"
[ "$(one "SELECT value FROM context_history WHERE key='one-row'")" = v1 ] || fail "the history row does not hold the value"
fresh; agentbus --as fa join >/dev/null; fillids context_history
before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as fa ctx set half v
[ "$(snap)" = "$before" ] || fail "ctx set changed something and then failed: the fact was written without its history row"
ok "one history row, and the fact only with it"

echo "TEST P-FACT-4: ctx set on the key goal is refused with bad_input"
# Bug it catches (mutation): the reserved key writable through ctx set.
fresh; agentbus --as fa join >/dev/null
jfail bad_input "${AB[@]}" --json --as fa ctx set goal "sneaky"
[ "$(count context)" = 0 ] || fail "ctx set goal stored a fact"
ok "goal is reserved"

echo "TEST P-FACT-5: ctx get of a missing key refuses with no_context_key"
# Bug it catches (mutation): another code, or an empty success.
jfail no_context_key "${AB[@]}" --json ctx get nothing-here
ok "no_context_key"

echo "TEST P-FACT-6: ctx history lists a key's values in the order they were written"
# Bug it catches (mutation): newest first, or sorted by value.
for v in zeta alpha mid; do agentbus --as fa ctx set order "$v" >/dev/null; done
got=$(agentbus --json ctx history order | python3 -c 'import json,sys; print(" ".join(r["value"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "zeta alpha mid" ] || fail "ctx history listed: $got (written zeta, alpha, mid)"
ok "written order"

echo "TEST P-FACT-9: ctx get with no key lists every fact except goal; ctx get goal and ctx history goal read it"
# Bug it catches (mutation): the goal listed with the facts, or not readable by name.
agentbus --as fa ctx set zz-fact "last" >/dev/null
agentbus --as fa goal "the shared goal" >/dev/null
got=$(agentbus --json ctx get | python3 -c 'import json,sys; print(" ".join(r["key"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "order zz-fact" ] || fail "ctx get listed: $got (every fact but goal)"
[ "$(agentbus ctx get goal | tr -d ' ')" = "thesharedgoal" ] || fail "ctx get goal did not read the goal: $(agentbus ctx get goal)"
agentbus --json ctx history goal | grep -qF "the shared goal" || fail "ctx history goal did not list the goal"
ok "goal hidden from the list, readable by name"

echo "TEST P-FACT-7: goal TEXT sets the fact goal under the rules of ctx set, logs a goal row when it changed, and any name on the roster may set it"
# Bug it catches (mutation): no history row, a goal that is not last-writer-wins, a repeat that writes, a goal row for a repeat, the fact written without its row.
fresh
for n in ga gb; do agentbus --as $n join >/dev/null; done
agentbus --as ga goal "first goal" >/dev/null
agentbus --as gb goal "second goal" >/dev/null
[ "$(one "SELECT value||'|'||updated_by FROM context WHERE key='goal'")" = "second goal|gb" ] || fail "the goal is $(one "SELECT value||'|'||updated_by FROM context WHERE key='goal'") (want the second writer's)"
[ "$(one "SELECT COUNT(*) FROM context_history WHERE key='goal'")" = 2 ] || fail "two goal changes wrote $(one "SELECT COUNT(*) FROM context_history WHERE key='goal'") history rows"
[ "$(one "SELECT COUNT(*) FROM log WHERE action='goal'")" = 2 ] || fail "two goal changes wrote $(one "SELECT COUNT(*) FROM log WHERE action='goal'") goal rows"
r=$(json_ok agentbus --json --as ga goal "second goal")
[ "$(field "$r" unchanged)" = True ] || fail "an unchanged goal was not reported unchanged: $r"
[ "$(one "SELECT COUNT(*) FROM context_history WHERE key='goal'")" = 2 ] && [ "$(one "SELECT COUNT(*) FROM log WHERE action='goal'")" = 2 ] || fail "an unchanged goal wrote a row"
fresh; agentbus --as ga join >/dev/null; fillids log
before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as ga goal "never stored"
[ "$(snap)" = "$before" ] || fail "goal changed something and then failed: the goal was stored without its log row"
ok "last writer, history, one goal row per change, nothing half stored"

echo "TEST P-FACT-8: goal with no text shows the current goal, or none, and changes nothing"
# Bug it catches (mutation): the goal not shown, or a show that writes.
fresh; agentbus --as ga join >/dev/null
r=$(json_ok agentbus --json goal)
[ "$(field "$r" goal)" = None ] || fail "goal with none set showed: $r"
agentbus --as ga goal "shown goal" >/dev/null
before=$(snapdata)
r=$(json_ok agentbus --json goal)
[ "$(field "$r" goal)" = "shown goal" ] || fail "goal did not show the current goal: $r"
json_ok agentbus --json --as ga goal >/dev/null
[ "$(snapdata)" = "$before" ] || fail "showing the goal changed the bus"
ok "shown, nothing changed"

echo "TEST P-ATOM-1 and P-ATOM-2: the steps of one operation take effect together or not at all; no other operation interleaves"
# Bug it catches (mutation): a commit between two writes of one operation (join's roster and log, leave's claims and roster,
# release's delete and log, a --from move's delete and claim), or a write lock that lets a second claim read before the first commits.
fresh
agentbus --as other join >/dev/null; fillids log; before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as jn join --tool t
[ "$(snap)" = "$before" ] || fail "join changed something and then failed: $(( $(count agents) )) roster rows, $(count cursors) cursors"
fresh; agentbus --as lv join >/dev/null; agentbus --as lv claim lv/a.py lv/b.py >/dev/null; fillids log; before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as lv leave
[ "$(snap)" = "$before" ] || fail "leave changed something and then failed: $(count claims) claims and $(count agents) roster rows are left"
fresh; agentbus --as rl join >/dev/null; agentbus --as rl claim rl/a.py rl/b.py >/dev/null; fillids log; before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as rl release rl/a.py
[ "$(snap)" = "$before" ] || fail "release changed something and then failed"
jfail bus_unavailable "${AB[@]}" --json --as rl release --all
[ "$(snap)" = "$before" ] || fail "release --all changed something and then failed"
fresh; agentbus --as hold join >/dev/null; agentbus --as take join >/dev/null; agentbus --as hold claim mv/f.py >/dev/null; fillids log; before=$(snap)
jfail bus_unavailable "${AB[@]}" --json --as take claim mv/f.py --from hold
[ "$(snap)" = "$before" ] || fail "claim --from changed something and then failed: the holder's claim is $(one "SELECT COALESCE((SELECT agent FROM claims WHERE resource='mv/f.py'),'gone')")"
# no interleaving: the second claim waits for the first to commit, then sees it
fresh; agentbus --as ra join >/dev/null; agentbus --as rb join >/dev/null
P="$T/pause"; mkdir -p "$P"
AGENTBUS_TEST_PAUSE="commit=$P" agentbus --as ra claim race.py >"$T/oa" 2>"$T/ea" & PA=$!
wait_for "$P/commit.reached"
"${AB[@]}" --json --as rb claim race.py >"$T/ob" 2>"$T/eb" & PB=$!
sleep 1
touch "$P/commit.go"
wait_exit "$PA" 20 "the first claim"; [ "$WAIT_RC" = 0 ] || fail "the first claim failed: $(cat "$T/ea")"
wait_exit "$PB" 20 "the second claim"
[ "$WAIT_RC" != 0 ] && grep -q '"claim_conflict"' "$T/eb" || fail "a claim made while another was committing did not see it: rb got $(cat "$T/ob") $(cat "$T/eb")"
[ "$(one "SELECT agent FROM claims WHERE resource='race.py'")" = ra ] || fail "the claim is held by $(one "SELECT agent FROM claims WHERE resource='race.py'")"
ok "no operation leaves half its steps, and a second writer waits"

echo "TEST P-ATOM-3: every time an operation writes comes from the writing process's clock, in UTC, at one-second resolution"
# Bug it catches (mutation): a time from another clock (the database's), with fractions, or in local time.
fresh
export AGENTBUS_TEST_NOW=2031-02-03T04:05:06Z
agentbus --as ck join >/dev/null
agentbus --as ck post "timed" >/dev/null
agentbus --as ck ctx set clockkey v >/dev/null
agentbus --as ck claim clock.py --ttl-min 10 >/dev/null
agentbus --as ck log add act detail >/dev/null
agentbus --as ck goal "timed goal" >/dev/null
unset AGENTBUS_TEST_NOW
bad=$(python3 - "$AGENTBUS_DB" <<'PY'
import re, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
want = {("agents", "joined_at"), ("agents", "last_seen"), ("messages", "ts"), ("context", "updated_at"), ("context_history", "updated_at"),
        ("claims", "claimed_at"), ("log", "ts")}
for t, col in sorted(want):
    for (v,) in c.execute(f"SELECT {col} FROM {t}"):
        if not re.fullmatch(r"2031-02-03T04:0[5-9]:[0-9][0-9]Z", v):
            print(f"{t}.{col} = {v}")
(e,) = c.execute("SELECT expires_at FROM claims").fetchone()
if not re.fullmatch(r"2031-02-03T04:1[5-9]:[0-9][0-9]Z", e):
    print("claims.expires_at = " + e)
PY
)
[ -z "$bad" ] || fail "a time written by an operation is not the process's clock in the second-resolution UTC form: $bad"
ok "one clock, UTC, whole seconds"

echo "TEST P-ERR-1: a refused operation changes nothing of its own"
# Bug it catches (mutation): a refusal that commits part of its work first (a refused release letting go of what it did hold,
# a refused join refreshing the roster entry).
fresh
for n in e1 e2; do agentbus --as $n join >/dev/null; done
agentbus --as e1 claim er/a.py >/dev/null
sql "UPDATE agents SET last_seen='2020-01-01T00:00:00Z'"
sql "UPDATE agents SET last_seen=? WHERE name='e2'" "$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
agentbus --as e1 claim er/mine.py >/dev/null
before=$(snap)
jfail bad_input "${AB[@]}" --json --as e1 post "x" --kind fyi
jfail no_message "${AB[@]}" --json --as e1 post "x" --reply-to 9999
jfail bad_input "${AB[@]}" --json --as e1 post "x" --kind dropped
jfail bad_input "${AB[@]}" --json --as e1 ctx set goal v
jfail no_context_key "${AB[@]}" --json --as e1 ctx get none
jfail name_active "${AB[@]}" --json --as e2 join
jfail not_held "${AB[@]}" --json --as e1 release er/mine.py er/not-held.py
jfail bad_input "${AB[@]}" --json --as e1 claim /absolute er/new.py
jfail not_on_roster "${AB[@]}" --json --as nobody post "x"
[ "$(snap)" = "$before" ] || fail "a refused operation changed the bus: $(diff <(echo "$before") <(snap) | head -5)"
agentbus --as e2 claim er/a.py >/dev/null 2>&1 && fail "setup: e2 should be refused er/a.py" || true
after=$(snap)
python3 - "$before" "$after" <<'PY' || fail "a refused claim changed more than its claim_refused row"
import sys
b, a = sys.argv[1:3]
bl = {l.split(" ", 1)[0]: l for l in b.splitlines()}
al = {l.split(" ", 1)[0]: l for l in a.splitlines()}
for t in bl:
    if t != "log" and bl[t] != al[t]:
        sys.exit(1)
PY
ok "nothing changed but the claim_refused row"

echo "TEST P-LIM-1: input over a limit is refused with bad_input, never truncated"
# Bug it catches (mutation): a limit one off either way, counted in characters, truncation instead of refusal, no trim.
fresh; agentbus --as li join >/dev/null
b65536=$(python3 -c 'print("b"*65536)'); b65537=$(python3 -c 'print("b"*65537)')
multi=$(python3 -c 'print("é"*32769)')
agentbus --as li post "$b65536" >/dev/null || fail "a body of 65536 bytes was refused"
[ "$(one "SELECT length(body) FROM messages")" = 65536 ] || fail "a body of 65536 bytes was stored as $(one "SELECT length(body) FROM messages") characters"
agentbus --as li post "   padded   " >/dev/null || fail "a padded body was refused"
[ "$(one "SELECT body FROM messages ORDER BY id DESC LIMIT 1")" = padded ] || fail "the body was not trimmed"
n=$(count messages)
jfail bad_input "${AB[@]}" --json --as li post "$b65537"
jfail bad_input "${AB[@]}" --json --as li post "$multi"
jfail bad_input "${AB[@]}" --json --as li post "      "
jfail bad_input "${AB[@]}" --json --as li ctx set k "$b65537"
jfail bad_input "${AB[@]}" --json --as li goal "$b65537"
jfail bad_input "${AB[@]}" --json --as li log add act "$b65537"
agentbus --as li ctx set k "$b65536" >/dev/null || fail "a fact value of 65536 bytes was refused"
agentbus --as li goal "$b65536" >/dev/null || fail "a goal of 65536 bytes was refused"
agentbus --as li log add act "$b65536" >/dev/null || fail "a log detail of 65536 bytes was refused"
[ "$(count messages)" = "$n" ] || fail "a refused body stored a message"
r1024=$(python3 -c 'print("r"*1024)'); r1025=$(python3 -c 'print("r"*1025)'); rmulti=$(python3 -c 'print("é"*1024)')
agentbus --as li claim "$r1024" >/dev/null || fail "a resource of 1024 characters was refused"
agentbus --as li claim "$rmulti" >/dev/null || fail "a resource of 1024 two-byte characters was refused: the limit is in characters"
jfail bad_input "${AB[@]}" --json --as li claim "$r1025"
[ "$(count claims)" = 2 ] || fail "a refused resource stored a claim"
many=(); for i in $(seq 1 101); do many+=("m$i"); done
jfail bad_input "${AB[@]}" --json --as li release "${many[@]}"
jfail bad_input "${AB[@]}" --json --as li claim "${many[@]}"
ok "bodies in bytes after trimming, resources in characters, refused not cut"

echo "TEST P-VER-1: the implementation publishes its protocol version in schema --json, full, per command and --index"
# Bug it catches (mutation): the version missing from one shape, or not the one the spec states.
for args in "" "--index" "join"; do
  # shellcheck disable=SC2086
  v=$(agentbus schema $args --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("protocol"))')
  [ "$v" = "1.0" ] || fail "schema $args --json says protocol $v, want 1.0"
done
ok "protocol 1.0 in all three shapes"

echo "All fact rule tests passed"
