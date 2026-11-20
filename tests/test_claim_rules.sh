#!/bin/bash
set -euo pipefail
# The claim and release requirements of docs/protocol.md (P-CLAIM-n), one section each, every check printing its own
# FAIL line. tests/test_claims.sh and tests/test_claim_refusal.sh pin the wording and the paths around them; this file
# pins the rules, so a mutation of one rule (tests/mutations.json, field "must") fails here for that rule's reason.
# Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/rules.db"
cd "$T"

# sql DB STATEMENT [ARG...]: one write straight into the bus, as a tool that planted rows would.
sql() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$AGENTBUS_DB" "$@"; }
# rows STATEMENT [ARG...]: the first column of every row, one per line.
rows() { python3 -c 'import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2], sys.argv[3:])]' "$AGENTBUS_DB" "$@"; }
# held AGENT: the resources AGENT holds, sorted, on one line.
held() { rows "SELECT resource FROM claims WHERE agent=? ORDER BY resource" "$1" | tr '\n' ' '; }
# field JSON KEY: one key of a JSON object.
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
for n in sa sb sc; do agentbus --as $n join --tool t >/dev/null; done

echo "TEST P-CLAIM-1: scheme names are compared exactly, with no hierarchy"
# Bug it catches (mutation): issue:17:sub counted as inside issue:17 the way a folder holds a path.
agentbus --as sa claim issue:17 >/dev/null
agentbus --as sb claim issue:17:sub >/dev/null || fail "issue:17:sub was refused next to issue:17: scheme names overlap by hierarchy"
expect_fail "claimed by sa" agentbus --as sb claim issue:17
agentbus --as sc claim issue:9:sub >/dev/null
agentbus --as sa claim issue:9 >/dev/null || fail "issue:9 was refused next to issue:9:sub: scheme names overlap by hierarchy"
ok "issue:17 and issue:17:sub do not overlap either way; issue:17 itself is held"

echo "TEST P-CLAIM-2: a path is stored normalised; absolute, climbing, empty and dot paths are refused"
# Bug it catches (mutation): a path stored as given, or only a leading ./ removed, or the folder marker dropped.
r=$(json_ok agentbus --json --as sa claim "./norm//a/../b.py")
[ "$(field "$r" resource)" = "norm/b.py" ] || fail "the stored form of ./norm//a/../b.py was not norm/b.py: $r"
r=$(json_ok agentbus --json --as sa claim "./normdir//x/")
[ "$(field "$r" resource)" = "normdir/x/" ] || fail "the folder marker or the normal form was lost: normdir/x/ became $r"
expect_fail "use a bus-relative path" agentbus --as sa claim /abs/path
expect_fail "it climbs out of the bus directory" agentbus --as sa claim ../out
expect_fail "it climbs out of the bus directory" agentbus --as sa claim a/../../out
for bad in . ./ ""; do
  expect_fail "name a path inside the bus directory" agentbus --as sa claim "$bad"
done
ok "normalised, marker kept, four kinds of path refused"

echo "TEST P-CLAIM-3: path overlap is the same path or a folder holding the other, either spelling, case-sensitive"
# Bug it catches (mutation): the compare ignored case, matched any name that starts with the held one (src/a vs src/a.py),
# or missed a folder claim written with its trailing slash.
agentbus --as sb claim sib/a.py sib/a-b sib/ab sib/a0 >/dev/null
agentbus --as sa claim "case/app.tsx" "mark/dir/" "mark2/dir" >/dev/null
agentbus --as sa claim sib/a >/dev/null || fail "sib/a was refused beside sib/a.py, sib/a-b, sib/ab and sib/a0: a name that starts with a held name overlaps it"
agentbus --as sb claim "case/App.tsx" >/dev/null || fail "case/App.tsx was refused next to case/app.tsx: the compare ignored case"
agentbus --as sb claim "case/other.tsx" >/dev/null
agentbus --as sc claim "case/OTHER.tsx" >/dev/null || fail "case/OTHER.tsx was refused next to case/other.tsx: the compare ignored case"
expect_fail "claimed by sa" agentbus --as sb claim sib/a/inside.py
expect_fail "claimed by sa" agentbus --as sb claim mark/dir
expect_fail "claimed by sa" agentbus --as sb claim mark/dir/inside.py
expect_fail "claimed by sa" agentbus --as sb claim mark2/dir/
expect_fail "claimed by sa" agentbus --as sb claim mark2/dir/deep/inside.py
ok "case, siblings, both spellings of a folder"

echo "TEST P-CLAIM-6: a claim held by a name off the roster does not block; a live one is deleted and logged as auto-released"
# Bug it catches (mutation): a holder that left or was cleared blocked every other agent, or its claim vanished unlogged.
sql "INSERT INTO claims VALUES('ghost/f.py','ghost','old work','2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')"
sql "INSERT INTO claims VALUES('ghostdir/','ghost','old work','2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')"
r=$(json_ok agentbus --json --as sa claim ghost/f.py) || fail "a claim held by a name off the roster blocked ghost/f.py"
[ "$(field "$r" auto_released_count)" = 1 ] || fail "the claim over a ghost's did not report it auto-released: $r"
agentbus --as sa claim ghostdir/x.py >/dev/null || fail "a ghost's folder claim blocked ghostdir/x.py"
[ -z "$(held ghost)" ] || fail "a live claim of a name off the roster was not deleted: $(held ghost)"
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='claim' AND detail LIKE '%auto-released from ghost (not on roster)'")" = 2 ] \
  || fail "the auto-release of a ghost's claims was not logged: $(rows "SELECT detail FROM log WHERE action='claim' AND detail LIKE '%auto-released%'")"
ok "ghost claims do not block, are deleted and logged"

echo "TEST P-CLAIM-7: an expired claim does not block, even when its holder is on the roster"
# Bug it catches (mutation): the compare ignored expires_at, so an on-roster holder's expired claim blocked everyone.
agentbus --as sa claim exp/a.py >/dev/null
sql "UPDATE claims SET expires_at='2020-01-01T00:00:00Z' WHERE resource='exp/a.py'"
agentbus --as sb claim exp/a.py >/dev/null || fail "an expired claim of an agent on the roster blocked another agent"
ok "expired claim taken"

echo "TEST P-CLAIM-8: release lets go of a claim whether it is live or expired"
# Bug it catches (mutation): release looked only at live claims, so an expired row stayed until leave.
agentbus --as sa claim rel/live.py rel/old.py >/dev/null
sql "UPDATE claims SET expires_at='2020-01-01T00:00:00Z' WHERE resource='rel/old.py'"
agentbus --as sa release rel/old.py >/dev/null || fail "release refused an expired claim of the caller"
[ -z "$(rows "SELECT 1 FROM claims WHERE resource='rel/old.py'")" ] || fail "release left the expired claim stored"
ok "an expired claim is released like a live one"

echo "TEST P-CLAIM-9 and P-CLAIM-10: renewal replaces expires_at, keeps claimed_at and purpose; the TTL defaults to 120 minutes"
# Bug it catches (mutation): a renewal restarted claimed_at, dropped the purpose, only ever extended the expiry, or left
# a second row under the other spelling of the path; a default of another length.
T0=2030-01-01T10:00:00Z
r=$(AGENTBUS_TEST_NOW=$T0 json_ok agentbus --json --as sa claim ren/f.py "ren/d" --purpose "first purpose")
r=$(AGENTBUS_TEST_NOW=$T0 json_ok agentbus --json --as sa claim ren/g.py)
[ "$(field "$r" expires_at)" = "2030-01-01T12:00:00Z" ] || fail "the default TTL is not 120 minutes: $r"
r=$(AGENTBUS_TEST_NOW=2030-01-01T10:30:00Z json_ok agentbus --json --as sa claim ren/f.py --ttl-min 10)
[ "$(field "$r" renewed)" = True ] || fail "a claim again while live was not reported renewed: $r"
[ "$(field "$r" claimed_at)" = "$T0" ] || fail "a renewal restarted claimed_at: $r"
[ "$(field "$r" purpose)" = "first purpose" ] || fail "a renewal dropped the purpose: $r"
[ "$(field "$r" expires_at)" = "2030-01-01T10:40:00Z" ] && [ "$(rows "SELECT expires_at FROM claims WHERE resource='ren/f.py'")" = "2030-01-01T10:40:00Z" ] \
  || fail "a renewal with a shorter TTL did not replace expires_at (it must not only extend): $r, stored $(rows "SELECT expires_at FROM claims WHERE resource='ren/f.py'")"
r=$(AGENTBUS_TEST_NOW=2030-01-01T10:31:00Z json_ok agentbus --json --as sa claim ren/f.py --purpose "second purpose")
[ "$(field "$r" purpose)" = "second purpose" ] || fail "a renewal with a new purpose kept the old one: $r"
AGENTBUS_TEST_NOW=$T0 agentbus --as sa claim "ren/d" >/dev/null
AGENTBUS_TEST_NOW=$T0 agentbus --as sa claim "ren/d/" >/dev/null
[ "$(rows "SELECT COUNT(*) FROM claims WHERE agent='sa' AND rtrim(resource,'/')='ren/d'")" = 1 ] \
  || fail "claiming ren/d again as ren/d/ left two rows: $(held sa)"
r=$(AGENTBUS_TEST_NOW=2030-01-01T13:00:00Z json_ok agentbus --json --as sa claim ren/g.py)
[ "$(field "$r" renewed)" = False ] || fail "an expired claim taken again was reported renewed: $r"
ok "renewal rules and the 120 minute default"

echo "TEST P-CLAIM-10: the TTL is refused outside 1 to 10080 minutes; nothing but claiming renews a claim"
# Bug it catches (mutation): 0 accepted, a week and a minute accepted, a post (or any other command) pushing expires_at out.
for ttl in 0 -5 10081; do
  expect_fail "--ttl-min must be at least 1 and at most 10080" agentbus --as sa claim ttl/x.py --ttl-min=$ttl
done
r=$(AGENTBUS_TEST_NOW=$T0 json_ok agentbus --json --as sa claim ttl/one.py --ttl-min 1)
[ "$(field "$r" expires_at)" = "2030-01-01T10:01:00Z" ] || fail "--ttl-min 1 was not accepted or not one minute: $r"
r=$(AGENTBUS_TEST_NOW=$T0 json_ok agentbus --json --as sa claim ttl/week.py --ttl-min 10080)
[ "$(field "$r" expires_at)" = "2030-01-08T10:00:00Z" ] || fail "--ttl-min 10080 was not accepted or not a week: $r"
before=$(rows "SELECT group_concat(resource || '@' || expires_at) FROM (SELECT * FROM claims WHERE agent='sa' ORDER BY resource)")
export AGENTBUS_TEST_NOW=2030-01-01T10:00:30Z
agentbus --as sa post "not a renewal" >/dev/null; agentbus --as sa inbox >/dev/null; agentbus --as sa read >/dev/null
agentbus --as sa claims >/dev/null; agentbus --as sa brief >/dev/null; agentbus --as sa ctx set k v >/dev/null
agentbus --as sa goal "not a renewal" >/dev/null
after=$(rows "SELECT group_concat(resource || '@' || expires_at) FROM (SELECT * FROM claims WHERE agent='sa' ORDER BY resource)")
unset AGENTBUS_TEST_NOW
[ "$before" = "$after" ] || fail "a command other than claim changed a claim's expires_at: $before => $after"
ok "bounds and no renewal by other commands"

echo "TEST P-CLAIM-11: a claim names at most 100 resources, counted as given, and at most 100 distinct --from holders"
# Bug it catches (mutation): the caps counted after duplicates were dropped, or allowed one more.
dup=$(for i in $(seq 1 101); do echo "cap/same.py"; done)
expect_fail "at most 100 resources" agentbus --as sa claim $dup
[ -z "$(rows "SELECT 1 FROM claims WHERE resource='cap/same.py'")" ] || fail "a claim over the cap took a resource"
many=$(for i in $(seq 1 101); do echo "h$i"; done)
args=(); for h in $many; do args+=(--from "$h"); done
expect_fail "at most 100 --from names" agentbus --as sa claim cap/from.py "${args[@]}"
args=(); for i in $(seq 1 101); do args+=(--from h1); done
if agentbus --as sa claim cap/from.py "${args[@]}" 2>"$T/e"; then fail "--from h1 with nobody holding was accepted"; fi
if grep -q "at most 100 --from" "$T/e"; then fail "101 copies of one --from holder hit the cap, which counts distinct holders: $(cat "$T/e")"; fi
ok "the resource cap counts as given, the --from cap counts distinct names"

echo "TEST P-CLAIM-12: claim --from gives the caller a new claim: claimed_at now, the caller's purpose and TTL, nothing of the holder's"
# Bug it catches (mutation): the taken claim kept the holder's purpose or claimed_at, as if the claim had been handed over.
for n in hf ht; do agentbus --as $n join --tool t >/dev/null; done
AGENTBUS_TEST_NOW=2030-01-01T10:00:00Z agentbus --as hf claim take/f.py --purpose "holder purpose" --ttl-min 500 >/dev/null
r=$(AGENTBUS_TEST_NOW=2030-01-01T10:10:00Z json_ok agentbus --json --as ht claim take/f.py --from hf --ttl-min 5)
[ "$(field "$r" agent)" = ht ] && [ -z "$(held hf)" ] || fail "claim --from did not move take/f.py from hf to ht: $r"
[ "$(field "$r" purpose)" = None ] && [ "$(rows "SELECT IFNULL(purpose,'none') FROM claims WHERE resource='take/f.py'")" = none ] || fail "the taken claim kept the holder's purpose: $r"
[ "$(field "$r" claimed_at)" = "2030-01-01T10:10:00Z" ] && [ "$(rows "SELECT claimed_at FROM claims WHERE resource='take/f.py'")" = "2030-01-01T10:10:00Z" ] || fail "the taken claim kept the holder's claimed_at: $r"
[ "$(field "$r" expires_at)" = "2030-01-01T10:15:00Z" ] || fail "the taken claim kept the holder's expiry instead of the caller's TTL: $r"
ok "a taken claim is a new claim of the caller"

echo "TEST P-CLAIM-16: claims are advisory: no operation is refused because of one"
# Bug it catches (mutation): a post, read or other write refused while another agent held a claim.
agentbus --as sb claim adv/x.py adv/dir/ >/dev/null
agentbus --as sa post "advisory" >/dev/null || fail "post refused while another agent holds a claim"
for cmd in "read" "inbox" "claims" "brief" "who" "ctx set advisory yes" "goal advisory" "log add note advisory"; do
  # shellcheck disable=SC2086
  agentbus --as sa $cmd >/dev/null 2>&1 || fail "'$cmd' refused while another agent holds a claim"
done
ok "post, read, inbox, claims, brief, who, ctx, goal and log add all work beside another agent's claims"

echo "TEST P-CLAIM-17: release acts only on the caller's own claims, takes all or none, and --if-held skips what is not held"
# Bug it catches (mutation): release let go of another agent's claim, took an absolute path, skipped what was not held
# without --if-held, or missed the other spelling of a path.
agentbus --as sa claim rl/mine.py rl/dir/ rl/plain >/dev/null
agentbus --as sb claim rl/other.py >/dev/null
expect_fail "you do not hold rl/other.py" agentbus --as sa release rl/other.py
[ "$(rows "SELECT agent FROM claims WHERE resource='rl/other.py'")" = sb ] || fail "release of another agent's claim let it go"
expect_fail "use a bus-relative path" agentbus --as sa release /abs/path
expect_fail "you do not hold rl/other.py" agentbus --as sa release rl/mine.py rl/other.py
[ -n "$(rows "SELECT 1 FROM claims WHERE resource='rl/mine.py'")" ] || fail "a release that refused still let go of rl/mine.py: all or none"
agentbus --as sa release rl/dir >/dev/null || fail "release of rl/dir did not match the stored rl/dir/"
agentbus --as sa release rl/plain/ >/dev/null || fail "release of rl/plain/ did not match the stored rl/plain"
agentbus --as sa release rl/mine.py rl/other.py --if-held >/dev/null || fail "--if-held refused a resource that is not held"
[ -z "$(rows "SELECT 1 FROM claims WHERE resource='rl/mine.py'")" ] || fail "--if-held skipped the held rl/mine.py too"
[ "$(rows "SELECT agent FROM claims WHERE resource='rl/other.py'")" = sb ] || fail "--if-held let go of another agent's claim"
ok "own claims only, all or none, either spelling, --if-held skips"

echo "TEST P-CLAIM-18: release does not split a claim: a path inside a held folder is not held"
# Bug it catches (mutation): releasing rl2/dir/inner.py let go of the whole folder claim.
agentbus --as sa claim rl2/dir/ >/dev/null
expect_fail "you do not hold rl2/dir/inner.py" agentbus --as sa release rl2/dir/inner.py
[ -n "$(rows "SELECT 1 FROM claims WHERE resource='rl2/dir/' AND agent='sa'")" ] || fail "releasing a path inside a held folder let go of the folder"
ok "not_held, folder still held"

echo "TEST P-CLAIM-19: opening a bus for writing normalises stored paths, logs each change, at most 500 rows per opening, and stands when the command is refused"
# Bug it catches (mutation): normalising skipped, unlogged, past the cap per opening, or undone by a refusal.
sql "INSERT INTO claims VALUES('./nl//one.py','sb','planted','2020-01-01T00:00:00Z','2999-01-01T00:00:00Z')"
agentbus --as sa claim /abs/refused >/dev/null 2>&1 && fail "an absolute path was claimed"
[ -n "$(rows "SELECT 1 FROM claims WHERE resource='nl/one.py'")" ] && [ -z "$(rows "SELECT 1 FROM claims WHERE resource='./nl//one.py'")" ] \
  || fail "the refused claim did not leave the planted spelling normalised: $(rows "SELECT resource FROM claims WHERE resource LIKE '%nl%'")"
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='claim' AND detail='./nl//one.py renamed to nl/one.py (normalised)'")" = 1 ] \
  || fail "the rename to the normalised form was not logged: $(rows "SELECT detail FROM log WHERE detail LIKE '%normalised%'")"
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO claims VALUES(?,?,?,?,?)", [("./bulk//f%d.py" % i, "sb", None, "2020-01-01T00:00:00Z", "2999-01-01T00:00:00Z") for i in range(501)])
c.commit()
PY
agentbus --as sa post "open once" >/dev/null
left=$(rows "SELECT COUNT(*) FROM claims WHERE resource GLOB './*'")
[ "$left" = 1 ] || fail "one opening normalised $((501 - left)) planted rows, not 500"
agentbus --as sa post "open twice" >/dev/null
[ "$(rows "SELECT COUNT(*) FROM claims WHERE resource GLOB './*'")" = 0 ] || fail "the row past the 500th was not normalised by a later opening"
ok "normalised, logged, capped per opening, kept after a refusal"

echo "TEST P-CLAIM-21: reclaiming one's own claim with the same purpose writes no log row, live or expired; a new claim or a changed purpose writes one"
# Bug it catches (mutation): the log row written for an expired reclaim, or never for a changed purpose.
agentbus --as sa claim lg/a.py --purpose same >/dev/null
n=$(rows "SELECT COUNT(*) FROM log")
agentbus --as sa claim lg/a.py --purpose same >/dev/null
sql "UPDATE claims SET expires_at='2020-01-01T00:00:00Z' WHERE resource='lg/a.py'"
agentbus --as sa claim lg/a.py --purpose same >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log")" = "$n" ] || fail "reclaiming with the same purpose wrote a log row: $(rows "SELECT detail FROM log ORDER BY id DESC LIMIT 2")"
agentbus --as sa claim lg/a.py --purpose changed >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log")" = "$((n + 1))" ] || fail "a changed purpose wrote no log row"
agentbus --as sa claim lg/b.py >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log")" = "$((n + 2))" ] || fail "a new claim wrote no log row"
ok "no row for the same purpose, a row for a change and a new claim"

echo "TEST P-CLAIM-22: release --all deletes every claim of the caller, live and expired, and writes no log row when there was nothing"
# Bug it catches (mutation): expired claims left behind, or a log row for a release that released nothing.
agentbus --as sc claim all/a.py all/b.py >/dev/null
sql "UPDATE claims SET expires_at='2020-01-01T00:00:00Z' WHERE resource='all/b.py'"
agentbus --as sc release --all >/dev/null
[ -z "$(held sc)" ] || fail "release --all left claims behind: $(held sc)"
n=$(rows "SELECT COUNT(*) FROM log WHERE action='release'")
agentbus --as sc release --all >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='release'")" = "$n" ] || fail "release --all with nothing to release wrote a log row"
ok "everything released, nothing logged for nothing"

echo "TEST P-CLAIM-4: one claim call takes every resource it names or none, in one atomic step"
# Bug it catches (mutation): a batch that keeps the resources taken before a later one failed (a refusal, or a fault between two writes).
agentbus --as sb claim batch/held.py >/dev/null
expect_fail "nothing claimed" agentbus --as sa claim batch/free1.py batch/held.py batch/free2.py
[ -z "$(rows "SELECT resource FROM claims WHERE agent='sa' AND resource LIKE 'batch/%'")" ] || fail "a refused batch kept the free resources: sa holds $(rows "SELECT resource FROM claims WHERE agent='sa' AND resource LIKE 'batch/%'" | tr '\n' ' ')"
# a fault after the first resource is written: the log table has run out of ids, so the second resource's log row fails
real_db=$AGENTBUS_DB
export AGENTBUS_DB="$T/fault.db"
agentbus --as fa join >/dev/null
agentbus --as fa claim keep/one.py --ttl-min 5 >/dev/null
before=$(rows "SELECT expires_at FROM claims WHERE resource='keep/one.py'")
sql "INSERT INTO log(id,ts,agent,action,detail) VALUES(9223372036854775807,'2020-01-01T00:00:00Z','x','y','z')"
rc=0; agentbus --json --as fa claim keep/one.py keep/two.py keep/three.py --ttl-min 100 >/dev/null 2>"$T/fault.err" || rc=$?
[ "$rc" != 0 ] || fail "the injected fault did not fail the claim"
[ "$(rows "SELECT expires_at FROM claims WHERE resource='keep/one.py'")" = "$before" ] || fail "a batch that failed on its second resource renewed the first"
[ "$(rows "SELECT COUNT(*) FROM claims")" = 1 ] || fail "a batch that failed on a later resource kept $(rows "SELECT resource FROM claims" | tr '\n' ' ')"
export AGENTBUS_DB=$real_db
ok "refused or failed, the batch leaves nothing behind"

echo "TEST P-CLAIM-5: a resource that overlaps a live claim of another name on the roster is refused with claim_conflict and nothing in the batch is claimed"
# Bug it catches (mutation): a different code, a refusal that names no holder, or one that leaves out when the holder's claim ends or the command to take it.
agentbus --as sb claim why/held.py --purpose "holding it" >/dev/null
for ask in "why/held.py" "why/free.py why/held.py"; do
  # shellcheck disable=SC2086
  r=$(agentbus --json --as sa claim $ask 2>&1 >/dev/null) && fail "a claim over another name's live claim succeeded: claim $ask"
  python3 - "$r" "$ask" <<'PY' || fail "the claim_conflict refusal of claim $ask lacks a field of the spec's list: $r"
import json, sys
e = json.loads(sys.argv[1])["error"]
assert e["code"] == "claim_conflict", e["code"]
assert e["holder"] == "sb" and e["resource"] == "why/held.py" and e["purpose"] == "holding it", e
for k in ("claimed_at", "expires_at", "holder_last_seen", "holder_idle_min", "claim_from"):
    assert k in e and e[k] is not None, k
assert e["claim_from"].endswith("--from sb"), e["claim_from"]
assert e["committed"] is False, e
assert "sb" in e["message"], e["message"]
assert (" " in sys.argv[2]) == ("nothing claimed" in e["message"]), e["message"]
PY
done
[ "$(rows "SELECT COUNT(*) FROM claims WHERE resource='why/free.py'")" = 0 ] || fail "the free resource of a refused batch was claimed"
ok "claim_conflict, with the holder, its claim and the command to take it"

echo "All claim rule tests passed"
