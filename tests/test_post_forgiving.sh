#!/bin/bash
set -euo pipefail
# post forgives the slips agents make most (issue 86 A4): an invented --kind posts as a note with a one-line warning
# that names the kinds, `send` is post, and --to all / everyone mean everyone. A name not on the roster still gets
# the message, with its warning (P-MSG-5, docs/protocol.md): that stays.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus.db"
agentbus --as lead join >/dev/null
agentbus --as lane join >/dev/null

kind_of() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT kind, recipient FROM messages WHERE id=?", (int(sys.argv[2]),)).fetchone())' "$AGENTBUS_DB" "$1"; }

echo "TEST: an invented --kind posts as a note, with one warning line naming the kinds"
# Bug it catches: 54 invented kinds (status, update, info...) were refused, and the lane lost its message.
out=$(agentbus --as lane post "tests green" --kind status 2>"$T/err") || fail "post --kind status failed: $(cat "$T/err")"
case "$out" in "posted #"*" to everyone [note]") ;; *) fail "post --kind status did not post a note: $out" ;; esac
[ "$(wc -l < "$T/err" | tr -d ' ')" = 1 ] || fail "the unknown-kind warning is not one line: $(cat "$T/err")"
grep -qF "unknown kind 'status'" "$T/err" && grep -qF "note, question, answer, handoff, decision, alert, done, todo, dropped" "$T/err" \
  || fail "the warning does not name the kind and the kinds: $(cat "$T/err")"
id=$(agentbus --as lane --json post "deploy done" --kind deployed | python3 -c 'import json,sys; d=json.load(sys.stdin); w=d["warnings"]; assert [x["code"] for x in w] == ["unknown_kind"] and w[0]["kind"] == "deployed" and "note" in w[0]["kinds"], d; print(d["id"])') \
  || fail "post --json --kind deployed has no unknown_kind warning"
[ "$(kind_of "$id")" = "('note', '*')" ] || fail "an invented kind was stored as $(kind_of "$id")"
ok "an invented kind posts as a note and says so in one line (unknown_kind in --json)"

echo "TEST: send is post"
out=$(agentbus --as lane send "hello lead" --to lead) || fail "send failed"
case "$out" in "posted #"*" to lead [note]") ;; *) fail "send did not post: $out" ;; esac
out=$(agentbus send --as lane "again" --kind question --to lead) || fail "send with --as after the verb failed"
case "$out" in "posted #"*" to lead [question]") ;; *) fail "send --kind question did not post a question: $out" ;; esac
ok "send posts exactly as post does"

echo "TEST: --to all and --to everyone broadcast"
# Bug it catches: three messages went to a name 'all' nobody could ever join as.
for to in all everyone ALL Everyone; do
  out=$(agentbus --as lane post "to $to" --to "$to" 2>"$T/err") || fail "post --to $to failed"
  case "$out" in "posted #"*" to everyone [note]") ;; *) fail "post --to $to did not broadcast: $out" ;; esac
  [ ! -s "$T/err" ] || fail "post --to $to warned: $(cat "$T/err")"
done
n=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM messages WHERE recipient IN (\"all\", \"everyone\", \"ALL\", \"Everyone\")").fetchone()[0])' "$AGENTBUS_DB")
[ "$n" = 0 ] || fail "$n messages were stored for a recipient named all or everyone"
ok "all and everyone mean *"

echo "TEST: a name not on the roster still gets the message, with its warning (P-MSG-5)"
out=$(agentbus --as lane post "for later" --to successor 2>"$T/err") || fail "post to a future name failed"
case "$out" in "posted #"*" to successor [note]") ;; *) fail "post to a future name: $out" ;; esac
grep -qF "successor is not on the roster" "$T/err" || fail "no roster warning: $(cat "$T/err")"
agentbus --as successor join >/dev/null
agentbus --as successor inbox | grep -qF "for later" || fail "the successor did not get the message"
ok "delivery to a name that joins later stays"
