#!/bin/bash
set -euo pipefail
# The post requirements of docs/protocol.md (P-MSG-1 to P-MSG-5, P-MSG-8), one section each, every check printing its own
# FAIL line. tests/test_identity.sh, tests/test_todo.sh and tests/test_inbox.sh pin the wording around them; this file
# pins the rules, so a mutation of one rule (tests/mutations.json, field "must") fails here for that rule's reason.
# Throwaway bus and HOME only.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/rules.db"
cd "$T"

# rows STATEMENT: the first column of every row, one per line.
rows() { python3 -c 'import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$AGENTBUS_DB" "$1"; }
# jfail CODE cmd...: the command exits non-zero with this JSON error code on stderr.
jfail() {
  local want=$1; shift
  local e; e=$(mktemp)
  if "$@" >/dev/null 2>"$e"; then fail "expected $want but succeeded: $*"; fi
  python3 - "$want" "$e" <<'PY' || fail "wrong error from: $* ($(cat "$e"))"
import json, sys
assert json.load(open(sys.argv[2]))["error"]["code"] == sys.argv[1]
PY
}
# posted ARGS...: post, print the new id.
posted() { json_ok agentbus --json --as "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
msgs() { rows "SELECT COUNT(*) FROM messages"; }
for n in qa qb qc; do agentbus --as $n join --tool t >/dev/null; done

echo "TEST P-MSG-1: the kind is one of the nine; any other is refused with bad_input and stores nothing"
# Bug it catches (mutation): a tenth kind accepted, or one of the nine refused.
first=$(posted qa post "root note")
for k in note question answer handoff decision alert done todo dropped; do
  id=$(posted qa post "kind $k" --kind $k --reply-to "$first") || fail "kind $k was refused"
  [ "$(rows "SELECT kind FROM messages WHERE id=$id")" = $k ] || fail "kind $k was stored as $(rows "SELECT kind FROM messages WHERE id=$id")"
done
n=$(msgs)
jfail bad_input "${AB[@]}" --json --as qa post "x" --kind fyi
[ "$(msgs)" = "$n" ] || fail "a refused kind stored a message"
ok "nine kinds stored as given, a tenth refused"

echo "TEST P-MSG-2: post inserts exactly one message with a new id, the sender, the recipient (default everyone), kind, topic, body, reply target and a time"
# Bug it catches (mutation): a field stored wrong (every kind as a note, a topic or reply target dropped, the body changed,
# the recipient forced to everyone, the sender replaced), or a second row inserted.
[ "$(rows "SELECT recipient || '|' || kind || '|' || sender FROM messages WHERE id=$first")" = "*|note|qa" ] \
  || fail "a post with no --to and no --kind did not store a note to everyone from the sender"
n=$(msgs)
got=$(posted qa post "Hello World" --to qb --kind question --topic t1 --reply-to "$first")
[ "$(msgs)" = $((n + 1)) ] || fail "one post did not insert exactly one message: $n -> $(msgs)"
[ "$got" -gt "$first" ] || fail "a post did not get a new id: $first then $got"
want="qa|qb|question|t1|Hello World|$first"
[ "$(rows "SELECT sender||'|'||recipient||'|'||kind||'|'||topic||'|'||body||'|'||reply_to FROM messages WHERE id=$got")" = "$want" ] \
  || fail "the stored message differs from what was posted: $(rows "SELECT sender||'|'||recipient||'|'||kind||'|'||topic||'|'||body||'|'||reply_to FROM messages WHERE id=$got") (want $want)"
[ -n "$(rows "SELECT ts FROM messages WHERE id=$got AND ts GLOB '[0-9][0-9][0-9][0-9]-*Z'")" ] || fail "a post stored no time"
ok "one row, every field as given"

echo "TEST P-MSG-3: a reply target must exist; a reply links only and does not choose the recipient"
# Bug it catches (mutation): a reply to a missing id accepted, or delivered to the sender of its target.
n=$(msgs)
jfail no_message "${AB[@]}" --json --as qa post "x" --reply-to 99999
[ "$(msgs)" = "$n" ] || fail "a refused reply stored a message"
mine=$(posted qb post "from qb" --to qc)
r=$(posted qa post "reply, no --to" --reply-to "$mine")
[ "$(rows "SELECT recipient FROM messages WHERE id=$r")" = "*" ] || fail "a reply chose its recipient from its target: $(rows "SELECT recipient FROM messages WHERE id=$r")"
r=$(posted qa post "reply to qc" --to qc --reply-to "$mine")
[ "$(rows "SELECT recipient FROM messages WHERE id=$r")" = qc ] || fail "a reply did not keep the recipient it was given"
agentbus --as qa post "an answer to a note" --kind answer --reply-to "$mine" >/dev/null || fail "an answer replying to a note was refused: nothing checks that kinds agree"
ok "missing target refused, recipient as given, kinds not checked"

echo "TEST P-MSG-5: a recipient not on the roster still receives the message, with the warning recipient_not_on_roster"
# Bug it catches (mutation): the message refused, or stored for everyone instead of for that name.
j=$(json_ok agentbus --json --as qa post "for a name that is not here yet" --to latecomer) || fail "post to a name off the roster was refused: $j"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert [w["code"] for w in d["warnings"]] == ["recipient_not_on_roster"], d' "$j" || fail "no recipient_not_on_roster warning: $j"
[ "$(rows "SELECT COUNT(*) FROM messages WHERE recipient='latecomer'")" = 1 ] || fail "the message to a name off the roster was not stored for that name"
agentbus --as latecomer join --tool t >/dev/null
agentbus --as latecomer inbox | grep -qF "for a name that is not here yet" || fail "the name that joined later did not receive the message that waited for it"
ok "stored for the name, warned, delivered when it joins"

echo "TEST P-MSG-8: a request id is per sender and per payload: a repeat returns the first id with duplicate true, a changed payload is refused"
# Bug it catches (mutation): the token shared between senders, compared by body alone, or a repeat that posts again.
a=$(posted qa post "tok" --request-id TK)
b=$(posted qb post "tok" --request-id TK) || fail "qb's post with qa's token was refused: a token is per sender"
[ "$a" != "$b" ] || fail "two senders with one token got one message"
n=$(msgs)
again=$(json_ok agentbus --json --as qa post "tok" --request-id TK) || fail "a repeat of a post with the same token failed: $again"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["duplicate"] is True and d["id"] == int(sys.argv[2]), d' "$again" "$a" || fail "a repeat did not return the first id with duplicate true: $again"
[ "$(msgs)" = "$n" ] || fail "a repeat with the same token stored a message"
for change in "--to qb" "--kind alert" "--topic other" "--reply-to $first"; do
  # shellcheck disable=SC2086
  jfail request_id_reused "${AB[@]}" --json --as qa post "tok" --request-id TK $change
done
jfail request_id_reused "${AB[@]}" --json --as qa post "other body" --request-id TK
[ "$(msgs)" = "$n" ] || fail "a refused repeat stored a message"
ok "per sender, per payload"

echo "All post rule tests passed"
