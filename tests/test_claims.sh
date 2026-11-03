#!/bin/bash
set -euo pipefail

# Test script for agentbus claims and release functionality
# Runs this checkout's CLI against a throwaway db in a temp dir

. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export AGENTBUS_DB="$TMP/selftest.db"

echo "Starting agentbus claims test..."

# Test 1: Join and claim
echo
echo "TEST 1: Join and claim resources"
agentbus --as agent1 join --tool test --model test --role "test agent 1"
agentbus --as agent1 claim "file1.txt" --purpose "test claim 1"
agentbus --as agent1 claim "file2.txt" --purpose "test claim 2"
claims_count=$(njson agentbus --json claims)
if [ "$claims_count" -eq 2 ]; then
  echo "PASS: Agent1 claimed 2 resources"
else
  echo "FAIL: Expected 2 claims, got $claims_count"
  exit 1
fi

# Test 2: Release with --all
echo
echo "TEST 2: Release all claims without leaving"
agentbus --as agent1 release --all
claims_count=$(njson agentbus --json claims)
if [ "$claims_count" -eq 0 ]; then
  echo "PASS: All claims released"
else
  echo "FAIL: Expected 0 claims, got $claims_count"
  exit 1
fi

# Test 3: Stale claim detection. A stale claim is one whose holder is off the roster without having
# released it (a row cleared by hand); leave itself releases.
echo
echo "TEST 3: Stale claim detection"
agentbus --as agent1 claim "file3.txt" --purpose "will be stale"
agentbus --as agent2 join --tool test --model test --role "test agent 2"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"DELETE FROM agents WHERE name='agent1'\"); c.commit()" "$AGENTBUS_DB"
stale_count=$(njson agentbus --as agent2 --json claims --stale)
if [ "$stale_count" -eq 1 ]; then
  echo "PASS: Detected 1 stale claim"
else
  echo "FAIL: Expected 1 stale claim, got $stale_count"
  exit 1
fi

# Test 4: Auto-release of stale claims
echo
echo "TEST 4: Auto-release stale claim when new agent claims it"
agentbus --as agent2 claim "file3.txt" --purpose "claimed over stale"
holder=$(outof agentbus --json claims | python3 -c 'import json,sys; print([r["agent"] for r in json.load(sys.stdin)["items"] if r["resource"]=="file3.txt"][0])')
if [ "$holder" = agent2 ]; then
  echo "PASS: Auto-released stale claim and took it"
else
  echo "FAIL: Failed to auto-release stale claim"
  exit 1
fi

# Test 5: Leave prints released paths
echo
echo "TEST 5: Leave prints released paths"
agentbus --as agent2 claim "file4.txt" --purpose "will be released"
agentbus --as agent2 claim "file5.txt" --purpose "will be released"
output=$(agentbus --as agent2 leave)
if grep -q "file4.txt" <<<"$output" && grep -q "file5.txt" <<<"$output"; then
  echo "PASS: Leave printed released paths"
else
  echo "FAIL: Leave did not print released paths"
  exit 1
fi

echo
echo "TEST 5b: leave releases every claim it reports"
n=$(agentbus --json claims | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["items"] if r["agent"]=="agent2"))')
[ "$n" = 0 ] || fail "leave left $n claims behind"
[ "$(agentbus --json claims --stale | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')" = 0 ] || fail "stale claims after leave"
ok "leave left zero claims"

# Test: a name active in the last 30 minutes cannot be joined by another session
echo
echo "TEST: join refuses a recently active name without --takeover"
agentbus --as agent9 join --tool test --role "first session"
expect_fail "may be another live session" agentbus --as agent9 join --tool test --role "second session"
role=$(agentbus --json who | python3 -c 'import json,sys; print([r["role"] for r in json.load(sys.stdin)["items"] if r["name"]=="agent9"][0])')
[ "$role" = "first session" ] || { echo "FAIL: roster entry was overwritten ($role)"; exit 1; }
agentbus --as agent9 join --tool test --role "same session" --takeover
role=$(agentbus --json who | python3 -c 'import json,sys; print([r["role"] for r in json.load(sys.stdin)["items"] if r["name"]=="agent9"][0])')
[ "$role" = "same session" ] || { echo "FAIL: --takeover did not rejoin"; exit 1; }
echo "PASS: live-name guard"

# Test: a folder claim and a claim on a path inside it conflict, both directions (issue #1)
echo
echo "TEST: folder claims block paths inside them"
agentbus --as f1 join --tool test --role "folder holder" >/dev/null
agentbus --as f2 join --tool test --role "file claimer" >/dev/null
agentbus --as f1 claim "pkg/tests/" --purpose "folder" >/dev/null
expect_fail "overlaps pkg/tests/, claimed by f1" agentbus --as f2 claim "pkg/tests/a_test.py"
agentbus --as f2 claim "pkg/testsuite.py" >/dev/null || { echo "FAIL: sibling sharing a name prefix was refused"; exit 1; }
agentbus --as f2 claim "lib/b.py" >/dev/null
expect_fail "overlaps lib/b.py, claimed by f2" agentbus --as f1 claim "lib/"
agentbus --as f1 claim "pkg/tests/a_test.py" >/dev/null || { echo "FAIL: holder refused a path inside its own folder"; exit 1; }
agentbus --as f2 leave >/dev/null
agentbus --as f1 claim "lib/" >/dev/null || { echo "FAIL: folder still blocked after the file holder left"; exit 1; }
echo "PASS: folder and file claims conflict"


echo
echo "TEST: claim requires joining first; an unjoined name's claim cannot exist to be auto-released"
expect_fail "ghost is not on the roster. Run: agentbus --as ghost join" agentbus --as ghost claim "g.txt"
agentbus --as h1 join --tool test >/dev/null
agentbus --as h1 claim "g.txt" >/dev/null
[ "$(agentbus --json claims | python3 -c 'import json,sys; print([r["agent"] for r in json.load(sys.stdin)["items"] if r["resource"]=="g.txt"][0])')" = h1 ] || fail "g.txt not held by h1"
ok "claim needs the roster"

echo
echo "TEST: path spellings normalise, so none bypasses a claim"
agentbus --as p1 join --tool test >/dev/null
agentbus --as p2 join --tool test >/dev/null
agentbus --as p1 claim "src/z.py" >/dev/null
for r in ./src/z.py src//z.py src/./z.py src/../src/z.py src; do
  expect_fail "claimed by p1" agentbus --as p2 claim "$r"
done
agentbus --as p1 claim "pk" >/dev/null
for r in pk/ pk/a.py ./pk//b/c.py; do expect_fail "claimed by p1" agentbus --as p2 claim "$r"; done
agentbus --as p2 claim "lb/a.py" >/dev/null
expect_fail "claimed by p2" agentbus --as p1 claim "lb"
expect_fail "bus-relative path" agentbus --as p1 claim "/etc/passwd"
expect_fail "climbs out of the bus directory" agentbus --as p1 claim "../other/x"
expect_fail "climbs out of the bus directory" agentbus --as p1 claim "a/../../x"
stored=$(agentbus --json claims | python3 -c 'import json,sys; print(" ".join(sorted(r["resource"] for r in json.load(sys.stdin)["items"] if r["agent"] in ("p1","p2"))))')
[ "$stored" = "lb/a.py pk src/z.py" ] || fail "stored forms: $stored"
agentbus --as p1 claim "issue:17" >/dev/null
agentbus --as p2 claim "issue:170" >/dev/null || fail "issue:170 refused next to issue:17"
expect_fail "claimed by p1" agentbus --as p2 claim "issue:17"
agentbus --as p1 claim "pk/" >/dev/null
[ "$(agentbus --json claims | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["items"] if r["resource"].rstrip("/")=="pk"))')" = 1 ] || fail "pk and pk/ both stored"
agentbus --as p1 release "./pk" >/dev/null || fail "release by another spelling"
agentbus --as p2 claim "pk/a.py" >/dev/null || fail "pk still held after release"
ok "normalised paths, exact scheme names, refused absolute and escaping paths"

echo
echo "TEST: --ttl-min below 1 refused; release RESOURCE --all refused"
expect_fail "--ttl-min must be at least 1" agentbus --as p1 claim "t.txt" --ttl-min 0
expect_fail "--ttl-min must be at least 1" agentbus --as p1 claim "t.txt" --ttl-min -5
expect_fail "not allowed with argument" agentbus --as p1 release "src/z.py" --all
grep -q '"src/z.py"' <<<"$(outof agentbus --json claims)" || fail "release with both forms released something"
ok "ttl and release arguments"

echo
echo "TEST: read --since N --limit L gives the next L after N"
for i in 1 2 3 4 5 6; do agentbus --as p1 post "seq$i" --topic seq >/dev/null; done
first=$(agentbus --json read --topic seq | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
got=$(agentbus --json read --topic seq --since "$first" --limit 2 | python3 -c 'import json,sys; print(" ".join(r["body"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "seq2 seq3" ] || fail "read --since gave: $got"
got=$(agentbus --json read --topic seq --limit 2 | python3 -c 'import json,sys; print(" ".join(r["body"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "seq5 seq6" ] || fail "read without --since gave: $got"
ok "read --since pages forward"

echo
echo "TEST: --reply-to a missing id is a clean error"
expect_fail "no message #99999 to reply to. See recent ids with: agentbus read" agentbus --as p1 post "hi" --reply-to 99999
ok "reply-to checked"

echo
echo "TEST: messages to a name before it first joins reach its inbox; older broadcasts do not"
agentbus --as p1 post "early broadcast" >/dev/null
agentbus --as p1 post "for latecomer" --to late >/dev/null
agentbus --as late join --tool test >/dev/null
agentbus --as p1 post "later broadcast" >/dev/null
got=$(agentbus --as late --json inbox | python3 -c 'import json,sys; print("|".join(r["body"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "for latecomer|later broadcast" ] || fail "late inbox: $got"
[ "$(agentbus --as late inbox)" = "inbox empty" ] || fail "inbox not marked read"
ok "direct messages wait for their recipient"

echo
echo "TEST: read-only commands under a name update last_seen"
for c in who read claims status "ctx get"; do
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE agents SET last_seen='2000-01-01T00:00:00Z' WHERE name='p1'\"); c.commit()" "$AGENTBUS_DB"
  agentbus $c >/dev/null
  seen=$(agentbus --json who | python3 -c 'import json,sys; print([r["last_seen"] for r in json.load(sys.stdin)["items"] if r["name"]=="p1"][0])')
  [ "$seen" = "2000-01-01T00:00:00Z" ] || fail "$c without --as touched last_seen"
  agentbus --as p1 $c >/dev/null
  seen=$(agentbus --json who | python3 -c 'import json,sys; print([r["last_seen"] for r in json.load(sys.stdin)["items"] if r["name"]=="p1"][0])')
  [ "$seen" != "2000-01-01T00:00:00Z" ] || fail "$c did not touch last_seen"
done
ok "who/read/claims/status/ctx get touch last_seen"

echo
echo "TEST: concurrent joins under one new name: exactly one wins"
pids=""; for i in 1 2 3 4 5 6 7 8; do (agentbus --as race join --tool test --role "r$i" >/dev/null 2>"$TMP/race.err$i" && echo won >> "$TMP/race") & pids="$pids $!"; done
for p in $pids; do wait $p || true; done   # losers exit non-zero by design; checked below
[ "$(wc -l < "$TMP/race" | tr -d ' ')" = 1 ] || fail "$(wc -l < "$TMP/race") joins won"
losers=0; for i in 1 2 3 4 5 6 7 8; do
  if [ -s "$TMP/race.err$i" ]; then
    grep -q "may be another live session" "$TMP/race.err$i" && ! grep -q Traceback "$TMP/race.err$i" || fail "loser $i: $(cat "$TMP/race.err$i")"
    losers=$((losers+1))
  fi
done
[ "$losers" = 7 ] || fail "$losers losers reported the live-session refusal, expected 7"
ok "join guard is atomic"

echo
echo "TEST: claims planted un-normalised are normalised on open, merged, renewable"
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO agents(name,joined_at,last_seen) VALUES('old1','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z') ON CONFLICT DO NOTHING")
c.execute("INSERT INTO claims VALUES('./old//x.py','old1','planted','2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')")
c.execute("INSERT INTO claims VALUES('old/./x.py','old1','planted2','2020-01-01T00:00:00Z','2998-01-01T00:00:00Z')")
c.commit()
PY
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE agents SET last_seen='2000-01-01T00:00:00Z' WHERE name='old1'\"); c.commit()" "$AGENTBUS_DB"
agentbus --as old1 join --tool t >/dev/null
got=$(agentbus --json claims | python3 -c 'import json,sys; print(" ".join(sorted(r["resource"]+"@"+r["expires_at"] for r in json.load(sys.stdin)["items"] if r["agent"]=="old1")))')
[ "$got" = "old/x.py@2999-01-01T00:00:00Z" ] || fail "aliases not merged to the normalised form: $got"
agentbus --as old1 claim "old/x.py" --ttl-min 5 >/dev/null
[ "$(agentbus --json claims | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["items"] if r["agent"]=="old1"))')" = 1 ] || fail "renew left an alias held"
agentbus --as old1 release "old/x.py" >/dev/null || fail "release by normalised form"
[ "$(agentbus --json claims | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["items"] if r["agent"]=="old1"))')" = 0 ] || fail "alias survived release"
ok "stored aliases normalised"

echo
echo "TEST: read --since 0 is the oldest first; --ttl-min above a week refused"
first=$(agentbus --json read --since 0 --limit 1 | python3 -c 'import json,sys; r=json.load(sys.stdin)["items"]; assert len(r)==1; print(r[0]["id"])')
oldest=$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select min(id) from messages').fetchone()[0])" "$AGENTBUS_DB")
[ "$first" = "$oldest" ] || fail "read --since 0 gave #$first, oldest is #$oldest"
expect_fail "at most 10080" agentbus --as p1 claim "big.txt" --ttl-min 99999999999
expect_fail "at most 10080" agentbus --as p1 claim "big.txt" --ttl-min 10081
agentbus --as p1 claim "week.txt" --ttl-min 10080 >/dev/null
ok "since 0 and ttl cap"

echo
echo "TEST: inbox --peek before a first join does not change what the join delivers"
agentbus --as p1 post "old broadcast for peeker" >/dev/null
agentbus --as peeker inbox --peek >/dev/null
agentbus --as p1 post "direct for peeker" --to peeker >/dev/null
agentbus --as peeker join --tool t >/dev/null
got=$(agentbus --as peeker --json inbox | python3 -c 'import json,sys; print("|".join(r["body"] for r in json.load(sys.stdin)["items"]))')
[ "$got" = "direct for peeker" ] || fail "peek before join changed the inbox: $got"
ok "peek leaves no cursor"

echo
echo "TEST: normalising planted claims logs another agent's claim it drops"
# Bug it catches: two stored spellings of one path held by different agents merged into one row
# and the losing holder's claim vanished with nothing in the log.
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
t = "2020-01-01T00:00:00Z"
c.execute("INSERT INTO claims VALUES('./cc.py','cx','',?,'2999-01-01T00:00:00Z')", (t,))
c.execute("INSERT INTO claims VALUES('cc.py','cy','',?,'2998-01-01T00:00:00Z')", (t,))
c.execute("INSERT INTO claims VALUES('dd.py','dx','',?,'2999-01-01T00:00:00Z')", (t,))
c.execute("INSERT INTO claims VALUES('./dd.py','dy','',?,'2998-01-01T00:00:00Z')", (t,))
c.commit()
PY
logs=$(outof agentbus --json log show --limit 200)
for pair in "cc.py held by cy" "./dd.py held by dy"; do
  printf '%s' "$logs" | python3 -c 'import json,sys; w=sys.argv[1]; sys.exit(0 if any(w in (r["detail"] or "") and "dropped" in r["detail"] for r in json.load(sys.stdin)["items"]) else 1)' "$pair" \
    || fail "no log entry for the dropped claim: $pair"
done
got=$(agentbus --json claims | python3 -c 'import json,sys; print(" ".join(sorted(r["resource"]+"@"+r["agent"] for r in json.load(sys.stdin)["items"] if r["resource"] in ("cc.py","dd.py"))))')
[ "$got" = "cc.py@cx dd.py@dx" ] || fail "later expiry did not win: $got"
ok "dropped colliding claims are logged with holder and resource"

echo
echo "TEST: --ttl-min counts minutes"
# Bug it catches (mutation): the TTL counted as seconds (or hours) instead of minutes.
agentbus --as ttl join --tool t >/dev/null
o=$(json_ok agentbus --json --as ttl claim ttl/a.py --ttl-min 7)
python3 -c '
import json, sys, time
from datetime import datetime, timezone
e = datetime.strptime(json.loads(sys.argv[1])["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
d = e - (time.time() + 7 * 60)
sys.exit(0 if abs(d) < 90 else "expires %+.0f s off now + 7 min" % d)' "$o" || fail "--ttl-min 7 did not expire in 7 minutes: $o"
ok "--ttl-min 7 expires 7 minutes from now"

echo
echo "TEST: an expired claim held by an agent still on the roster can be taken"
# Bug it catches (mutation): the conflict check ignored expires_at, so an on-roster agent's expired
# claim blocked everyone until it renewed or left.
agentbus --as exa join --tool t >/dev/null; agentbus --as exb join --tool t >/dev/null
agentbus --as exa claim ex/a.py --ttl-min 1 >/dev/null
agentbus --as exa claim ex/dir/ --ttl-min 1 >/dev/null
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE claims SET expires_at=? WHERE agent=?", ("2020-01-01T00:00:00Z", "exa")); c.commit()' "$AGENTBUS_DB"
outof agentbus --as exb claim ex/a.py >/dev/null
outof agentbus --as exb claim ex/dir/sub.py >/dev/null
[ "$(agentbus --json claims | python3 -c 'import json,sys; print(" ".join(sorted(r["resource"]+"@"+r["agent"] for r in json.load(sys.stdin)["items"] if r["resource"].startswith("ex/"))))')" = "ex/a.py@exb ex/dir/@exa ex/dir/sub.py@exb" ] \
  || fail "expired claims: $(agentbus --json claims)"
agentbus --as exa claim ex/b.py >/dev/null
expect_fail "ex/b.py is claimed by exa" agentbus --as exb claim ex/b.py
ok "an expired claim of an on-roster agent is taken; an unexpired one still refuses"

echo
echo "TEST: claims compare paths exactly, case included (documented in SKILL.md)"
# A case-insensitive filesystem (macOS by default) makes src/App.tsx and src/app.tsx one file,
# but they are two claims: the protocol says to claim the path exactly as git spells it.
agentbus --as csa join --tool t >/dev/null; agentbus --as csb join --tool t >/dev/null
agentbus --as csa claim cs/App.tsx >/dev/null
outof agentbus --as csb claim cs/app.tsx >/dev/null
SKILL="$(dirname "$BIN")/../skills/agentbus/SKILL.md"
grep -q 'Claims compare exactly, case included' "$SKILL" || fail "SKILL.md does not say claims are case-sensitive"
grep -q 'git ls-files' "$SKILL" || fail "SKILL.md does not say how to spell a path"
ok "case-distinct paths are distinct claims, and SKILL.md says so"

echo
echo "TEST: join --help says a recent name is refused, not that join is idempotent"
h=$(outof agentbus join --help)
grep -q 'idempotent' <<<"$h" && fail "join --help still says idempotent"
tr -d '\n' <<<"$h" | sed 's/  */ /g' | grep -q 'refuses a name active in the last 30 min unless --takeover' || fail "join --help: $h"
agentbus --as idem join --tool t >/dev/null
expect_fail "was active less than a minute ago" agentbus --as idem join --tool t
ok "join --help matches what a second join does"

echo
echo "TEST: renewal preserves purpose and acquisition time, including equivalent path spelling"
agentbus --as renew join >/dev/null
agentbus --as rival join >/dev/null
agentbus --as renew claim renew/ --purpose 'original purpose' >/dev/null
# Distinct from now without sleeping, so replacing claimed_at cannot pass by luck.
"$PY" - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as c:
    c.execute("UPDATE claims SET claimed_at=? WHERE resource=?", ('2001-02-03T04:05:06Z', 'renew/'))
PY
for purpose in preserve replace; do
  if [ "$purpose" = preserve ]; then
    o=$(json_ok agentbus --as renew claim renew --json)
  else
    o=$(json_ok agentbus --as renew claim renew --json --purpose 'new purpose')
  fi
  "$PY" - "$o" "$purpose" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {'resource', 'agent', 'purpose', 'claimed_at', 'expires_at', 'auto_released', 'auto_released_count'}, d
assert d['purpose'] == ('original purpose' if sys.argv[2] == 'preserve' else 'new purpose'), d
assert d['claimed_at'] == '2001-02-03T04:05:06Z', d
assert d['resource'] == 'renew' and d['agent'] == 'renew', d
PY
  want='original purpose'; [ "$purpose" = preserve ] || want='new purpose'
  expect_fail "(purpose: \"$want\"). Do not edit it yet." agentbus --as rival claim renew/sub.py
  agentbus --json claims | "$PY" -c 'import json,sys; r=next(r for r in json.load(sys.stdin)["items"] if r["resource"]=="renew"); assert r["purpose"]==sys.argv[1] and r["claimed_at"]=="2001-02-03T04:05:06Z"' "$want"
done
ok "renewal retains purpose and claimed_at; an explicit purpose replaces it in storage, JSON and conflicts"
echo "All tests passed!"
