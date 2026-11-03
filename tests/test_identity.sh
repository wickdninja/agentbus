#!/usr/bin/env bash
# Identity, retries and idempotency: every write needs a joined name, a recipient typo is warned about,
# join retries safely with --request-id, and the small rules around names, goals and claims.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# A failure inside $(...) must still reach the output: lib.sh's fail prints on stdout, which a command substitution captures.
fail() { echo "FAIL: $1" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus/bus.db"; mkdir -p "$T/bus"
cd "$T"

# jfail CODE cmd...: the command exits non-zero with this JSON error code on stderr; prints the error object.
jfail() {
  local want=$1; shift
  local e; e=$(mktemp)
  if "$@" >/dev/null 2>"$e"; then fail "expected $want but succeeded: $*"; fi
  python3 - "$want" "$e" <<'PY' || fail "wrong error from: $* ($(cat "$e"))"
import json, sys
err = json.load(open(sys.argv[2]))["error"]
assert err["code"] == sys.argv[1], err
print(json.dumps(err))
PY
}
# rows SQL: the first column of every row, one per line, read straight from the bus file.
rows() {
  python3 - "$AGENTBUS_DB" "$1" <<'PY'
import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2]):
    print(r[0])
PY
}
# pyj 'CODE': runs CODE with d = the JSON on stdin.
pyj() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" || fail "JSON check failed: $(head -n1 <<<"$1")"; }
# must cmd...: the command succeeds (its stdout is not wanted).
must() { "$@" >/dev/null || fail "refused: $*"; }

echo "TEST 1: every write needs a joined name; nothing is written when it is refused"
agentbus --as alpha join >/dev/null
for w in "post hello" "ctx set k v" "goal ship" "log add note detail"; do
  # shellcheck disable=SC2086
  e=$(jfail not_on_roster "${AB[@]}" --json --as zed $w) || fail "unjoined write was not refused: $w"
  grep -qF "zed is not on the roster. Run: agentbus --as zed join" <<<"$e" || fail "message for '$w': $e"
done
[ "$(rows 'SELECT COUNT(*) FROM messages')" = 0 ] || fail "a refused post left a message"
[ "$(rows 'SELECT COUNT(*) FROM context')" = 0 ] || fail "a refused ctx set or goal left a fact"
[ "$(rows "SELECT COUNT(*) FROM log WHERE action IN ('note','goal')")" = 0 ] || fail "a refused write logged"
set +e; "${AB[@]}" --as zed post hello >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "unjoined post exits $rc, claim's not_on_roster exits 1"
agentbus --as alpha post hello >/dev/null; agentbus --as alpha ctx set k v >/dev/null; agentbus --as alpha goal ship >/dev/null
agentbus --as alpha log add note detail >/dev/null
agentbus --as alpha leave >/dev/null
expect_fail "alpha is not on the roster" agentbus --as alpha post "after leaving"
agentbus --as alpha join >/dev/null
ok "post, ctx set, goal and log add refuse a name that has not joined (or has left), like claim"

echo "TEST 2: an unknown --to is delivered, with a warning and a did-you-mean"
agentbus --as beta join >/dev/null
j=$(json_ok agentbus --json --as alpha post "hi" --to bata)
pyj 'assert d["warnings"] == [{"code":"recipient_not_on_roster","name":"bata","did_you_mean":["beta"],"roster":["alpha","beta"],"roster_total":2}], d' <<<"$j"
[ "$(rows "SELECT COUNT(*) FROM messages WHERE recipient='bata'")" = 1 ] || fail "the message was not delivered"
agentbus --as alpha post "hi" --to bata 2>"$T/err" >/dev/null
grep -qF "bata is not on the roster; the message waits for that name. Did you mean beta? On the roster: alpha, beta." "$T/err" || fail "text warning: $(cat "$T/err")"
j=$(json_ok agentbus --json --as alpha post "hi" --to zzzzzz)
pyj 'assert d["warnings"][0]["did_you_mean"] == [], d' <<<"$j"
agentbus --as alpha post "hi" --to zzzzzz 2>"$T/err" >/dev/null
if grep -q "Did you mean" "$T/err"; then fail "did-you-mean shown when nothing is close"; fi
j=$(json_ok agentbus --json --as alpha post "hi" --to beta)
pyj 'assert d["warnings"] == [], d' <<<"$j"
j=$(json_ok agentbus --json --as alpha post "everyone")
pyj 'assert d["warnings"] == [], d' <<<"$j"
json_ok agentbus --json --as alpha post "retry" --to bata --request-id w1 >/dev/null
j=$(json_ok agentbus --json --as alpha post "retry" --to bata --request-id w1)
pyj 'assert d["duplicate"] is True and d["warnings"][0]["name"] == "bata", d' <<<"$j"
ok "the warning is structured in JSON, one stderr line in text, empty when the name is fine"

echo "TEST 3: a repeated --to is refused, not silently reduced to the last one"
n=$(rows 'SELECT COUNT(*) FROM messages')
e=$(jfail bad_input "${AB[@]}" --json --as alpha post "x" --to beta --to gamma)
grep -qF "takes one name" <<<"$e" || fail "message: $e"
expect_fail "--to takes one name (got beta and gamma)" agentbus --as alpha post "x" --to beta --to gamma
[ "$(rows 'SELECT COUNT(*) FROM messages')" = "$n" ] || fail "a refused post left a message"
ok "post --to x --to y is bad_input and names the fix"

echo "TEST 4: join --request-id replays; a changed join and a reused token are named; name_active suggests a name"
j=$(json_ok agentbus --json --as gamma join --role lead --request-id J1)
pyj 'assert d["joined"] == "gamma" and "duplicate" not in d, d' <<<"$j"
logs=$(rows "SELECT COUNT(*) FROM log WHERE action='join'")
j=$(json_ok agentbus --json --as gamma join --role lead --request-id J1)
pyj 'assert d["joined"] == "gamma" and d["duplicate"] is True and d["contract"] == 1, d' <<<"$j"
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='join'")" = "$logs" ] || fail "the replay wrote a log row"
o=$(outof agentbus --as gamma join --role lead --request-id J1)
grep -qF "joined as gamma on" <<<"$o" && grep -qF "(already joined)" <<<"$o" || fail "text replay: $o"
e=$(jfail request_id_reused "${AB[@]}" --json --as gamma join --role other --request-id J1)
pyj 'assert d["original_id"] > 0 and "Original: join (log #%d)" % d["original_id"] in d["message"], d' <<<"$e"
grep -qF "or pick a new --request-id" <<<"$e" || fail "no way out named: $e"
e=$(jfail name_active "${AB[@]}" --json --as gamma join --role lead)
pyj 'assert d["suggested_name"] == "gamma-2", d' <<<"$e"
expect_fail "Pick your own name (run: agentbus --as gamma-2 join)" agentbus --as gamma join
agentbus --as gamma-2 join >/dev/null
e=$(jfail name_active "${AB[@]}" --json --as gamma-2 join)
pyj 'assert d["suggested_name"] == "gamma-3", d' <<<"$e"
json_ok agentbus --json --as gamma join --role lead --request-id J2 --takeover >/dev/null
agentbus --as gamma leave >/dev/null
j=$(json_ok agentbus --json --as gamma join --role lead --request-id J1)
pyj 'assert "duplicate" not in d, ("a name that left joins fresh even with an old token", d)' <<<"$j"
ok "same-agent retry replays (no new log row), a different join under the token names the original, the name error suggests a free name"

echo "TEST 5: post's mismatch error names the original message"
agentbus --as alpha post "first" --request-id P1 >/dev/null
id=$(rows "SELECT id FROM messages WHERE request_id='P1'")
e=$(jfail request_id_reused "${AB[@]}" --json --as alpha post "second" --request-id P1)
pyj 'assert d["original_id"] == '"$id"' and "Original: #'"$id"'. Reuse the same body or pick a new --request-id." in d["message"], d' <<<"$e"
ok "request_id_reused carries original_id and says how to fix it"

echo "TEST 6: --request-id is accepted on every write, and a repeat changes nothing"
must agentbus --as eps join --request-id R0
must agentbus --as eps claim src/a.py --purpose p --request-id R1
must agentbus --as eps ctx set kk vv --request-id R2
must agentbus --as eps goal "ship it" --request-id R3
n1=$(rows 'SELECT MAX(id) FROM log'); h1=$(rows 'SELECT COUNT(*) FROM context_history')
must agentbus --as eps join --request-id R0
must agentbus --as eps claim src/a.py --purpose p --request-id R1
must agentbus --as eps ctx set kk vv --request-id R2
must agentbus --as eps goal "ship it" --request-id R3
must agentbus --as eps release src/a.py --request-id R4
must agentbus --as eps release src/a.py --if-held --request-id R4
must agentbus --as eps leave --request-id R5
must agentbus --as eps leave --request-id R5
[ "$(rows 'SELECT COUNT(*) FROM context_history')" = "$h1" ] || fail "a repeated ctx set or goal wrote history"
[ "$(rows "SELECT action FROM log WHERE id>$n1" | tr '\n' ' ')" = "release leave " ] || fail "repeats wrote log rows: $(rows "SELECT action FROM log WHERE id>$n1" | tr '\n' ' ')"
ok "join, claim, release, ctx set, goal and leave take --request-id; the repeats are no-ops"

echo "TEST 7: join --takeover keeps role, tool and model that it does not repeat"
agentbus --as delta join --role reviewer --tool codex --model gpt >/dev/null
agentbus --as delta join --takeover >/dev/null
j=$(json_ok agentbus --json who)
pyj 'a = {x["name"]: x for x in d["items"]}["delta"]; assert (a["role"], a["tool"], a["model"]) == ("reviewer", "codex", "gpt"), a' <<<"$j"
agentbus --as delta join --takeover --role tester >/dev/null
j=$(json_ok agentbus --json who)
pyj 'a = {x["name"]: x for x in d["items"]}["delta"]; assert (a["role"], a["tool"], a["model"]) == ("tester", "codex", "gpt"), a' <<<"$j"
ok "takeover fills only what it is told"

echo "TEST 8: goal is a reserved fact key"
e=$(jfail bad_input "${AB[@]}" --json --as alpha ctx set goal "sneaky")
grep -qF "goal is reserved; use: agentbus goal TEXT" <<<"$e" || fail "message: $e"
pyj 'assert d["field"] == "key", d' <<<"$e"
expect_fail "goal is reserved; use: agentbus goal TEXT" agentbus --as alpha ctx set goal sneaky
agentbus --as alpha goal "the real goal" >/dev/null
j=$(json_ok agentbus --json status)
pyj 'assert d["goal"]["goal"] == "the real goal" and all(c["key"] != "goal" for c in d["context"]), d' <<<"$j"
o=$(outof agentbus status)
if sed -n '/^== context/,/^$/p' <<<"$o" | grep -q "goal = "; then fail "status lists the goal under facts: $o"; fi
o=$(outof agentbus ctx get)
if grep -q "goal = " <<<"$o"; then fail "ctx get lists the goal as a fact: $o"; fi
grep -qF "the real goal" <<<"$(agentbus ctx get goal)" || fail "ctx get goal no longer reads the goal"
ok "ctx set goal is refused, and status and ctx get stop listing it as a fact"

echo "TEST 9: leave for a name that never joined says so"
j=$(json_ok agentbus --json --as nobody leave 2>"$T/err")
pyj 'assert d["was_joined"] is False and d["released_count"] == 0, d' <<<"$j"
grep -qF "nobody was not on the roster" "$T/err" || fail "stderr note: $(cat "$T/err")"
j=$(json_ok agentbus --json --as delta leave 2>"$T/err")
pyj 'assert d["was_joined"] is True, d' <<<"$j"
[ ! -s "$T/err" ] || fail "a real leave printed a note: $(cat "$T/err")"
j=$(json_ok agentbus --json --as delta leave 2>/dev/null)
pyj 'assert d["was_joined"] is False, d' <<<"$j"
ok "was_joined is false, with a note, when there was nothing to leave"

echo "TEST 10: join names match the hook's [A-Za-z0-9._-]{1,40}; odd names already on a bus still work"
for bad in "has space" "semi;colon" "slash/name" "$(printf 'x%.0s' $(seq 41))" "ünï"; do
  e=$(jfail bad_input "${AB[@]}" --json --as "$bad" join)
  pyj 'assert d["field"] == "name" and "A-Za-z0-9._-" in d["message"], d' <<<"$e"
done
for good in "a.b_c-d" "$(printf 'x%.0s' $(seq 40))" "7"; do
  agentbus --as "$good" join >/dev/null || fail "valid name refused: $good"
done
python3 - "$AGENTBUS_DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO agents(name,joined_at,last_seen) VALUES('old name','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
con.commit()
PY
agentbus who | grep -qF "old name" || fail "an old bus's odd name no longer lists"
agentbus status >/dev/null || fail "status on a bus with an odd name"
agentbus --as "old name" post "still here" >/dev/null || fail "an odd name already on the roster cannot post"
expect_fail "is not a valid name" agentbus --as "old name" join
ok "bad names are refused with the rule; names already on a bus keep working"

echo "TEST 11: a claim renewal logs once; a changed purpose logs again"
agentbus --as alpha claim res/x --purpose first >/dev/null
n=$(rows "SELECT COUNT(*) FROM log WHERE action='claim'")
agentbus --as alpha claim res/x >/dev/null
agentbus --as alpha claim res/x --purpose first >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='claim'")" = "$n" ] || fail "a renewal logged"
agentbus --as alpha claim res/x --purpose second >/dev/null
[ "$(rows "SELECT COUNT(*) FROM log WHERE action='claim'")" = "$((n + 1))" ] || fail "a changed purpose did not log"
j=$(json_ok agentbus --json --as alpha claim res/x)
pyj 'assert d["purpose"] == "second" and d["expires_at"], d' <<<"$j"
ok "renewal is quiet, a first claim and a new purpose are logged"

echo "TEST 12: ctx set shows old -> new"
agentbus --as alpha ctx set mode fast >/dev/null
o=$(outof agentbus --as alpha ctx set mode slow)
[ "$o" = "set mode: fast -> slow" ] || fail "changed: $o"
o=$(outof agentbus --as alpha ctx set mode slow)
[ "$o" = "set mode (unchanged)" ] || fail "unchanged: $o"
o=$(outof agentbus --as alpha ctx set fresh one)
[ "$o" = "set fresh" ] || fail "new key: $o"
long=$(printf 'w%.0s' $(seq 200))
o=$(outof agentbus --as alpha ctx set mode "$long")
[ "${#o}" -lt 120 ] && grep -q '^set mode: slow -> w*\.\.\.$' <<<"$o" || fail "long value not cut: $o"
j=$(json_ok agentbus --json --as alpha ctx set mode quick)
pyj 'assert d["value"] == "quick" and d["unchanged"] is False, d' <<<"$j"
ok "the text output shows what changed"

echo "TEST 13: --limit below -1 is refused"
expect_fail "must be 0 or more, or -1 for all" agentbus who --limit -2
expect_fail "must be 0 or more, or -1 for all" agentbus claims --limit -5
[ "$(njson agentbus --json who --limit -1)" -ge 3 ] || fail "--limit -1 no longer lists all"
[ "$(njson agentbus --json who --limit 0)" = 0 ] || fail "--limit 0 changed"
ok "who --limit -2 is a usage error; -1 still means all"

echo "TEST 14: schema registers the changes"
j=$(json_ok agentbus --json schema)
pyj '
assert d["warnings"]["recipient_not_on_roster"]["fields"] == ["name", "did_you_mean", "roster", "roster_total"], d["warnings"]
assert "original_id" in d["errors"]["request_id_reused"]["fields"] and "suggested_name" in d["errors"]["name_active"]["fields"]
c = d["commands"]
for k in ("join", "leave", "claim", "release", "ctx set", "goal", "post"):
    assert any(a["name"] == "--request-id" for a in c[k]["args"]), k
assert "was_joined" in c["leave"]["result"]["required"] and "warnings" in c["post"]["result"]["required"]
assert "Warning" in d["objects"]
' <<<"$j"
ok "schema --json carries the warning, the new error fields and --request-id on every write"

echo "All identity tests passed"
