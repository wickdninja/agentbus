#!/bin/bash
set -euo pipefail

# The claim refusal: always true wherever it runs, since when, claimed_at in every refusal, a claim_refused log row.
# Runs this checkout's CLI against a throwaway db in a temp dir.

. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export AGENTBUS_DB="$TMP/selftest.db"

seen_ago() { "$PY" -c "import sqlite3,sys; from datetime import datetime,timedelta,timezone; c=sqlite3.connect(sys.argv[1]); t=(datetime.now(timezone.utc)-timedelta(minutes=int(sys.argv[3]))).strftime('%Y-%m-%dT%H:%M:%SZ'); c.execute('UPDATE agents SET last_seen=? WHERE name=?', (t, sys.argv[2])); c.commit()" "$AGENTBUS_DB" "$1" "$2"; }
echo "TEST: a refusal is always true: who, why, since when, and both branches; claim_refused is logged; claimed_at is in every refusal"
# Bug it catches: the refusal told every agent "Do not edit it yet", which is false on a separate branch (the merge decides),
# said nothing of since when, and left no row to count refusals from. A cwd guess about the checkout would be wrong in
# the other direction, so the text is the same wherever the claim runs.
RF_SAME='leave it until'
RF_BRANCH='On a separate branch, post what you are touching; the merge decides.'
for n in rh1 rh2 rw; do agentbus --as $n join --tool t >/dev/null; done
agentbus --as rh1 claim r/a.py --purpose "auth work" >/dev/null
agentbus --as rh2 claim r/b.py --purpose "tests" >/dev/null
err=$(mktemp)
agentbus --as rw claim r/a.py 2>"$err" && fail "single claim of a held file succeeded"
grep -qF "In a shared checkout, leave it until rh1 answers or releases it; ask: agentbus --as rw post QUESTION --to rh1 --kind question." "$err" || { cat "$err"; fail "the refusal lacks the same-checkout branch"; }
grep -qF "$RF_BRANCH" "$err" || { cat "$err"; fail "the refusal lacks the separate-branch branch"; }
grep -qF 'r/a.py is claimed by rh1 since ' "$err" || { cat "$err"; fail "the refusal lacks since when"; }
grep -qF 'purpose: "auth work"' "$err" || { cat "$err"; fail "the refusal lacks why"; }
grep -qF "Do not edit" "$err" && { cat "$err"; fail "the refusal still forbids editing outright"; }
agentbus --as rw claim r/a.py r/b.py 2>"$err" && fail "batch claim of held files succeeded"
grep -qF "nothing claimed: 2 of 2 resources are held by others. " "$err" && grep -qF "In a shared checkout, leave them until the holders answer or release them; ask rh1: agentbus --as rw post QUESTION --to rh1 --kind question (and the others), or leave these out and claim the rest." "$err" || { cat "$err"; fail "the batch refusal lacks the same-checkout branch"; }
grep -qF "$RF_BRANCH" "$err" || { cat "$err"; fail "the batch refusal lacks the separate-branch branch"; }
# no inference from where the claim runs: the same text from a plain folder and from inside a git checkout
mkdir -p "$TMP/plain" "$TMP/repo"; git -C "$TMP/repo" init -q 2>/dev/null
for d in "$TMP/plain" "$TMP/repo"; do (cd "$d" && "${AB[@]}" --json --as rw claim r/a.py 2>&1 >/dev/null) > "$d/out.json" || true; done
"$PY" - "$TMP/plain/out.json" "$TMP/repo/out.json" <<'PY' || fail "refusal differs by working folder, or names a checkout"
import json, sys
a, b = (json.load(open(f))["error"] for f in sys.argv[1:])
assert a == b, (a, b)
assert not any("checkout" in k for k in a), a
PY
# claimed_at: in the error, in every conflict, and the stored value
stored=$(agentbus --json claims | "$PY" -c 'import json,sys; print({r["resource"]: r["claimed_at"] for r in json.load(sys.stdin)["items"]}["r/a.py"])')
agentbus --json --as rw claim r/a.py 2>"$err" && fail "json single claim succeeded"
"$PY" - "$err" "$stored" <<'PY' || fail "claimed_at in the single refusal"
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["claimed_at"] == sys.argv[2], e
assert "rh1" in e["message"] and "separate branch" in e["message"], e
PY
agentbus --json --as rw claim r/a.py r/b.py 2>"$err" && fail "json batch claim succeeded"
"$PY" - "$err" "$stored" <<'PY' || fail "claimed_at in the batch refusal"
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["claimed_at"] == sys.argv[2] and e["committed"] is False, e
assert len(e["conflicts"]) == 2 and all(c["claimed_at"].endswith("Z") for c in e["conflicts"]), e
PY
# the holder's claim under bytes that are not UTF-8 (the undecoded path builds its own dict)
agentbus --as ru join --tool t >/dev/null
"$PY" - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO claims VALUES(CAST(X'617265613a71ff' AS TEXT),'ru','odd','2026-11-01T10:00:00Z','2999-01-01T00:00:00Z')")
c.commit()
PY
agentbus --json --as rw claim $'area:q\xef\xbf\xbd' 2>"$err" && fail "claim over an undecoded holder succeeded"
"$PY" - "$err" <<'PY' || fail "claimed_at in the undecoded refusal"
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "claim_conflict" and e["holder"] == "ru" and e["claimed_at"] == "2026-11-01T10:00:00Z", e
PY
# a holder's claimed_at that is not text (a lane can store any type): the refusal is still the refusal
agentbus --as rb join --tool t >/dev/null
"$PY" - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO claims VALUES('r/blob.py','rb','odd',X'6162','2999-01-01T00:00:00Z')")
c.commit()
PY
agentbus --json --as rw claim r/blob.py 2>"$err" && fail "claim over a holder with a blob claimed_at succeeded"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="claim_conflict" and e["holder"]=="rb", e' "$err" || { cat "$err"; fail "a claimed_at that is not text broke the refusal"; }
# the log: one claim_refused row per refusal, structured, and none for a claim that worked
rows() { agentbus --json log show --limit 200 | "$PY" -c 'import json,sys; print(json.dumps([r for r in json.load(sys.stdin)["items"] if r["action"]=="claim_refused"]))'; }
"$PY" - "$(rows)" <<'PY' || fail "claim_refused rows"
import json, sys
rows = json.loads(sys.argv[1])
assert [r["agent"] for r in rows] == ["rw"] * len(rows) and len(rows) == 8, rows
d = json.loads(rows[0]["detail"])
assert d == {"conflicts": [{"resource": "r/a.py", "held": "r/a.py", "holder": "rh1", "claimed_at": d["conflicts"][0]["claimed_at"]}]}, d
assert d["conflicts"][0]["claimed_at"].endswith("Z"), d
d = json.loads(rows[1]["detail"])
assert [(c["resource"], c["holder"]) for c in d["conflicts"]] == [("r/a.py", "rh1"), ("r/b.py", "rh2")], d
PY
agentbus --as rw claim r/free.py >/dev/null
[ "$(rows | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 8 ] || fail "a claim that worked logged a refusal"
agentbus log show --limit 200 | grep -F "claim_refused" | grep -qF "r/a.py held by rh1" || fail "log show does not read a claim_refused row as a sentence"
# the log write never changes the refusal: a busy bus, a database error and a full log all still give claim_conflict
before=$(rows | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')
AGENTBUS_TEST_FAIL=refusal-log agentbus --json --as rw claim r/a.py 2>"$err" && fail "claim succeeded with the log write failing"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="claim_conflict" and e["holder"]=="rh1" and e["committed"] is False, e' "$err" || { cat "$err"; fail "a busy bus on the log write changed the refusal"; }
AGENTBUS_TEST_FAIL=refusal-log-db agentbus --json --as rw claim r/a.py 2>"$err" && fail "claim succeeded with a database error on the log write"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="claim_conflict" and e["holder"]=="rh1" and e["committed"] is False, e' "$err" || { cat "$err"; fail "a database error on the log write changed the refusal"; }
# a real fault, not an injected one: the log table has run out of ids, so the insert fails and the write exits bus_unavailable
"$PY" - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE sqlite_sequence SET seq=9223372036854775807 WHERE name='log'")
c.commit()
PY
agentbus --json --as rw claim r/a.py 2>"$err" && fail "claim succeeded with the log full"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["code"]=="claim_conflict" and e["holder"]=="rh1" and e["committed"] is False, e' "$err" || { cat "$err"; fail "a full log changed the refusal"; }
[ "$(rows | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "$before" ] || fail "a failed log write left a row"
# the takeover wording: ask first, then your user; take it only with a handoff or your user's word, under your own name
# Bug it catches: the refusal offered `agentbus --as rh2 leave`, which acts as the holder (impersonation).
seen_ago rh2 180
agentbus --as rw claim r/b.py 2>"$err" && fail "claim of a gone holder's file succeeded"
grep -qF "rh2 was last seen 3h ago. rh2 may be gone: if no answer comes, ask your user. If your user or a handoff gave you rh2's work, take it: agentbus --as rw claim r/b.py --from rh2" "$err" || { cat "$err"; fail "the takeover wording"; }
grep -qF "probably gone" "$err" && fail "the refusal says probably gone"
grep -qF -- "--as rh2 leave" "$err" && { cat "$err"; fail "the refusal offers to act as the holder"; }
rm -f "$err"
ok "the refusal names holder, purpose, since when and both branches; claim_refused is logged and survives a failed write"

echo "TEST: claim --from HOLDER moves the named holders' claims in the way, all or nothing, and tells each holder"
# Bug it catches: a successor whose user or handoff gave it a crashed agent's work had no way out but acting as the
# holder (--as HOLDER leave), shown only after 30 minutes. --from is the taker's own name, logged and told.
err=$(mktemp)
export AGENTBUS_DB="$TMP/from.db"  # the bus above has a full log, by design
for n in fa fb fc; do agentbus --as $n join --tool t >/dev/null; done
agentbus --as fa claim f/src/ --purpose "port" >/dev/null
holder() { agentbus --json claims | "$PY" -c 'import json,sys; print(" ".join(r["resource"] + "=" + r["agent"] for r in json.load(sys.stdin)["items"] if r["resource"].startswith("f/")))'; }
# every refusal shows the --from command, with when to use it; a folder above is named whole
agentbus --as fb claim f/src/a.py 2>"$err" && fail "claim inside another's folder succeeded"
grep -qF "If your user or a handoff gave you fa's work, take it: agentbus --as fb claim f/src/ --from fa" "$err" || { cat "$err"; fail "the refusal lacks the --from command, folder named whole"; }
grep -qF "leave it until fa answers or releases it" "$err" || { cat "$err"; fail "the refusal lost the shared-checkout rule"; }
grep -qF "may be gone" "$err" && { cat "$err"; fail "a holder seen just now may be gone"; }
agentbus --json --as fb claim f/src/a.py 2>"$err" && fail "json claim inside another's folder succeeded"
"$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["error"]; assert e["claim_from"]=="agentbus --as fb claim f/src/ --from fa" and e["takeover"] is None, e' "$err" || { cat "$err"; fail "claim_from is not the --from command, or takeover is given under 30 minutes"; }
# a claim moves whole: --from on a path inside the holder's folder frees none of it
agentbus --json --as fb claim f/src/a.py --from fa 2>"$err" && fail "--from on a path inside the holder's folder succeeded"
"$PY" - "$err" <<'PY' || { cat "$err"; fail "--from inside a folder"; }
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "claim_conflict" and e["committed"] is False, e
assert e["message"].startswith("Nothing claimed: fa's claim is f/src/, wider than f/src/a.py, and a claim moves whole. "), e["message"]
assert e["claim_from"] == "agentbus --as fb claim f/src/ --from fa", e
PY
[ "$(holder)" = "f/src/=fa" ] || fail "a refused --from changed the claims: $(holder)"
# --from the wrong holder: the one in the way is named, with the command that names it
agentbus --json --as fb claim f/src/ --from fc 2>"$err" && fail "--from the wrong holder succeeded"
"$PY" - "$err" <<'PY' || { cat "$err"; fail "--from the wrong holder"; }
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "claim_conflict" and e["holder"] == "fa" and e["committed"] is False, e
assert e["message"].startswith("Nothing claimed: --from fc, but fa holds f/src/. "), e["message"]
assert e["claim_from"] == "agentbus --as fb claim f/src/ --from fa", e
PY
[ "$(holder)" = "f/src/=fa" ] || fail "--from the wrong holder changed the claims: $(holder)"
# a stale command: nothing is in the way and the named holder holds nothing (it released, or its claim expired)
rc=0; agentbus --json --as fb claim f/free.py --from fc 2>"$err" || rc=$?
[ "$rc" = 2 ] || fail "--from a non-holder exited $rc, not 2"
"$PY" - "$err" <<'PY' || { cat "$err"; fail "--from a non-holder"; }
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "bad_input" and e["field"] == "from" and e["committed"] is False, e
assert "fc holds no claim in the way of f/free.py" in e["message"] and "Nothing claimed" in e["message"], e["message"]
assert e["next"] == "agentbus --as fb claim f/free.py", e
PY
[ "$(holder)" = "f/src/=fa" ] || fail "a stale --from claimed something: $(holder)"
agentbus --as fb claim f/src/ --from fb 2>"$err" && fail "--from your own name succeeded"
grep -qF "take from yourself" "$err" || { cat "$err"; fail "--from your own name"; }
# a blocker nobody named refuses the whole batch, and the command names every holder
agentbus --as fc claim f/lib/x.py --purpose "lib" >/dev/null
agentbus --json --as fb claim f/src/ f/lib/ --from fa 2>"$err" && fail "--from with an unnamed blocker succeeded"
"$PY" - "$err" <<'PY' || { cat "$err"; fail "--from with an unnamed blocker"; }
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert e["code"] == "claim_conflict" and e["holder"] == "fc" and e["resource"] == "f/lib/", e
assert e["message"].startswith("Nothing claimed: --from fa, but fc holds f/lib/x.py. "), e["message"]
assert e["claim_from"] == "agentbus --as fb claim f/src/ f/lib/ --from fa --from fc", e
assert [c["claim_from"] for c in e["conflicts"]] == ["agentbus --as fb claim f/lib/ --from fc"], e
PY
[ "$(holder)" = "f/lib/x.py=fc f/src/=fa" ] || fail "a refused batch changed the claims: $(holder)"
agentbus --as fb claim f/src/ f/lib/ 2>"$err" && fail "batch over two holders succeeded"
grep -qF "If your user or a handoff gave you the holders' work, take it: agentbus --as fb claim f/src/ f/lib/ --from fa --from fc" "$err" || { cat "$err"; fail "the batch refusal lacks one --from command for the batch"; }
# the move: both holders named, all taken in one go
agentbus --as fb claim f/src/ f/lib/ --from fa --from fc --purpose "finish the port" >"$TMP/out" 2>"$err" || { cat "$err"; fail "--from both holders refused"; }
grep -qF "taken from fa (f/src/), fc (f/lib/x.py); each is told" "$TMP/out" || { cat "$TMP/out"; fail "the success text does not say what was taken"; }
[ "$(holder)" = "f/lib/=fb f/src/=fb" ] || fail "--from did not move the claims: $(holder)"
agentbus --json log show --limit 500 | "$PY" -c '
import json, sys
rows = [r for r in json.load(sys.stdin)["items"] if r["action"] == "claim_taken"]
by = {json.loads(r["detail"])["from"]: json.loads(r["detail"]) for r in rows}
assert [r["agent"] for r in rows] == ["fb", "fb"], rows
assert by["fa"] == {"from": "fa", "resources": ["f/src/"], "count": 1, "claimed": ["f/src/", "f/lib/"], "purpose": "finish the port"}, by
assert by["fc"]["resources"] == ["f/lib/x.py"] and by["fc"]["count"] == 1, by
' || fail "claim_taken rows"
agentbus log show --limit 500 | grep -F claim_taken | grep -qF "f/src/ taken from fa" || fail "log show does not read a claim_taken row as a sentence"
for h in fa fc; do
  agentbus --json --as $h inbox | "$PY" -c '
import json, sys
h = sys.argv[1]
m = [x for x in json.load(sys.stdin)["items"] if x["sender"] == "fb"]
assert len(m) == 1 and m[0]["kind"] == "alert" and m[0]["topic"] == "claim" and m[0]["recipient"] == h, m
held = {"fa": "f/src/", "fc": "f/lib/x.py"}[h]
assert m[0]["body"] == "fb took your claim on %s with claim --from and now holds f/src/, f/lib/ (purpose: \"finish the port\")." % held, m[0]["body"]
' $h || fail "$h was not told who took what and why"
done
# a repeat of your own --from renews and takes nothing again
agentbus --json --as fb claim f/src/ f/lib/ --from fa --from fc >"$TMP/out" 2>"$err" || { cat "$err"; fail "a repeat of --from refused"; }
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert all(c["renewed"] and c["taken_from"] == [] for c in d["claims"]), d' "$TMP/out" || fail "a repeat of --from did not renew"
[ "$(agentbus --json log show --limit 500 | "$PY" -c 'import json,sys; print(sum(r["action"]=="claim_taken" for r in json.load(sys.stdin)["items"]))')" = 2 ] || fail "a repeat logged another claim_taken"
# paths inside the resource move too, and the JSON says what each resource took
agentbus --as fa claim f/in/a.py f/in/b.py >/dev/null
agentbus --json --as fc claim f/in/ --from fa >"$TMP/out" 2>"$err" || { cat "$err"; fail "--from over paths inside refused"; }
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["taken_from"] == [{"resource": "f/in/a.py", "agent": "fa"}, {"resource": "f/in/b.py", "agent": "fa"}], d' "$TMP/out" || { cat "$TMP/out"; fail "taken_from"; }
[ "$(holder)" = "f/in/=fc f/lib/=fb f/src/=fb" ] || fail "paths inside did not move: $(holder)"
rm -f "$err"
ok "--from moves whole claims of named holders only, refuses stale and partial takes, logs claim_taken and tells the holder"
all_passed "All tests passed!"
